import Foundation

/// Board filters (port of board/types.ts).
public struct CardFilters: Equatable, Sendable {
    public enum Due: String, CaseIterable, Identifiable, Sendable {
        case overdue, day, week, none, complete
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .overdue: return "Overdue"
            case .day: return "Due in the next day"
            case .week: return "Due in the next week"
            case .none: return "No dates"
            case .complete: return "Marked complete"
            }
        }
    }

    public var q = ""
    /// User ids; "none" = cards with no members.
    public var members: Set<String> = []
    /// Label ids; "none" = cards with no labels.
    public var labels: Set<String> = []
    public var due: Set<Due> = []

    public init() {}

    public var isActive: Bool { !q.isEmpty || !members.isEmpty || !labels.isEmpty || !due.isEmpty }
    public var count: Int { (q.isEmpty ? 0 : 1) + members.count + labels.count + due.count }

    public func matches(_ c: BoardCard, now: Date = .now) -> Bool {
        if !q.isEmpty && !c.title.localizedCaseInsensitiveContains(q) { return false }
        if !members.isEmpty {
            let ids = c.members.map(\.userId)
            if !members.contains(where: { $0 == "none" ? ids.isEmpty : ids.contains($0) }) { return false }
        }
        if !labels.isEmpty {
            let ids = c.labels.map(\.labelId)
            if !labels.contains(where: { $0 == "none" ? ids.isEmpty : ids.contains($0) }) { return false }
        }
        if !due.isEmpty {
            let ok = due.contains { d in
                switch d {
                case .none: return c.due == nil
                case .complete: return c.due != nil && c.dueComplete
                default:
                    guard let t = c.due, !c.dueComplete else { return false }
                    switch d {
                    case .overdue: return t < now
                    case .day: return t >= now && t < now.addingTimeInterval(86_400)
                    default: return t >= now && t < now.addingTimeInterval(7 * 86_400)
                    }
                }
            }
            if !ok { return false }
        }
        return true
    }
}

public enum CardSort: String, CaseIterable, Identifiable, Sendable {
    case due, nameAZ, nameZA, newest, oldest, members

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .due: return "Due date (soonest first)"
        case .nameAZ: return "Name (A–Z)"
        case .nameZA: return "Name (Z–A)"
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .members: return "Most members first"
        }
    }

    private static func byTitle(_ a: BoardCard, _ b: BoardCard) -> Bool {
        a.title.compare(b.title, options: [.numeric, .caseInsensitive, .diacriticInsensitive]) == .orderedAscending
    }

    public func sorted(_ cards: [BoardCard]) -> [BoardCard] {
        cards.sorted { a, b in
            switch self {
            case .due:
                let x = a.due ?? .distantFuture, y = b.due ?? .distantFuture
                return x == y ? Self.byTitle(a, b) : x < y
            case .nameAZ: return Self.byTitle(a, b)
            case .nameZA: return Self.byTitle(b, a)
            case .newest: return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
            case .oldest: return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
            case .members: return a.members.count > b.members.count
            }
        }
    }

    /// Pulls cards with the same assignees together, keeping order within and between groups by first appearance.
    public static func groupByAssignee(_ cards: [BoardCard]) -> [BoardCard] {
        func key(_ c: BoardCard) -> String { c.members.map(\.userId).sorted().joined(separator: ",") }
        var first: [String: Int] = [:]
        for (i, c) in cards.enumerated() where first[key(c)] == nil { first[key(c)] = i }
        return cards.enumerated().sorted { l, r in
            let a = first[key(l.element)]!, b = first[key(r.element)]!
            return a == b ? l.offset < r.offset : a < b
        }.map(\.element)
    }
}
