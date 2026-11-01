import AppIntents
import Foundation
import WidgetKit

/// Hand-off from intents (which may run outside the app's UI) to the app: a route to open.
public enum AppSignals {
    private static let key = "pendingRoute"
    public static let notification = Notification.Name("HackbanPendingRoute")

    public static func request(_ url: URL) {
        Shared.defaults.set(url.absoluteString, forKey: key)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    public static func take() -> URL? {
        guard let s = Shared.defaults.string(forKey: key) else { return nil }
        Shared.defaults.removeObject(forKey: key)
        return URL(string: s)
    }
}

public enum Routes {
    public static func quickAdd(_ target: UUID?) -> URL {
        var c = URLComponents(string: "\(Shared.urlScheme)://quickadd")!
        if let target { c.queryItems = [.init(name: "target", value: target.uuidString)] }
        return c.url!
    }

    public static func board(_ id: ScopedID) -> URL {
        URL(string: "\(Shared.urlScheme)://board?account=\(id.account.uuidString)&id=\(id.id)")!
    }

    public static func card(_ id: ScopedID) -> URL {
        URL(string: "\(Shared.urlScheme)://card?account=\(id.account.uuidString)&id=\(id.id)")!
    }

    public static let myCards = URL(string: "\(Shared.urlScheme)://mycards")!
}

func reloadWidgets() {
    WidgetCenter.shared.reloadAllTimelines()
}

// MARK: Add card

public struct AddCardIntent: AppIntent {
    public static var title: LocalizedStringResource = "Add Card"
    public static var description = IntentDescription("Adds a card to a Hackban board.")

    @Parameter(title: "Title") public var title: String
    @Parameter(title: "Board") public var board: BoardEntity
    @Parameter(title: "List", description: "Defaults to the board's first list.") public var list: ListEntity?
    @Parameter(title: "Due date") public var due: Date?
    @Parameter(title: "Description") public var notes: String?
    @Parameter(title: "Assign to me", default: false) public var assignToMe: Bool
    @Parameter(title: "Add to top", default: false) public var top: Bool

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to \(\.$board)") {
            \.$list
            \.$due
            \.$notes
            \.$assignToMe
            \.$top
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<CardEntity> & ProvidesDialog {
        guard let scoped = board.scoped, let account = AccountRepository.account(scoped.account) else { throw QuickAddError.noAccount }
        let api = HackbanAPI(account)
        let b = try await api.board(scoped.id)
        let listId = list?.parts?.listId ?? b.lists.first?.id
        guard let listId, let l = b.lists.first(where: { $0.id == listId }) else { throw QuickAddError.noList }
        let created = try await api.createCard(listId: l.id, title: title, top: top)
        var fields: [String: JSONValue] = [:]
        if let due { fields["due"] = .date(due) }
        if let notes, !notes.isEmpty { fields["description"] = .string(notes) }
        if !fields.isEmpty { try await api.updateCard(created.id, fields) }
        if assignToMe { try await api.toggleMember(card: created.id, user: account.userId, on: true) }
        reloadWidgets()
        let entity = CardEntity(id: ScopedID(account: account.id, id: created.id), title: title, boardName: b.name, listName: l.name, due: due, complete: false)
        return .result(value: entity, dialog: "Added \u{201C}\(title)\u{201D} to \(b.name) › \(l.name).")
    }
}

/// Parses Todoist-style text ("Call Sam tomorrow 3pm #Work/Today @me !red") and adds the card.
public struct QuickAddIntent: AppIntent {
    public static var title: LocalizedStringResource = "Quick Add Card"
    public static var description = IntentDescription("Adds a card from one line of text. Use #board/list, @person, !label, ^top, *weekly and date phrases like \u{201C}tomorrow 5pm\u{201D}.")

    @Parameter(title: "Text") public var text: String
    @Parameter(title: "Target", description: "Where the card goes when the text doesn't name a board.") public var target: QuickAddTargetEntity?

    public init() {}
    public init(text: String, target: QuickAddTargetEntity?) { self.text = text; self.target = target }

    public static var parameterSummary: some ParameterSummary {
        Summary("Quick add \(\.$text)") { \.$target }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<CardEntity> & ProvidesDialog {
        let parsed = QuickAddParser.parse(text)
        let added = try await QuickAddService.add(parsed, target: target?.target ?? QuickAddTargets.defaultTarget)
        reloadWidgets()
        let entity = CardEntity(id: ScopedID(account: added.accountId, id: added.cardId), title: added.title, boardName: added.boardName, listName: added.listName, due: parsed.due, complete: false)
        return .result(value: entity, dialog: "Added \u{201C}\(added.title)\u{201D} to \(added.boardName) › \(added.listName).")
    }
}

/// Opens the app's quick add sheet. Used by the Control Center control, the Action button and Shortcuts.
public struct OpenQuickAddIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Quick Add"
    public static var description = IntentDescription("Opens Hackban's quick add sheet.")
    public static var openAppWhenRun = true

