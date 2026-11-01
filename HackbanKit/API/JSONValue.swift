import Foundation

/// A loosely typed JSON value. Used for tRPC inputs (where `.date` becomes a superjson Date)
/// and for free-form server data such as activity payloads.
public enum JSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case date(Date)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .date(let d): return ISO8601.string(d)
        default: return nil
        }
    }

    public var date: Date? {
        switch self {
        case .date(let d): return d
        case .string(let s): return ISO8601.date(s)
        default: return nil
        }
    }

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Wraps an optional: `nil` becomes JSON null (explicitly clearing a field).
    public static func orNull(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
    public static func orNull(_ d: Date?) -> JSONValue { d.map(JSONValue.date) ?? .null }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .date(let d): try c.encode(ISO8601.string(d))
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
}

public enum ISO8601 {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let lock = NSLock()

    public static func string(_ d: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return frac.string(from: d)
    }

    public static func date(_ s: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return frac.date(from: s) ?? plain.date(from: s)
    }
}

/// superjson wire format: `{"json": <value>, "meta": {"values": {"path": ["Date"]}}}`.
/// Outputs keep dates as ISO strings inside `json`, so decoding only needs a date strategy;
/// inputs must declare their Date paths in `meta` or the server's zod `z.date()` rejects them.
public enum SuperJSON {
    public static func serialize(_ value: JSONValue?) -> Data {
        var paths: [String: JSONValue] = [:]
        if let value { collectDates(value, path: [], into: &paths) }
        var root: [String: JSONValue] = ["json": value ?? .null]
        if value == nil {
            root["meta"] = ["values": ["undefined"]]
        } else if !paths.isEmpty {
            root["meta"] = ["values": .object(paths)]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(JSONValue.object(root))) ?? Data("{}".utf8)
    }

    private static func collectDates(_ v: JSONValue, path: [String], into out: inout [String: JSONValue]) {
        switch v {
        case .date:
            if path.isEmpty { return }
            out[path.map(escape).joined(separator: ".")] = ["Date"]
        case .object(let o):
            for (k, child) in o { collectDates(child, path: path + [k], into: &out) }
        case .array(let a):
            for (i, child) in a.enumerated() { collectDates(child, path: path + [String(i)], into: &out) }
        default: break
        }
    }

    private static func escape(_ key: String) -> String {
        key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ".", with: "\\.")
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let s = try? c.decode(String.self), let date = ISO8601.date(s) { return date }
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n / 1000) }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a date")
        }
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(ISO8601.string(date))
        }
        return e
    }()
}

/// Decodes anything and discards it (for mutations whose result we don't use).
public struct Ignored: Codable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {}
    public func encode(to encoder: Encoder) throws {}
}
