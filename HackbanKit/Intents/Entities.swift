import AppIntents
import Foundation

// MARK: Account

public struct AccountEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Hackban Account"
    public static var defaultQuery = AccountQuery()

    public var id: String
    public var label: String
    public var subtitle: String

    public init(_ a: Account) { id = a.id.uuidString; label = a.displayLabel; subtitle = a.subtitle }

    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)", subtitle: "\(subtitle)") }
    public var uuid: UUID? { UUID(uuidString: id) }
}

public struct AccountQuery: EntityQuery {
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        AccountRepository.load().filter { identifiers.contains($0.id.uuidString) }.map(AccountEntity.init)
    }
    public func suggestedEntities() async throws -> [AccountEntity] { AccountRepository.load().map(AccountEntity.init) }
}

// MARK: Board

public struct BoardEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Board"
    public static var defaultQuery = BoardQuery()

    /// ScopedID string: "accountUUID|boardId".
    public var id: String
    public var name: String
    public var subtitle: String

    public init(_ b: BoardRef) {
        id = b.scoped.description
        name = b.name
        let account = AccountRepository.account(b.accountId)?.displayLabel
        subtitle = [b.workspace, AccountRepository.load().count > 1 ? account : nil].compactMap { $0 }.joined(separator: " · ")
    }

    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)") }
    public var scoped: ScopedID? { ScopedID(id) }
}

public struct BoardQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [BoardEntity] {
        var boards = await BoardDirectory.all()
        if identifiers.contains(where: { id in !boards.contains { $0.scoped.description == id } }) {
            boards = await BoardDirectory.all(refresh: true)
        }
        return boards.filter { identifiers.contains($0.scoped.description) }.map(BoardEntity.init)
    }

    public func suggestedEntities() async throws -> [BoardEntity] {
        let boards = await BoardDirectory.all()
        return boards.sorted { ($0.starred ? 0 : 1, $0.name) < ($1.starred ? 0 : 1, $1.name) }.map(BoardEntity.init)
    }

    public func entities(matching string: String) async throws -> [BoardEntity] {
        let boards = await BoardDirectory.all()
        return boards.filter { $0.name.localizedCaseInsensitiveContains(string) }.map(BoardEntity.init)
    }
}

// MARK: List

public struct ListEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    public static var defaultQuery = ListQuery()

    /// "accountUUID|boardId/listId".
    public var id: String
    public var name: String

    public init(account: UUID, boardId: String, listId: String, name: String) {
        id = "\(account.uuidString)|\(boardId)/\(listId)"
        self.name = name
    }

    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    public var parts: (account: UUID, boardId: String, listId: String)? { Self.parse(id) }

    static func parse(_ id: String) -> (account: UUID, boardId: String, listId: String)? {
        guard let s = ScopedID(id) else { return nil }
        let p = s.id.split(separator: "/", maxSplits: 1).map(String.init)
        guard p.count == 2 else { return nil }
        return (s.account, p[0], p[1])
    }
}

enum ListCache {
    static func key(_ board: ScopedID) -> String { "lists-\(board.account.uuidString)-\(board.id)" }

    struct Row: Codable { var id: String; var name: String }

    static func store(_ board: Board, account: UUID) {
        DiskCache.write(board.lists.map { Row(id: $0.id, name: $0.name) }, key(ScopedID(account: account, id: board.id)))
    }

    static func lists(_ board: ScopedID, refresh: Bool = false) async -> [ListEntity] {
        var rows = DiskCache.read([Row].self, key(board)) ?? []
        if rows.isEmpty || refresh, let account = AccountRepository.account(board.account),
           let b = try? await HackbanAPI(account).board(board.id) {
            store(b, account: board.account)
            rows = b.lists.map { Row(id: $0.id, name: $0.name) }
        }
        return rows.map { ListEntity(account: board.account, boardId: board.id, listId: $0.id, name: $0.name) }
    }
}

public struct ListQuery: EntityQuery {
    public init() {}

    @IntentParameterDependency<AddCardIntent>(\.$board) var addCard
    @IntentParameterDependency<BoardWidgetIntent>(\.$board) var widget

    private var board: ScopedID? { (addCard?.board ?? widget?.board)?.scoped }

