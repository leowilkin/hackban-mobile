import CryptoKit
import Foundation

public enum HackbanError: LocalizedError, Equatable {
    case server(code: String, message: String, status: Int)
    case unauthorized
    case signedOut
    case invalidServer(String)
    case cancelled
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .server(_, let message, _): return message
        case .unauthorized: return "Your session expired. Sign in again."
        case .signedOut: return "This account is signed out. Sign in again from Settings."
        case .invalidServer(let s): return s
        case .cancelled: return "Cancelled"
        case .decoding(let s): return "Unexpected response from the server (\(s))."
        }
    }

    public var isAuth: Bool { self == .unauthorized || self == .signedOut }
}

/// OAuth 2.1 against a Hackban server: the same provider MCP clients use
/// (dynamic client registration, PKCE S256, rotating refresh tokens).
public struct OAuthServer: Sendable {
    public var authorize: URL
    public var token: URL
    public var register: URL

    public static func discover(_ base: URL) async throws -> OAuthServer {
        let fallback = OAuthServer(
            authorize: base.appending(path: "oauth/authorize"),
            token: base.appending(path: "api/oauth/token"),
            register: base.appending(path: "api/oauth/register"))
        let url = base.appending(path: ".well-known/oauth-authorization-server")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw HackbanError.invalidServer("Couldn't reach \(base.host() ?? base.absoluteString): \(error.localizedDescription)")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            throw HackbanError.invalidServer("\(base.host() ?? base.absoluteString) doesn't look like a Hackban server.")
        }
        return OAuthServer(
            authorize: URL(string: meta.authorization_endpoint) ?? fallback.authorize,
            token: URL(string: meta.token_endpoint) ?? fallback.token,
            register: meta.registration_endpoint.flatMap(URL.init(string:)) ?? fallback.register)
    }

    private struct Meta: Decodable {
        var authorization_endpoint: String
        var token_endpoint: String
        var registration_endpoint: String?
    }

    /// RFC 7591: register this app as a public (PKCE-only) client.
    public func registerClient() async throws -> String {
        var req = URLRequest(url: register)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "client_name": "Hackban for iOS",
            "redirect_uris": [Shared.redirectURI],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        struct Reg: Decodable { var client_id: String }
        guard (response as? HTTPURLResponse)?.statusCode == 201 || (response as? HTTPURLResponse)?.statusCode == 200,
              let reg = try? JSONDecoder().decode(Reg.self, from: data) else {
            throw HackbanError.invalidServer("The server refused to register the app: \(String(decoding: data, as: UTF8.self).prefix(200))")
        }
        return reg.client_id
    }

    public func authorizeURL(clientId: String, challenge: String, state: String) -> URL {
        var c = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: Shared.redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    public func exchange(code: String, verifier: String, clientId: String) async throws -> Tokens {
        try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Shared.redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ])
    }

    /// Synchronous refresh for use under the cross-process lock (never call on the main thread).
    public func refreshBlocking(_ refreshToken: String, clientId: String) throws -> Tokens {
        let req = tokenURLRequest(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId])
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        URLSession.shared.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
        sem.wait()
        if let e = out.2 { throw e }
        return try Self.parseTokens(out.0 ?? Data(), out.1)
    }

    private func tokenRequest(_ form: [String: String]) async throws -> Tokens {
        let (data, response) = try await URLSession.shared.data(for: tokenURLRequest(form))
        return try Self.parseTokens(data, response)
    }

    private func tokenURLRequest(_ form: [String: String]) -> URLRequest {
        var req = URLRequest(url: token)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        req.httpBody = Data(encoded.utf8)
        return req
    }

    private static func parseTokens(_ data: Data, _ response: URLResponse?) throws -> Tokens {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct T: Decodable { var access_token: String; var refresh_token: String; var expires_in: Double }
        guard status == 200, let t = try? JSONDecoder().decode(T.self, from: data) else {
            if status == 400 || status == 401 { throw HackbanError.unauthorized }
            throw HackbanError.server(code: "TOKEN", message: "Token request failed (\(status)).", status: status)
        }
        return Tokens(access: t.access_token, refresh: t.refresh_token, expiresAt: Date().addingTimeInterval(t.expires_in))
    }
}

public enum PKCE {
    public static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    public static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Hands out valid access tokens. Refresh tokens rotate and a replayed one revokes the whole grant on the
/// server, so only one process may refresh at a time: an in-process actor plus an flock on a file in the
/// App Group (shared with the widget extension and intents). After taking the lock it re-reads the Keychain,
/// so a process that lost the race uses the winner's tokens instead of replaying the old refresh token.
public actor TokenManager {
    public static let shared = TokenManager()

    private var servers: [URL: OAuthServer] = [:]
    private var inflight: [UUID: Task<String, Error>] = [:]

    public func accessToken(for account: Account, forceRefresh: Bool = false) async throws -> String {
        guard let current = TokenStore.read(account.id) else { throw HackbanError.signedOut }
        if current.isFresh && !forceRefresh { return current.access }
        if let running = inflight[account.id] { return try await running.value }
        let server = try await server(for: account.baseURL)
        let task = Task<String, Error> {
            try await withCheckedThrowingContinuation { cont in
                // A plain GCD thread: flock may block while another process refreshes.
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(with: Result { try Self.refresh(account, seen: current, server: server) })
                }
            }
        }
        inflight[account.id] = task
        defer { inflight[account.id] = nil }
        return try await task.value
    }

    private func server(for base: URL) async throws -> OAuthServer {
        if let s = servers[base] { return s }
        let s = try await OAuthServer.discover(base)
        servers[base] = s
        return s
    }

    private nonisolated static func refresh(_ account: Account, seen: Tokens, server: OAuthServer) throws -> String {
        let lockPath = Shared.container.appendingPathComponent("refresh-\(account.id.uuidString).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }

        guard let latest = TokenStore.read(account.id) else { throw HackbanError.signedOut }
        if latest.refresh != seen.refresh && latest.isFresh { return latest.access }
        do {
            let tokens = try server.refreshBlocking(latest.refresh, clientId: account.clientId)
            TokenStore.write(tokens, for: account.id)
            return tokens.access
        } catch HackbanError.unauthorized {
            AccountRepository.update(account.id) { $0.needsReauth = true }
            throw HackbanError.signedOut
        }
    }
}
