import SwiftUI
import WidgetKit

struct WorkspaceRoute: Hashable {
    var account: UUID
    var workspaceId: String
}

/// Everything the home screen shows for one account.
struct HomeData {
    var workspaces: [Workspace] = []
    var recent: [BoardSummary] = []
    var guests: [BoardSummary] = []
    var error: String?

    var starred: [BoardSummary] {
        var seen = Set<String>()
        return (workspaces.flatMap(\.boards) + guests).filter { $0.starred == true && seen.insert($0.id).inserted }
    }
}

@MainActor @Observable
final class HomeStore {
    var data: [UUID: HomeData] = [:]
    var loading = false

    func load(_ accounts: [Account]) async {
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (UUID, HomeData).self) { group in
            for a in accounts {
                group.addTask {
                    let api = HackbanAPI(a)
                    do {
                        async let ws = api.workspaces()
                        async let recent = api.recentBoards()
                        async let guests = api.guestBoards()
                        let d = HomeData(workspaces: try await ws, recent: (try? await recent) ?? [], guests: (try? await guests) ?? [])
                        BoardDirectory.store(a, workspaces: d.workspaces, guests: d.guests)
                        return (a.id, d)
                    } catch {
                        return (a.id, HomeData(error: error.localizedDescription))
                    }
                }
            }
            for await (id, d) in group {
                if d.error != nil, let old = data[id], !old.workspaces.isEmpty {
                    data[id]?.error = d.error
                } else {
                    data[id] = d
                }
            }
        }
    }

    func setStar(_ account: UUID, board: String, _ starred: Bool) {
        guard var d = data[account] else { return }
        for w in d.workspaces.indices {
            for b in d.workspaces[w].boards.indices where d.workspaces[w].boards[b].id == board { d.workspaces[w].boards[b].starred = starred }
        }
        for b in d.guests.indices where d.guests[b].id == board { d.guests[b].starred = starred }
        for b in d.recent.indices where d.recent[b].id == board { d.recent[b].starred = starred }
        data[account] = d
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var store = HomeStore()
    @State private var showSettings = false
    @State private var createBoardFor: Account?
    @State private var createWorkspaceFor: Account?
    @State private var showJoin = false
    @State private var showClosed: Account?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.homePath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(model.scopedAccounts) { account in
                        accountSection(account)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationTitle(title)
            .refreshable { await store.load(model.scopedAccounts) }
            .task(id: model.scopedAccounts.map(\.id)) { await store.load(model.scopedAccounts) }
            .toolbar { toolbar }
            .navigationDestination(for: BoardRoute.self) { route in
                BoardView(route: route)
            }
            .navigationDestination(for: WorkspaceRoute.self) { route in
                if let account = model.account(route.account) {
                    WorkspaceSettingsView(account: account, workspaceId: route.workspaceId)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $createBoardFor) { account in
                CreateBoardSheet(account: account, workspaces: store.data[account.id]?.workspaces ?? []) { route in
                    Task { await store.load([account]) }
                    model.openBoard(route)
                }
            }
            .sheet(item: $createWorkspaceFor) { account in
                CreateWorkspaceSheet(account: account) { Task { await store.load([account]) } }
            }
            .sheet(item: $showClosed) { account in
                ClosedBoardsView(account: account) { Task { await store.load([account]) } }
            }
            .sheet(isPresented: $showJoin) { PasteLinkSheet() }
        }
    }

    private var title: String {
        if case .one(let id) = model.scope, let a = model.account(id) { return a.displayLabel }
        return "Boards"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { AccountScopeMenu() }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ForEach(model.scopedAccounts) { a in
                    Section(model.accounts.count > 1 ? a.displayLabel : "") {
                        Button { createBoardFor = a } label: { SwiftUI.Label("New board", systemImage: "rectangle.badge.plus") }
                        Button { createWorkspaceFor = a } label: { SwiftUI.Label("New workspace", systemImage: "person.3") }
                        Button { showClosed = a } label: { SwiftUI.Label("Closed boards", systemImage: "archivebox") }
                    }
                }
                Button { showJoin = true } label: { SwiftUI.Label("Open a Hackban link", systemImage: "link") }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Create")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
        }
        ToolbarItem(placement: .bottomBar) {
            Button { model.quickAdd = .init(target: nil) } label: {
                SwiftUI.Label("Quick add", systemImage: "plus.circle.fill")
            }
        }
    }

    @ViewBuilder
    private func accountSection(_ account: Account) -> some View {
        let d = store.data[account.id]
        VStack(alignment: .leading, spacing: 18) {
            if model.showAccountBadges {
                HStack(spacing: 10) {
                    AvatarView(name: account.name, image: account.image, account: account, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.displayLabel).font(.title3.bold())
                        Text(account.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.top, 8)
            }
            if account.needsReauth {
                ReauthBanner(account: account)
            }
            if let error = d?.error, d?.workspaces.isEmpty ?? true {
                SwiftUI.Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
            }
            if d == nil && store.loading {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            if let d {
                if !d.starred.isEmpty { boardGrid("Starred", icon: "star", boards: d.starred, account: account) }
                if !d.recent.isEmpty { boardGrid("Recently viewed", icon: "clock", boards: d.recent, account: account) }
                ForEach(d.workspaces) { w in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            WorkspaceLogo(name: w.name, logo: w.logo, account: account, size: 26)
                            Text(w.name).font(.headline)
                            Spacer()
                            NavigationLink(value: WorkspaceRoute(account: account.id, workspaceId: w.id)) {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("Workspace settings")
                        }
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(w.boards.filter { $0.closed != true }) { b in tile(b, account: account) }
                            Button { createBoardFor = account } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "plus")
                                    Text("Create board").font(.footnote)
                                }
                                .frame(maxWidth: .infinity, minHeight: 84)
                                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !d.guests.isEmpty { boardGrid("Guest boards", icon: "person.badge.key", boards: d.guests, account: account) }
            }
        }
    }

    private func boardGrid(_ title: String, icon: String, boards: [BoardSummary], account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SwiftUI.Label(title, systemImage: icon).font(.headline)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(boards) { b in tile(b, account: account) }
            }
        }
    }

    private func tile(_ b: BoardSummary, account: Account) -> some View {
        NavigationLink(value: BoardRoute(account: account.id, boardId: b.id)) {
            BoardTile(name: b.name, background: b.background, image: b.bgImage, starred: b.starred) {
                let next = !(b.starred ?? false)
                store.setStar(account.id, board: b.id, next)
                attempt(model) { try await HackbanAPI(account).starBoard(b.id, next) }
            }
        }
        .buttonStyle(.plain)
    }
}

