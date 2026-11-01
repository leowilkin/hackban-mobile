import Foundation

/// A saved destination for quick add: "Work inbox" = account + board + list.
public struct QuickAddTarget: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var accountId: UUID
    public var boardId: String
    public var boardName: String
    public var listId: String?
    public var listName: String?
    public var top: Bool
    public var assignMe: Bool

    public init(id: UUID = UUID(), name: String, accountId: UUID, boardId: String, boardName: String, listId: String?, listName: String?, top: Bool = false, assignMe: Bool = false) {
        self.id = id; self.name = name; self.accountId = accountId; self.boardId = boardId; self.boardName = boardName
        self.listId = listId; self.listName = listName; self.top = top; self.assignMe = assignMe
    }

    public var subtitle: String { [boardName, listName].compactMap { $0 }.joined(separator: " › ") }
}

public enum QuickAddTargets {
    private static let key = "quickAddTargets.v1"
    private static let defaultKey = "quickAddDefault.v1"

    public static func load() -> [QuickAddTarget] {
        guard let data = Shared.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([QuickAddTarget].self, from: data)) ?? []
    }

    public static func save(_ targets: [QuickAddTarget]) {
        if let data = try? JSONEncoder().encode(targets) { Shared.defaults.set(data, forKey: key) }
    }

    public static var defaultId: UUID? {
        get { Shared.defaults.string(forKey: defaultKey).flatMap(UUID.init(uuidString:)) }
        set { Shared.defaults.set(newValue?.uuidString, forKey: defaultKey) }
    }

    public static var defaultTarget: QuickAddTarget? {
        let all = load()
        return all.first { $0.id == defaultId } ?? all.first
    }

    public static func target(_ id: UUID?) -> QuickAddTarget? {
        guard let id else { return defaultTarget }
        return load().first { $0.id == id }
    }
}

/// Todoist-style inline syntax:
/// `Ship deck tomorrow 5pm #Events/To_Do @me @sam !red ^top *weekly`
/// - `#board` or `#board/list` (underscores stand in for spaces; fuzzy matched)
/// - `@person` assigns (`@me` = you), `!label` adds a label by name or color
/// - `^top` / `^bottom`, `*daily|weekdays|weekly|monthly|yearly`
/// - any date phrase ("tomorrow 5pm", "next friday", "3 Dec") becomes the due date
public struct ParsedQuickAdd: Equatable, Sendable {
    public var title: String
    public var due: Date?
    public var board: String?
    public var list: String?
    public var members: [String] = []
    public var labels: [String] = []
    public var top: Bool?
    public var recurrence: Recurrence?
    public var dueText: String?
}

public enum QuickAddParser {
    public static func parse(_ text: String, now: Date = .now) -> ParsedQuickAdd {
        var kept: [String] = []
        var out = ParsedQuickAdd(title: "")
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            guard word.count > 1, let sigil = word.first else { kept.append(word); continue }
            let rest = String(word.dropFirst()).replacingOccurrences(of: "_", with: " ")
            switch sigil {
            case "#":
                let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
                out.board = parts.first
                out.list = parts.count > 1 ? parts[1] : nil
            case "@": out.members.append(rest)
            case "!": out.labels.append(rest)
            case "^":
                if rest.lowercased() == "top" { out.top = true }
                else if rest.lowercased() == "bottom" { out.top = false }
                else { kept.append(word) }
            case "*":
                if let r = Recurrence(rawValue: rest.lowercased()) { out.recurrence = r } else { kept.append(word) }
            default: kept.append(word)
            }
        }
        var title = kept.joined(separator: " ")
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = title as NSString
            if let match = detector.matches(in: title, range: NSRange(location: 0, length: ns.length)).last, let date = match.date {
                out.due = date
                out.dueText = ns.substring(with: match.range)
                title = ns.replacingCharacters(in: match.range, with: " ")
            }
        }
        out.title = title.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return out
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    /// Best fuzzy match: exact, then prefix, then substring, on letters and digits only.
    public static func best<T>(_ query: String, in items: [T], name: (T) -> String) -> T? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        let named = items.map { (item: $0, n: normalize(name($0))) }
        return named.first { $0.n == q }?.item
            ?? named.first { $0.n.hasPrefix(q) }?.item
            ?? named.first { $0.n.contains(q) }?.item
    }
}

/// A board somewhere across the signed-in accounts.
public struct BoardRef: Codable, Hashable, Identifiable, Sendable {
    public var accountId: UUID
    public var id: String
    public var name: String
    public var workspace: String?
    public var background: String
    public var starred: Bool

    public var scoped: ScopedID { ScopedID(account: accountId, id: id) }
}

/// Every board the user can open, per account, cached in the App Group for intents and widgets.
public enum BoardDirectory {
    static func key(_ account: UUID) -> String { "boards-\(account.uuidString)" }

    public static func cached(_ account: UUID) -> [BoardRef] { DiskCache.read([BoardRef].self, key(account)) ?? [] }

