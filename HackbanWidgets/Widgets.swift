import AppIntents
import SwiftUI
import WidgetKit

@main
struct HackbanWidgetBundle: WidgetBundle {
    var body: some Widget {
        MyCardsWidget()
        BoardListWidget()
        QuickAddWidget()
        QuickAddControl()
    }
}

// MARK: My cards

struct CardsEntry: TimelineEntry {
    var date: Date
    var cards: [FeedCard]
    var multiAccount: Bool
    var signedIn: Bool
}

struct MyCardsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CardsEntry { CardsEntry(date: .now, cards: [], multiAccount: false, signedIn: true) }

    func snapshot(for configuration: MyCardsWidgetIntent, in context: Context) async -> CardsEntry {
        entry(configuration, cards: MyCardsFeed.cached(accounts(configuration)))
    }

    func timeline(for configuration: MyCardsWidgetIntent, in context: Context) async -> Timeline<CardsEntry> {
        let accts = accounts(configuration)
        // Use the cache the app keeps fresh; only hit the network when it's stale.
        let stale = accts.contains { (MyCardsFeed.lastUpdated($0.id) ?? .distantPast).timeIntervalSinceNow < -15 * 60 }
        let cards = stale ? await MyCardsFeed.fetch(accts) : MyCardsFeed.cached(accts)
        return Timeline(entries: [entry(configuration, cards: cards)], policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func accounts(_ c: MyCardsWidgetIntent) -> [Account] {
        let all = AccountRepository.load()
        guard let id = c.account?.uuid else { return all }
        return all.filter { $0.id == id }
    }

    private func entry(_ c: MyCardsWidgetIntent, cards: [FeedCard]) -> CardsEntry {
        CardsEntry(date: .now, cards: c.showComplete ? cards : cards.filter { !$0.card.dueComplete },
                   multiAccount: AccountRepository.load().count > 1 && c.account == nil, signedIn: !AccountRepository.load().isEmpty)
    }
}

struct MyCardsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MyCards", intent: MyCardsWidgetIntent.self, provider: MyCardsProvider()) { entry in
            MyCardsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("My Cards")
        .description("Cards assigned to you, soonest due first. Tap the circle to complete one.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct MyCardsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: CardsEntry

    private var dueSoon: Int {
        let end = Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400)
        return entry.cards.filter { !$0.card.dueComplete && ($0.card.due ?? .distantFuture) < end }.count
    }

    var body: some View {
        if !entry.signedIn {
            Text("Open Hackban to sign in").font(.caption).widgetURL(URL(string: "\(Shared.urlScheme)://"))
        } else {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Text("\(dueSoon)").font(.title2.bold())
                        Text("due").font(.caption2)
                    }
                }
                .widgetURL(Routes.myCards)
            case .accessoryInline:
                if let c = entry.cards.first {
                    Text("\(c.card.title)\(c.card.due.map { " · " + Fmt.due($0) } ?? "")")
                } else {
                    Text("No cards due")
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text(dueSoon > 0 ? "\(dueSoon) due today" : "My cards").font(.headline).widgetAccentable()
                    ForEach(entry.cards.prefix(2)) { c in Text(c.card.title).font(.caption).lineLimit(1) }
                    if entry.cards.isEmpty { Text("All clear").font(.caption) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(Routes.myCards)
            default:
                list
            }
        }
    }

    private var limit: Int {
        switch family { case .systemSmall: return 3; case .systemMedium: return 3; default: return 8 }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            HStack {
                Text("My Cards").font(.headline)
                Spacer()
                if dueSoon > 0 {
                    Text("\(dueSoon)").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Palette.brand, in: Capsule()).foregroundStyle(.white)
                }
                if family != .systemSmall {
                    Button(intent: OpenQuickAddIntent(target: nil)) { Image(systemName: "plus.circle.fill").foregroundStyle(Palette.brand) }
                        .buttonStyle(.plain)
                }
            }
            if entry.cards.isEmpty {
                Spacer()
                Text("Nothing assigned to you.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.cards.prefix(limit)) { c in row(c) }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(Routes.myCards)
    }

    private func row(_ c: FeedCard) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if family != .systemSmall {
                Button(intent: CompleteCardIntent(card: CardEntity(c), complete: !c.card.dueComplete)) {
                    Image(systemName: c.card.dueComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(c.card.dueComplete ? Color.green : .secondary)
                }
                .buttonStyle(.plain)
            }
            Link(destination: Routes.card(c.scoped)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.card.title).font(.caption.weight(.medium)).lineLimit(family == .systemSmall ? 2 : 1)
                        .strikethrough(c.card.dueComplete)
                    HStack(spacing: 4) {
                        if let due = c.card.due {
                            let state = DueState.of(due: due, complete: c.card.dueComplete)
                            Text(Fmt.due(due)).foregroundStyle(state == .overdue ? Color.red : state == .soon ? Color.orange : .secondary)
                        }
                        if family != .systemSmall {
                            Text(entry.multiAccount ? "\(c.card.list.board.name) · \(c.accountLabel)" : c.card.list.board.name).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: Board list

struct BoardListEntry: TimelineEntry {
    var date: Date
    var boardName: String?
    var listName: String?
    var background: String
    var cards: [BoardCard]
    var account: UUID?
    var boardId: String?
}

struct BoardListProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BoardListEntry {
        BoardListEntry(date: .now, boardName: "Board", listName: "To Do", background: "#0079bf", cards: [], account: nil, boardId: nil)
    }

    func snapshot(for configuration: BoardWidgetIntent, in context: Context) async -> BoardListEntry {
        await load(configuration)
    }

    func timeline(for configuration: BoardWidgetIntent, in context: Context) async -> Timeline<BoardListEntry> {
        Timeline(entries: [await load(configuration)], policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func load(_ c: BoardWidgetIntent) async -> BoardListEntry {
        guard let scoped = c.board?.scoped, let account = AccountRepository.account(scoped.account) else {
            return BoardListEntry(date: .now, boardName: nil, listName: nil, background: "#0079bf", cards: [], account: nil, boardId: nil)
        }
        let key = "widgetboard-\(scoped.account.uuidString)-\(scoped.id)"
        var board = DiskCache.read(Board.self, key)
        if let fresh = try? await HackbanAPI(account).board(scoped.id) {
            board = fresh
            DiskCache.write(fresh, key)
        }
        let list = board?.lists.first { $0.id == c.list?.parts?.listId } ?? board?.lists.first
        return BoardListEntry(date: .now, boardName: board?.name ?? c.board?.name, listName: list?.name, background: board?.background ?? "#0079bf",
                              cards: list?.cards ?? [], account: scoped.account, boardId: scoped.id)
    }
}

struct BoardListWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "BoardList", intent: BoardWidgetIntent.self, provider: BoardListProvider()) { entry in
            BoardListWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    BoardBackground.fill(entry.background).opacity(0.9)
                }
        }
        .configurationDisplayName("Board List")
        .description("The cards in one list of a board.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct BoardListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: BoardListEntry

    var body: some View {
        if entry.boardName == nil {
            Text("Edit the widget to pick a board.").font(.caption).foregroundStyle(.white)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.boardName ?? "").font(.headline)
                    if let l = entry.listName { Text("› \(l)").font(.subheadline).opacity(0.8) }
                    Spacer()
                    Text("\(entry.cards.count)").font(.caption.bold())
                }
                .foregroundStyle(.white)
                ForEach(entry.cards.prefix(family == .systemLarge ? 8 : 3)) { c in
                    HStack(spacing: 6) {
                        if !c.labels.isEmpty {
                            RoundedRectangle(cornerRadius: 2).fill(Palette.label(c.labels[0].label.color).background).frame(width: 4, height: 14)
                        }
                        Text(c.title).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let due = c.due { Text(Fmt.due(due)).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                }
                if entry.cards.isEmpty { Text("No cards").font(.caption).foregroundStyle(.white.opacity(0.8)) }
                Spacer(minLength: 0)
            }
            .widgetURL(entry.account.flatMap { a in entry.boardId.map { Routes.board(ScopedID(account: a, id: $0)) } })
        }
    }
}

// MARK: Quick add button

struct QuickAddEntry: TimelineEntry {
    var date: Date
    var target: QuickAddTarget?
}

struct QuickAddProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickAddEntry { QuickAddEntry(date: .now, target: nil) }
    func snapshot(for configuration: QuickAddWidgetIntent, in context: Context) async -> QuickAddEntry {
        QuickAddEntry(date: .now, target: configuration.target?.target ?? QuickAddTargets.defaultTarget)
    }
    func timeline(for configuration: QuickAddWidgetIntent, in context: Context) async -> Timeline<QuickAddEntry> {
        Timeline(entries: [QuickAddEntry(date: .now, target: configuration.target?.target ?? QuickAddTargets.defaultTarget)], policy: .never)
    }
}

struct QuickAddWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuickAdd", intent: QuickAddWidgetIntent.self, provider: QuickAddProvider()) { entry in
            QuickAddWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Palette.brand, Color(hex: "#a3142b")], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .widgetURL(Routes.quickAdd(entry.target?.id))
        }
        .configurationDisplayName("Quick Add")
        .description("One tap to add a card to a quick add target.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct QuickAddWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: QuickAddEntry

    var body: some View {
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "plus").font(.title.bold())
            }
        } else {
            VStack(alignment: .leading) {
                Image(systemName: "plus.circle.fill").font(.system(size: 40)).foregroundStyle(.white)
                Spacer()
                Text("Add card").font(.headline).foregroundStyle(.white)
                Text(entry.target?.name ?? "Quick add").font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Control Center / Lock Screen / Action button

struct QuickAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.hackclub.hackban.quickadd", intent: QuickAddControlIntent.self) { configuration in
            ControlWidgetButton(action: OpenQuickAddIntent(target: configuration.target)) {
                SwiftUI.Label(configuration.target?.name ?? "Add Card", systemImage: "plus.rectangle.on.rectangle")
            }
        }
        .displayName("Hackban Quick Add")
        .description("Opens quick add, optionally for a saved target.")
    }
}
