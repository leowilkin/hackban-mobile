import Foundation

/// tRPC 11 over HTTP for one account. Queries are GETs with `?input=<superjson>`, mutations POST the
/// superjson body, subscriptions are server-sent events. Every call carries the account's OAuth token.
public struct HackbanAPI: Sendable {
    public let account: Account

    public init(_ account: Account) { self.account = account }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static let streamSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60 * 60
        c.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: c)
    }()

    // MARK: Core

    public func query<T: Decodable>(_ path: String, _ input: JSONValue? = nil, as: T.Type = T.self) async throws -> T {
        try await call(path, input, method: "GET")
    }

    public func mutate<T: Decodable>(_ path: String, _ input: JSONValue? = nil, as: T.Type = T.self) async throws -> T {
        try await call(path, input, method: "POST")
    }

    /// A mutation whose result isn't needed.
    public func run(_ path: String, _ input: JSONValue? = nil) async throws {
        let _: Ignored = try await call(path, input, method: "POST")
    }

    private func call<T: Decodable>(_ path: String, _ input: JSONValue?, method: String) async throws -> T {
        let data = try await send(retrying: true) { token in
            var url = account.baseURL.appending(path: "api/trpc/\(path)")
            var body: Data?
            if method == "GET" {
                if let input {
                    let encoded = String(decoding: SuperJSON.serialize(input), as: UTF8.self)
                    url = URL(string: url.absoluteString + "?input=" + Self.queryEscape(encoded))!
                }
            } else {
                body = SuperJSON.serialize(input)
            }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            authorize(&req, token)
            return req
        }
        return try Self.decodeResult(T.self, from: data)
    }

    /// Runs a request with a valid token; on 401 refreshes once and retries.
    private func send(retrying: Bool, _ build: (String) throws -> URLRequest) async throws -> Data {
        let token = try await TokenManager.shared.accessToken(for: account)
        let (data, response) = try await Self.session.data(for: try build(token))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retrying {
            let fresh = try await TokenManager.shared.accessToken(for: account, forceRefresh: true)
            let (d2, r2) = try await Self.session.data(for: try build(fresh))
            let s2 = (r2 as? HTTPURLResponse)?.statusCode ?? 0
            if s2 == 401 { throw HackbanError.unauthorized }
            if s2 >= 400 { throw Self.error(from: d2, status: s2) }
            return d2
        }
        if status >= 400 { throw Self.error(from: data, status: status) }
        return data
    }

    private func authorize(_ req: inout URLRequest, _ token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Shared.clientId, forHTTPHeaderField: "x-client-id")
        req.setValue(String(-TimeZone.current.secondsFromGMT() / 60), forHTTPHeaderField: "x-tz-offset")
        req.setValue("ios", forHTTPHeaderField: "x-trpc-source")
    }

    static func queryEscape(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/:,;$@!'()*[]")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private struct Envelope<T: Decodable>: Decodable {
        struct Result: Decodable { var data: Payload? }
        struct Payload: Decodable {
            var json: T?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                json = try c.decodeIfPresent(T.self, forKey: .json)
            }
            enum Keys: String, CodingKey { case json }
        }
        var result: Result?
    }

    static func decodeResult<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if T.self == Ignored.self { return Ignored() as! T }
        do {
            let env = try SuperJSON.decoder.decode(Envelope<T>.self, from: data)
            if let value = env.result?.data?.json { return value }
            throw HackbanError.decoding("empty result")
        } catch let e as DecodingError {
            throw HackbanError.decoding(Self.describe(e))
        }
    }

    private static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, let ctx): return "missing \(k.stringValue) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "bad value at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default: return "decoding error"
        }
    }

    static func error(from data: Data, status: Int) -> HackbanError {
        if status == 401 { return .unauthorized }
        struct E: Decodable {
            struct Inner: Decodable {
                struct Body: Decodable {
                    struct D: Decodable { var code: String?; var httpStatus: Int? }
                    var message: String?
                    var data: D?
                }
                var json: Body?
            }
            var error: Inner?
        }
        if let e = try? JSONDecoder().decode(E.self, from: data), let body = e.error?.json {
            var message = body.message ?? "Something went wrong."
            // zod errors arrive as a JSON array of issues; show the first message.
            if message.hasPrefix("["), let d = message.data(using: .utf8),
               let issues = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]],
               let first = issues.first?["message"] as? String {
                message = first
            }
            if body.data?.code == "FORBIDDEN" && message == "FORBIDDEN" { message = "You don't have permission to do that." }
            if body.data?.code == "NOT_FOUND" && message == "NOT_FOUND" { message = "That no longer exists, or you can't see it." }
            return .server(code: body.data?.code ?? "ERROR", message: message, status: status)
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return .server(code: "HTTP\(status)", message: text.isEmpty ? "Request failed (\(status))." : text, status: status)
    }

    // MARK: Files

    public struct UploadFile: Sendable {
        public var name: String
        public var mimeType: String
        public var data: Data
        public init(name: String, mimeType: String, data: Data) { self.name = name; self.mimeType = mimeType; self.data = data }
    }

    /// Multipart upload to a REST route (field "file").
    public func upload(_ path: String, files: [UploadFile], method: String = "POST") async throws -> Data {
        let boundary = "hackban-\(UUID().uuidString)"
        var body = Data()
        for f in files {
            body.append(Data("--\(boundary)\r\n".utf8))
            let safeName = f.name.replacingOccurrences(of: "\"", with: "'")
            body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
            body.append(Data("Content-Type: \(f.mimeType)\r\n\r\n".utf8))
            body.append(f.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return try await send(retrying: true) { token in
            var req = URLRequest(url: account.baseURL.appending(path: path))
            req.httpMethod = method
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            req.timeoutInterval = 300
            authorize(&req, token)
            return req
        }
    }

    public func delete(_ path: String) async throws {
        _ = try await send(retrying: true) { token in
            var req = URLRequest(url: account.baseURL.appending(path: path))
            req.httpMethod = "DELETE"
            authorize(&req, token)
            return req
        }
    }

    /// Downloads a URL; server-relative or same-host URLs get the bearer token.
    public func data(_ urlString: String) async throws -> Data {
        guard let url = account.resolve(urlString) else { throw HackbanError.invalidServer("Bad URL") }
        if url.host() == account.baseURL.host() {
            return try await send(retrying: true) { token in
                var req = URLRequest(url: url)
                authorize(&req, token)
                return req
            }
        }
        let (data, _) = try await Self.session.data(from: url)
        return data
    }

    // MARK: Live updates

    /// board.onEvent as an SSE stream. Ends when the connection drops; callers reconnect.
    public func boardEvents(_ boardId: String) -> AsyncThrowingStream<BoardEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let token = try await TokenManager.shared.accessToken(for: account)
                    let input = String(decoding: SuperJSON.serialize(["id": .string(boardId)]), as: UTF8.self)
                    let url = URL(string: account.baseURL.appending(path: "api/trpc/board.onEvent").absoluteString + "?input=" + Self.queryEscape(input))!
                    var req = URLRequest(url: url)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    authorize(&req, token)
                    let (bytes, response) = try await Self.streamSession.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 401 { _ = try? await TokenManager.shared.accessToken(for: account, forceRefresh: true) }
                    guard status == 200 else { throw HackbanError.server(code: "SSE", message: "Live updates unavailable (\(status))", status: status) }
                    // tRPC sends each message as one `data:` line of JSON; `lines` drops the blank
                    // separators, so parse data lines as they arrive and track the event name.
                    var event = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("id:") {
                            event = ""
                        } else if line.hasPrefix("data:") {
                            defer { event = "" }
                            guard event.isEmpty || event == "message" else { continue }
                            if let parsed = Self.parseEvent(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) {
                                continuation.yield(parsed)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func parseEvent(_ s: String) -> BoardEvent? {
        guard let data = s.data(using: .utf8) else { return nil }
        struct Wrapped: Decodable { var json: BoardEvent }
        if let w = try? JSONDecoder().decode(Wrapped.self, from: data) { return w.json }
        return try? JSONDecoder().decode(BoardEvent.self, from: data)
    }
}