    @Parameter(title: "Target") public var target: QuickAddTargetEntity?

    public init() {}
    public init(target: QuickAddTargetEntity?) { self.target = target }

    @MainActor
    public func perform() async throws -> some IntentResult {
        AppSignals.request(Routes.quickAdd(target.flatMap { UUID(uuidString: $0.id) }))
        return .result()
    }
}

// MARK: Cards

public struct CompleteCardIntent: AppIntent {
    public static var title: LocalizedStringResource = "Complete Card"
    public static var description = IntentDescription("Marks a card's due date complete (or not). Repeating cards move to their next date.")

    @Parameter(title: "Card") public var card: CardEntity
    @Parameter(title: "Complete", default: true) public var complete: Bool

    public init() {}
    public init(card: CardEntity, complete: Bool = true) { self.card = card; self.complete = complete }

    public static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$card) complete: \(\.$complete)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let s = card.scoped, let account = AccountRepository.account(s.account) else { throw QuickAddError.noAccount }
        MyCardsFeed.setComplete(s, complete)
        try await HackbanAPI(account).updateCard(s.id, ["dueComplete": .bool(complete)])
        _ = await MyCardsFeed.fetch([account])
        reloadWidgets()
        return .result(dialog: complete ? "Completed \u{201C}\(card.title)\u{201D}." : "Reopened \u{201C}\(card.title)\u{201D}.")
    }
}

public struct OpenBoardIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Board"
    public static var openAppWhenRun = true

    @Parameter(title: "Board") public var board: BoardEntity

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        if let s = board.scoped { AppSignals.request(Routes.board(s)) }
        return .result()
    }
}

public struct OpenCardIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Card"
    public static var openAppWhenRun = true

    @Parameter(title: "Card") public var card: CardEntity

    public init() {}
    public init(card: CardEntity) { self.card = card }

    @MainActor
    public func perform() async throws -> some IntentResult {
        if let s = card.scoped { AppSignals.request(Routes.card(s)) }
        return .result()
    }
}

public struct GetMyCardsIntent: AppIntent {
    public static var title: LocalizedStringResource = "Get My Cards"
    public static var description = IntentDescription("Open cards assigned to you, across every account, soonest due first.")

    @Parameter(title: "Due within (days)", description: "Leave empty for all cards.") public var withinDays: Int?
    @Parameter(title: "Include completed", default: false) public var includeComplete: Bool
    @Parameter(title: "Account", description: "Leave empty for all accounts.") public var account: AccountEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[CardEntity]> {
        var accounts = AccountRepository.load()
        if let id = account?.uuid { accounts = accounts.filter { $0.id == id } }
        var cards = await MyCardsFeed.fetch(accounts)
        if !includeComplete { cards = cards.filter { !$0.card.dueComplete } }
        if let withinDays {
            let limit = Date().addingTimeInterval(Double(withinDays) * 86_400)
            cards = cards.filter { ($0.card.due ?? .distantFuture) <= limit }
        }
        return .result(value: cards.map(CardEntity.init))
    }
}

public struct FindCardsIntent: AppIntent {
    public static var title: LocalizedStringResource = "Find Cards"
    public static var description = IntentDescription("Searches card titles and descriptions on every account.")

    @Parameter(title: "Search for") public var query: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[CardEntity]> {
        .result(value: try await CardSearch.search(query))
    }
}

// MARK: Widget & control configuration

public struct BoardWidgetIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Board List"
    public static var description = IntentDescription("Shows the cards in one list of a board.")

    @Parameter(title: "Board") public var board: BoardEntity?
    @Parameter(title: "List") public var list: ListEntity?

    public init() {}
}

public struct MyCardsWidgetIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "My Cards"
    public static var description = IntentDescription("Cards assigned to you.")

    @Parameter(title: "Account", description: "Leave empty for all accounts.") public var account: AccountEntity?
    @Parameter(title: "Show completed", default: false) public var showComplete: Bool

    public init() {}
}

public struct QuickAddWidgetIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Quick Add"
    public static var description = IntentDescription("One tap to add a card.")

    @Parameter(title: "Target") public var target: QuickAddTargetEntity?

    public init() {}
}

public struct QuickAddControlIntent: ControlConfigurationIntent {
    public static var title: LocalizedStringResource = "Quick Add"

    @Parameter(title: "Target") public var target: QuickAddTargetEntity?

    public init() {}
}