struct WorkspaceLogo: View {
    var name: String
    var logo: String?
    var account: Account
    var size: CGFloat = 28

    var body: some View {
        let hues: [[String]] = [["#4bce97", "#1f845a"], ["#f87168", "#c9372c"], ["#579dff", "#0c66e4"], ["#9f8fef", "#6e5dc6"], ["#fea362", "#c25100"], ["#e774bb", "#ae4787"]]
        let hue = hues[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % hues.count]
        AuthImage(logo, account: account) {
            ZStack {
                LinearGradient(colors: hue.map(Color.init(hex:)), startPoint: .top, endPoint: .bottom)
                Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

struct ReauthBanner: View {
    @Environment(AppModel.self) private var model
    var account: Account
    @State private var signIn = SignIn()

    var body: some View {
        HStack {
            SwiftUI.Label("Signed out of \(account.host)", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.subheadline)
            Spacer()
            Button("Sign in") {
                attempt(model) {
                    _ = try await signIn.signIn(to: account.baseURL, replacing: account)
                    model.reloadAccounts()
                }
            }
            .glassButton()
        }
        .padding(12)
        .glassPanel(cornerRadius: 14, tint: .orange.opacity(0.2))
    }
}

struct AccountScopeMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.accounts.count > 1 {
            Menu {
                Picker("Show", selection: $model.scope) {
                    SwiftUI.Label("All accounts", systemImage: "square.stack.3d.up").tag(AccountScope.all)
                    ForEach(model.accounts) { a in
                        Text(a.displayLabel).tag(AccountScope.one(a.id))
                    }
                }
            } label: {
                Image(systemName: model.scope == .all ? "square.stack.3d.up" : "person.crop.circle")
            }
            .accessibilityLabel("Switch account")
        }
    }
}

/// Paste any https://<instance>/b/..., /c/... or /join/... link.
struct PasteLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://hackban.hackclub.com/join/…", text: $text)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Board, card and invite links from any server you're signed in to.")
                }
            }
            .navigationTitle("Open link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { return }
                        if model.openWebLink(url) { dismiss() } else { model.flash("That isn't a link to a server you're signed in to.") }
                    }
                }
            }
            .onAppear {
                if let s = UIPasteboard.general.string, s.hasPrefix("https://") { text = s }
            }
        }
        .presentationDetents([.medium])
    }
}
