import Foundation

/// One signed-in Hackban instance (e.g. hackban.hackclub.com as you@hackclub.com, or a personal server).
public struct Account: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var baseURL: URL
    public var userId: String
    public var name: String?
    public var email: String?
    public var image: String?
    /// The OAuth client this app registered with the server.
    public var clientId: String
    /// User-chosen label ("Work", "Personal"); defaults to the host.
    public var label: String?
    /// Index into `AccountTint.all`.
    public var tint: Int
    public var needsReauth: Bool

    public init(id: UUID = UUID(), baseURL: URL, userId: String, name: String?, email: String?, image: String?, clientId: String, label: String? = nil, tint: Int = 0) {
        self.id = id; self.baseURL = baseURL; self.userId = userId; self.name = name; self.email = email
        self.image = image; self.clientId = clientId; self.label = label; self.tint = tint; self.needsReauth = false
    }

    public var host: String { baseURL.host() ?? baseURL.absoluteString }
    public var displayLabel: String { (label?.isEmpty == false ? label : nil) ?? host }
    public var subtitle: String { [name ?? email, host].compactMap { $0 }.joined(separator: " · ") }

    /// Resolves a server-relative path ("/api/files/x") against this instance.
    public func resolve(_ path: String) -> URL? {
        if let u = URL(string: path), u.scheme != nil { return u }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    public func webURL(board id: String) -> URL? { resolve("/b/\(id)") }
    public func webURL(card id: String) -> URL? { resolve("/c/\(id)") }
}

/// Persists the account list in the App Group so every process sees the same accounts.
public enum AccountRepository {
    private static let key = "accounts.v1"

    public static func load() -> [Account] {
        guard let data = Shared.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    public static func save(_ accounts: [Account]) {
        if let data = try? JSONEncoder().encode(accounts) { Shared.defaults.set(data, forKey: key) }
    }

    public static func account(_ id: UUID) -> Account? { load().first { $0.id == id } }

    public static func update(_ id: UUID, _ change: (inout Account) -> Void) {
        var all = load()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        save(all)
    }
}

/// Stable string id for things that live on one account: "accountUUID|serverId".
public struct ScopedID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var account: UUID
    public var id: String

    public init(account: UUID, id: String) { self.account = account; self.id = id }

    public init?(_ string: String) {
        let parts = string.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let uuid = UUID(uuidString: parts[0]) else { return nil }
        account = uuid; id = parts[1]
    }

    public var description: String { "\(account.uuidString)|\(id)" }
}
