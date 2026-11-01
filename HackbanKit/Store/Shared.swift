import Foundation

/// Locations shared between the app, the widget extension and App Intents.
public enum Shared {
    public static let appGroup: String = Bundle.main.object(forInfoDictionaryKey: "HBAppGroup") as? String ?? "group.com.hackclub.hackban"

    /// "<TeamID>.com.hackclub.hackban.shared", or nil when unsigned (simulator CI builds).
    public static let keychainGroup: String? = {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "HBKeychainGroup") as? String,
              !g.hasPrefix("."), !g.hasPrefix("$") else { return nil }
        return g
    }()

    public static let defaults: UserDefaults = UserDefaults(suiteName: appGroup) ?? .standard

    /// App Group container, or Application Support when the group isn't provisioned.
    public static let container: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return url }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hackban", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static let urlScheme = "hackban-ios"
    public static let redirectURI = "hackban-ios://oauth/callback"

    /// Identifies this process to the server so live-update echoes of its own changes can be skipped.
    public static let clientId: String = UUID().uuidString.lowercased()
}

/// Small JSON file cache in the shared container. The app writes; widgets and intents read.
public enum DiskCache {
    private static var dir: URL {
        let url = Shared.container.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent(safe + ".json")
    }

    public static func write<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? SuperJSON.encoder.encode(value) else { return }
        try? data.write(to: file(key), options: .atomic)
    }

    public static func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? SuperJSON.decoder.decode(T.self, from: data)
    }

    public static func modified(_ key: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(key).path))?[.modificationDate] as? Date
    }

    public static func remove(prefix: String) {
        let safe = prefix.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(safe) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