    public func entities(for identifiers: [String]) async throws -> [ListEntity] {
        var out: [ListEntity] = []
        for id in identifiers {
            guard let p = ListEntity.parse(id) else { continue }
            let lists = await ListCache.lists(ScopedID(account: p.account, id: p.boardId))
            if let match = lists.first(where: { $0.id == id }) { out.append(match) }
        }
        return out
    }

    public func suggestedEntities() async throws -> [ListEntity] {
        guard let board else { return [] }
        return await ListCache.lists(board, refresh: true)
    }
}

// MARK: Card

public struct CardEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Card"
    public static var defaultQuery = CardQuery()

    /// ScopedID string: "accountUUID|cardId".
    public var id: String
    @Property(title: "Title") public var title: String
    @Property(title: "Board") public var boardName: String
    @Property(title: "List") public var listName: String
    @Property(title: "Due") public var due: Date?
    @Property(title: "Complete") public var complete: Bool
    @Property(title: "Link") public var url: URL?

    public init(id: ScopedID, title: String, boardName: String, listName: String, due: Date?, complete: Bool) {
        self.id = id.description
        self.title = title
        self.boardName = boardName
        self.listName = listName
        self.due = due
        self.complete = complete
        self.url = AccountRepository.account(id.account)?.webURL(card: id.id)
    }

    public init(_ f: FeedCard) {
        self.init(id: f.scoped, title: f.card.title, boardName: f.card.list.board.name, listName: f.card.list.name, due: f.card.due, complete: f.card.dueComplete)
    }

    public var displayRepresentation: DisplayRepresentation {
        let sub = [boardName, due.map { Fmt.due($0) }].compactMap { $0 }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(title)", subtitle: "\(sub)")
    }

    public var scoped: ScopedID? { ScopedID(id) }
}

public struct CardQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [CardEntity] {
        let cached = MyCardsFeed.cached()
        var out: [CardEntity] = []
        for id in identifiers {
            if let f = cached.first(where: { $0.id == id }) { out.append(CardEntity(f)); continue }
            guard let s = ScopedID(id), let account = AccountRepository.account(s.account),
                  let c = try? await HackbanAPI(account).card(s.id) else { continue }
            out.append(CardEntity(id: s, title: c.title, boardName: c.list.board?.name ?? "", listName: c.list.name, due: c.due, complete: c.dueComplete))
        }
        return out
    }

    public func suggestedEntities() async throws -> [CardEntity] {
        let cached = MyCardsFeed.cached()
        return (cached.isEmpty ? await MyCardsFeed.fetch() : cached).prefix(30).map(CardEntity.init)
    }

    public func entities(matching string: String) async throws -> [CardEntity] {
        try await CardSearch.search(string)
    }
}

enum CardSearch {
    static func search(_ q: String) async throws -> [CardEntity] {
        var out: [CardEntity] = []
        for a in AccountRepository.load() where !a.needsReauth {
            guard let r = try? await HackbanAPI(a).search(q) else { continue }
            out += r.cards.filter { $0.closed != true }.map {
                CardEntity(id: ScopedID(account: a.id, id: $0.id), title: $0.title, boardName: $0.list.board.name, listName: $0.list.name, due: $0.due, complete: $0.dueComplete ?? false)
            }
        }
        return out
    }
}

// MARK: Quick add target

public struct QuickAddTargetEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Quick Add Target"
    public static var defaultQuery = QuickAddTargetQuery()

    public var id: String
    public var name: String
    public var subtitle: String

    public init(_ t: QuickAddTarget) { id = t.id.uuidString; name = t.name; subtitle = t.subtitle }

    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)") }
    public var target: QuickAddTarget? { QuickAddTargets.target(UUID(uuidString: id)) }
}

public struct QuickAddTargetQuery: EntityQuery {
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [QuickAddTargetEntity] {
        QuickAddTargets.load().filter { identifiers.contains($0.id.uuidString) }.map(QuickAddTargetEntity.init)
    }
    public func suggestedEntities() async throws -> [QuickAddTargetEntity] { QuickAddTargets.load().map(QuickAddTargetEntity.init) }
    public func defaultResult() async -> QuickAddTargetEntity? { QuickAddTargets.defaultTarget.map(QuickAddTargetEntity.init) }
}
