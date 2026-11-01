import SwiftUI
import WidgetKit

// MARK: My cards (all accounts)

struct MyCardsView: View {
    @Environment(AppModel.self) private var app
    @State private var cards: [FeedCard] = MyCardsFeed.cached()
    @State private var showComplete = false
    @State private var loading = false

    var body: some View {
        let scoped = cards.filter { c in app.scopedAccounts.contains { $0.id == c.accountId } && (showComplete || !c.card.dueComplete) }
        List {
            if scoped.isEmpty && !loading {
                EmptyState(title: "Nothing assigned to you", systemImage: "checkmark.circle", message: "Cards you're a member of show up here.")
                    .listRowBackground(Color.clear)
            }
            ForEach(groups(scoped), id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { f in row(f) }
                }
            }
        }
        .navigationTitle("My Cards")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { AccountScopeMenu() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show completed", isOn: $showComplete)
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { app.quickAdd = .init(target: nil) } label: { Image(systemName: "plus") }.accessibilityLabel("Quick add")
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        cards = await MyCardsFeed.fetch(app.accounts)
        loading = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func groups(_ cards: [FeedCard]) -> [(String, [FeedCard])] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [FeedCard])] = [("Overdue", []), ("Today", []), ("Tomorrow", []), ("This week", []), ("Later", []), ("No due date", []), ("Completed", [])]
        for c in cards {
            let i: Int
            if c.card.dueComplete { i = 6 }
            else if let d = c.card.due {
                if d < now { i = 0 }
                else if cal.isDateInToday(d) { i = 1 }
                else if cal.isDateInTomorrow(d) { i = 2 }
                else if d < now.addingTimeInterval(7 * 86_400) { i = 3 }
                else { i = 4 }
            } else { i = 5 }
            buckets[i].1.append(c)
        }
        return buckets.filter { !$0.1.isEmpty }
    }

    private func row(_ f: FeedCard) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                toggle(f)
            } label: {
                Image(systemName: f.card.dueComplete ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(f.card.dueComplete ? Color.green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(f.card.dueComplete ? "Mark incomplete" : "Mark complete")
            VStack(alignment: .leading, spacing: 4) {
                Text(f.card.title).strikethrough(f.card.dueComplete)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(BoardBackground.primary(f.card.list.board.background ?? "#0079bf")).frame(width: 10, height: 10)
                    Text("\(f.card.list.board.name) › \(f.card.list.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let due = f.card.due { DueBadge(due: due, complete: f.card.dueComplete, recurrence: f.card.recurrence) }
                    ForEach(f.card.labels.prefix(4), id: \.labelId) { LabelChip(label: $0.label, compact: true) }
                    if app.showAccountBadges, let a = app.account(f.accountId) { AccountBadge(account: a) }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.presentedCard = CardRoute(account: f.accountId, cardId: f.card.id) }
        .swipeActions(edge: .leading) {
            Button(f.card.dueComplete ? "Reopen" : "Complete") { toggle(f) }.tint(.green)
        }
        .contextMenu {
            Button { app.openBoard(BoardRoute(account: f.accountId, boardId: f.card.list.board.id)) } label: { SwiftUI.Label("Open board", systemImage: "rectangle.split.3x1") }
        }
    }

    private func toggle(_ f: FeedCard) {
        guard let account = app.account(f.accountId) else { return }
        let next = !f.card.dueComplete
        if let i = cards.firstIndex(where: { $0.id == f.id }) { cards[i].card.dueComplete = next }
        attempt(app) {
            try await HackbanAPI(account).updateCard(f.card.id, ["dueComplete": .bool(next)])
            if f.card.recurrence != nil { app.flash("Repeating card moved to its next date") }
            await load()
        }
    }
}

// MARK: Notifications

struct NotificationsView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [(account: Account, item: NotificationItem)] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && items.isEmpty {
                EmptyState(title: "No notifications", systemImage: "bell.slash", message: "You'll hear about cards you're added to and comments on cards you watch.")
                    .listRowBackground(Color.clear)
            }
            ForEach(items, id: \.item.id) { entry in
                Button { open(entry.account, entry.item) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(entry.item.read ? Color.clear : Palette.brand).frame(width: 8, height: 8).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ActivityText.notification(entry.item)).font(.subheadline).foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                Text(Fmt.relative(entry.item.createdAt)).font(.caption).foregroundStyle(.secondary)
                                if app.showAccountBadges { AccountBadge(account: entry.account) }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { AccountScopeMenu() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark all read") {
                    attempt(app) {
                        for a in app.scopedAccounts { try await HackbanAPI(a).markAllNotificationsRead() }
                        await load()
                    }
                }
                .disabled(!items.contains { !$0.item.read })
            }
        }
        .refreshable { await load() }
        .task(id: app.scopedAccounts.map(\.id)) { await load() }
    }

    private func load() async {
        var out: [(Account, NotificationItem)] = []
        for a in app.scopedAccounts where !a.needsReauth {
            if let n = try? await HackbanAPI(a).notifications() {
                out += n.map { (a, $0) }
                app.unread[a.id] = n.filter { !$0.read }.count
            }
        }
        items = out.sorted { $0.1.createdAt > $1.1.createdAt }.map { (account: $0.0, item: $0.1) }
        loaded = true
    }

    private func open(_ account: Account, _ n: NotificationItem) {
        if !n.read {
            if let i = items.firstIndex(where: { $0.item.id == n.id }) { items[i].item.read = true }
            app.unread[account.id] = max(0, (app.unread[account.id] ?? 1) - 1)
            Task { try? await HackbanAPI(account).markNotificationRead(n.id) }
        }
        if let card = n.value("cardId") { app.presentedCard = CardRoute(account: account.id, cardId: card) }
        else if let board = n.value("boardId") { app.openBoard(BoardRoute(account: account.id, boardId: board)) }
    }
}