    public static func store(_ account: Account, workspaces: [Workspace], guests: [BoardSummary]) {
        var refs: [BoardRef] = []
        for w in workspaces {
            for b in w.boards where b.closed != true {
                refs.append(BoardRef(accountId: account.id, id: b.id, name: b.name, workspace: w.name, background: b.background, starred: b.starred ?? false))
            }
        }
        for b in guests where !refs.contains(where: { $0.id == b.id }) {
            refs.append(BoardRef(accountId: account.id, id: b.id, name: b.name, workspace: b.workspace?.name, background: b.background, starred: b.starred ?? false))
        }
        DiskCache.write(refs, key(account.id))
    }

    public static func fetch(_ account: Account) async throws -> [BoardRef] {
        let api = HackbanAPI(account)
        async let ws = api.workspaces()
        async let guests = api.guestBoards()
        store(account, workspaces: try await ws, guests: (try? await guests) ?? [])
        return cached(account.id)
    }

    /// Cached boards for all accounts, refreshing any account that has no cache yet.
    public static func all(refresh: Bool = false) async -> [BoardRef] {
        var out: [BoardRef] = []
        for a in AccountRepository.load() where !a.needsReauth {
            let c = cached(a.id)
            if c.isEmpty || refresh { out += (try? await fetch(a)) ?? c } else { out += c }
        }
        return out
    }
}

public struct AddedCard: Sendable, Hashable {
    public var accountId: UUID
    public var cardId: String
    public var boardId: String
    public var title: String
    public var boardName: String
    public var listName: String
}

public enum QuickAddError: LocalizedError {
    case noTitle, noAccount, noBoard(String?), noList

    public var errorDescription: String? {
        switch self {
        case .noTitle: return "Give the card a title."
        case .noAccount: return "Sign in to a Hackban server first."
        case .noBoard(let q): return q.map { "No board matches \u{201C}\($0)\u{201D}." } ?? "Pick a board, or set a default quick add target."
        case .noList: return "That board has no lists yet."
        }
    }
}

public enum QuickAddService {
    /// Creates the card described by `parsed`, defaulting to `target` for anything the text doesn't say.
    public static func add(_ parsed: ParsedQuickAdd, target: QuickAddTarget?, notes: String? = nil) async throws -> AddedCard {
        let title = parsed.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { throw QuickAddError.noTitle }
        let accounts = AccountRepository.load().filter { !$0.needsReauth }
        guard !accounts.isEmpty else { throw QuickAddError.noAccount }

        // Board: from #text (preferring the target's account), else the target's board.
        var accountId: UUID
        var boardId: String
        if let q = parsed.board {
            var boards = await BoardDirectory.all()
            if QuickAddParser.best(q, in: boards, name: \.name) == nil { boards = await BoardDirectory.all(refresh: true) }
            let preferred = boards.filter { $0.accountId == target?.accountId }
            guard let match = QuickAddParser.best(q, in: preferred, name: \.name) ?? QuickAddParser.best(q, in: boards, name: \.name) else {
                throw QuickAddError.noBoard(q)
            }
            accountId = match.accountId
            boardId = match.id
        } else if let target {
            accountId = target.accountId
            boardId = target.boardId
        } else {
            throw QuickAddError.noBoard(nil)
        }
        guard let account = accounts.first(where: { $0.id == accountId }) else { throw QuickAddError.noAccount }
        let api = HackbanAPI(account)
        let board = try await api.board(boardId)

        // List: from /text, else the target's list on that board, else the first list.
        let list: BoardList
        if let q = parsed.list, let l = QuickAddParser.best(q, in: board.lists, name: \.name) { list = l }
        else if let id = target?.listId, target?.boardId == boardId, let l = board.lists.first(where: { $0.id == id }) { list = l }
        else if let l = board.lists.first { list = l }
        else { throw QuickAddError.noList }

        let top = parsed.top ?? (target?.boardId == boardId ? target?.top ?? false : false)
        let created = try await api.createCard(listId: list.id, title: title, top: top)

        var fields: [String: JSONValue] = [:]
        if let due = parsed.due { fields["due"] = .date(due) }
        if let r = parsed.recurrence { fields["recurrence"] = .string(r.rawValue) }
        if let notes, !notes.isEmpty { fields["description"] = .string(notes) }
        if !fields.isEmpty { try await api.updateCard(created.id, fields) }

        var memberIds = Set<String>()
        if target?.assignMe == true && target?.boardId == boardId { memberIds.insert(account.userId) }
        for m in parsed.members {
            if m.lowercased() == "me" { memberIds.insert(account.userId); continue }
            if let row = QuickAddParser.best(m, in: board.members, name: { $0.user.username ?? $0.user.displayName })
                ?? QuickAddParser.best(m, in: board.members, name: { $0.user.displayName }) {
                memberIds.insert(row.userId)
            }
        }
        for id in memberIds { try? await api.toggleMember(card: created.id, user: id, on: true) }

        for l in parsed.labels {
            if let label = QuickAddParser.best(l, in: board.labels.filter { !$0.name.isEmpty }, name: \.name)
                ?? board.labels.first(where: { ($0.color ?? "") == l.lowercased() }) {
                try? await api.toggleLabel(card: created.id, label: label.id, on: true)
            }
        }
        return AddedCard(accountId: account.id, cardId: created.id, boardId: board.id, title: title, boardName: board.name, listName: list.name)
    }
}