// MARK: Search

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var results: [(account: Account, results: SearchResults)] = []
    @State private var searching = false

    var body: some View {
        List {
            if query.count < 2 {
                EmptyState(title: "Search boards and cards", systemImage: "magnifyingglass", message: app.accounts.count > 1 ? "Searches every account at once." : nil)
                    .listRowBackground(Color.clear)
            }
            ForEach(results, id: \.account.id) { entry in
                if !entry.results.boards.isEmpty {
                    Section(app.showAccountBadges ? "Boards · \(entry.account.displayLabel)" : "Boards") {
                        ForEach(entry.results.boards) { b in
                            Button { app.openBoard(BoardRoute(account: entry.account.id, boardId: b.id)) } label: {
                                HStack {
                                    BoardBackground(b.background, image: b.bgImage).frame(width: 36, height: 26).clipShape(RoundedRectangle(cornerRadius: 5))
                                    Text(b.name)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !entry.results.cards.isEmpty {
                    Section(app.showAccountBadges ? "Cards · \(entry.account.displayLabel)" : "Cards") {
                        ForEach(entry.results.cards) { c in
                            Button { app.presentedCard = CardRoute(account: entry.account.id, cardId: c.id) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).strikethrough(c.closed == true)
                                    Text("\(c.list.board.name) › \(c.list.name)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if query.count >= 2 && !searching && results.allSatisfy({ $0.results.boards.isEmpty && $0.results.cards.isEmpty }) {
                Text("No results for \u{201C}\(query)\u{201D}").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Boards and cards")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searching = true
            var out: [(Account, SearchResults)] = []
            for a in app.scopedAccounts where !a.needsReauth {
                if let r = try? await HackbanAPI(a).search(q) { out.append((a, r)) }
            }
            guard !Task.isCancelled else { return }
            results = out.map { (account: $0.0, results: $0.1) }
            searching = false
        }
    }
}
