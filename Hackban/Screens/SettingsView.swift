import PhotosUI
import SwiftUI
import WidgetKit

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var addingAccount = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    ForEach(app.accounts) { a in
                        NavigationLink { AccountSettingsView(accountId: a.id) } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: a.name, image: a.image, account: a, size: 36)
                                    .overlay(alignment: .bottomTrailing) { Circle().fill(AccountTint.color(a.tint)).frame(width: 10, height: 10) }
                                VStack(alignment: .leading) {
                                    Text(a.displayLabel)
                                    Text(a.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                if a.needsReauth { Spacer(); Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                            }
                        }
                    }
                    Button { addingAccount = true } label: { SwiftUI.Label("Add account", systemImage: "plus.circle") }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Sign in to as many Hackban servers as you like, e.g. your organization's and your own. Boards, My Cards, Notifications and Search show them all together, or pick one with the account switcher.")
                }

                Section {
                    NavigationLink { QuickAddTargetsView() } label: {
                        LabeledContent("Quick add targets", value: "\(QuickAddTargets.load().count)")
                    }
                } header: {
                    Text("Quick add")
                } footer: {
                    Text("Targets show up as Home Screen quick actions (long-press the app icon), in the Quick Add control for Control Center, the Lock Screen and the Action button, in widgets, and in Shortcuts.")
                }

                Section("Appearance") {
                    Picker("Theme", selection: $app.theme) {
                        ForEach(Theme.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("Hackban on GitHub", destination: URL(string: "https://github.com/hackclub/hackban")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $addingAccount) {
                NavigationStack {
                    AddServerForm(dismissOnSuccess: true)
                        .padding()
                        .navigationTitle("Add account")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { addingAccount = false } } }
                    Spacer()
                }
                .presentationDetents([.medium])
            }
        }
    }
}

struct AccountSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let accountId: UUID
    @State private var label = ""
    @State private var profile: Profile?
    @State private var name = ""
    @State private var username = ""
    @State private var apps: [ConnectedApp] = []
    @State private var avatarItem: PhotosPickerItem?
    @State private var confirmRemove = false
    @State private var signIn = SignIn()

    var body: some View {
        if let account = app.account(accountId) {
            Form {
                Section {
                    TextField("Label", text: $label, prompt: Text(account.host))
                        .onSubmit { app.updateAccount(account.id) { $0.label = label.isEmpty ? nil : label } }
                    Picker("Color", selection: Binding(get: { account.tint }, set: { t in app.updateAccount(account.id) { $0.tint = t } })) {
                        ForEach(AccountTint.all.indices, id: \.self) { i in
                            Text(["Red", "Blue", "Green", "Purple", "Orange", "Teal"][i]).tag(i)
                        }
                    }
                    LabeledContent("Server", value: account.host)
                    if account.needsReauth {
                        Button("Sign in again") {
                            attempt(app) { _ = try await signIn.signIn(to: account.baseURL, replacing: account); app.reloadAccounts() }
                        }
                    }
                } header: { Text("This account") }

                if let profile {
                    Section("Profile") {
                        HStack {
                            AvatarView(name: profile.name, image: profile.image, account: account, size: 56)
                            VStack(alignment: .leading, spacing: 6) {
                                PhotosPicker(selection: $avatarItem, matching: .images) { Text("Change picture") }
                                if profile.avatarKey != nil {
                                    Button("Use Slack picture", role: .destructive) {
                                        attempt(app) { try await HackbanAPI(account).removeAvatar(); await loadProfile(account) }
                                    }
                                }
                            }
                        }
                        TextField("Full name", text: $name)
                        TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let email = profile.email { LabeledContent("Email", value: email) }
                        Button("Save profile") {
                            let n = name, u = username
                            attempt(app) {
                                try await HackbanAPI(account).updateProfile(name: n.isEmpty ? nil : n, username: u.isEmpty ? .null : .string(u.lowercased()))
                                await loadProfile(account)
                                app.flash("Profile saved")
                            }
                        }
                        .disabled(name == (profile.name ?? "") && username == (profile.username ?? ""))
                    }
                }

                Section {
                    NavigationLink { MyActivityView(account: account) } label: { SwiftUI.Label("Your activity", systemImage: "clock.arrow.circlepath") }
                }

                Section {
                    ForEach(apps) { a in
                        VStack(alignment: .leading) {
                            Text(a.name + (a.id == account.clientId ? " (this app)" : ""))
                            if let d = a.lastActive { Text("Last active \(Fmt.relative(d))").font(.caption).foregroundStyle(.secondary) }
                        }
                        .swipeActions {
                            if a.id != account.clientId {
                                Button("Revoke", role: .destructive) {
                                    attempt(app) { try await HackbanAPI(account).revokeApp(a.id); apps = try await HackbanAPI(account).connectedApps() }
                                }
                            }
                        }
                    }
                } header: { Text("Connected apps") } footer: { Text("Apps that can act as you on \(account.host), such as Claude over MCP. Swipe to revoke.") }

                Section {
                    Button("Sign out and remove", role: .destructive) { confirmRemove = true }
                }
            }
            .navigationTitle(account.displayLabel)
            .onAppear { label = account.label ?? "" }
            .task { await loadProfile(account); apps = (try? await HackbanAPI(account).connectedApps()) ?? [] }
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                attempt(app) {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let type = item.supportedContentTypes.first
                    try await HackbanAPI(account).uploadAvatar(.init(name: "avatar.\(type?.preferredFilenameExtension ?? "jpg")", mimeType: type?.preferredMIMEType ?? "image/jpeg", data: data))
                    await loadProfile(account)
                }
            }
            .confirmationDialog("Remove \(account.displayLabel) from this device? The server stays as it is.", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove account", role: .destructive) { app.remove(account); dismiss() }
            }
        }
    }

    private func loadProfile(_ account: Account) async {
        guard let p = try? await HackbanAPI(account).profile() else { return }
        profile = p
        name = p.name ?? ""
        username = p.username ?? ""
        app.updateAccount(account.id) { $0.name = p.name; $0.image = p.image; $0.email = p.email }
    }
}

struct MyActivityView: View {
    @Environment(AppModel.self) private var app
    let account: Account
    @State private var items: [Activity] = []
    @State private var next: String?
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(items) { a in
                VStack(alignment: .leading, spacing: 4) {
                    ActivityRow(activity: a, account: account)
                    if let b = a.board { Text("on \(b.name)").font(.caption).foregroundStyle(.secondary).padding(.leading, 40) }
                }
                .contentShape(Rectangle())
                .onTapGesture { if let c = a.card { app.presentedCard = CardRoute(account: account.id, cardId: c.id) } }
            }
            if let next { ProgressView().frame(maxWidth: .infinity).task { await load(next) } }
        }
        .navigationTitle("Your activity")
        .task { if !loaded { await load(nil) } }
    }

    private func load(_ cursor: String?) async {
        guard let page = try? await HackbanAPI(account).myActivity(cursor: cursor) else { next = nil; return }
        items += page.items
        next = page.next
        loaded = true
    }
}

// MARK: Quick add targets

struct QuickAddTargetsView: View {
    @Environment(AppModel.self) private var app
    @State private var targets = QuickAddTargets.load()
    @State private var defaultId = QuickAddTargets.defaultTarget?.id
    @State private var editing: QuickAddTarget?
    @State private var creating = false

    var body: some View {
        List {
            Section {
                ForEach(targets) { t in
                    Button { editing = t } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(t.name)
                                Text([app.account(t.accountId)?.displayLabel, t.subtitle].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if t.id == defaultId { Text("Default").font(.caption.bold()).foregroundStyle(.tint) }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button("Default") { defaultId = t.id; QuickAddTargets.defaultId = t.id; changed() }.tint(.accentColor)
                    }
                }
                .onDelete { targets.remove(atOffsets: $0); save() }
                .onMove { targets.move(fromOffsets: $0, toOffset: $1); save() }
            } footer: {
                Text("Swipe right to make a target the default. The first three appear as Home Screen quick actions.")
            }
            Section("Syntax") {
                Text("Type \u{201C}Ship deck tomorrow 5pm #Events/To_Do @me !red ^top *weekly\u{201D}. **#board/list** picks where it goes (underscores for spaces), **@name** assigns, **!label** labels, **^top** adds to the top, **\\*daily**…**\\*yearly** repeats, and date phrases set the due date.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Quick add targets")
        .toolbar {
            EditButton()
            Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New target")
        }
        .sheet(item: $editing) { t in TargetEditor(target: t) { updated in
            if let i = targets.firstIndex(where: { $0.id == updated.id }) { targets[i] = updated; save() }
        } }
        .sheet(isPresented: $creating) { TargetEditor(target: nil) { t in targets.append(t); save() } }
    }

    private func save() {
        QuickAddTargets.save(targets)
        if !targets.contains(where: { $0.id == defaultId }) { defaultId = targets.first?.id; QuickAddTargets.defaultId = defaultId }
        changed()
    }

    private func changed() {
        app.updateQuickActions()
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
    }
}

struct TargetEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: QuickAddTarget?
    var onSave: (QuickAddTarget) -> Void

    @State private var name = ""
    @State private var accountId: UUID?
    @State private var boards: [BoardRef] = []
    @State private var boardId = ""
    @State private var lists: [BoardList] = []
    @State private var listId = ""
    @State private var top = false
    @State private var assignMe = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Work inbox)", text: $name)
                if app.accounts.count > 1 {
                    Picker("Account", selection: $accountId) {
                        ForEach(app.accounts) { Text($0.displayLabel).tag(Optional($0.id)) }
                    }
                }
                Picker("Board", selection: $boardId) {
                    Text("Choose…").tag("")
                    ForEach(boards) { Text($0.name).tag($0.id) }
                }
                Picker("List", selection: $listId) {
                    ForEach(lists) { Text($0.name).tag($0.id) }
                }
                .disabled(lists.isEmpty)
                Toggle("Add to top of list", isOn: $top)
                Toggle("Assign to me", isOn: $assignMe)
            }
            .navigationTitle(target == nil ? "New target" : "Edit target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let accountId, let board = boards.first(where: { $0.id == boardId }) else { return }
                        let list = lists.first { $0.id == listId }
                        onSave(QuickAddTarget(id: target?.id ?? UUID(), name: name.isEmpty ? board.name : name, accountId: accountId,
                                              boardId: board.id, boardName: board.name, listId: list?.id, listName: list?.name, top: top, assignMe: assignMe))
                        dismiss()
                    }
                    .disabled(accountId == nil || boardId.isEmpty)
                }
            }
            .onAppear {
                if let target {
                    name = target.name; accountId = target.accountId; boardId = target.boardId
                    listId = target.listId ?? ""; top = target.top; assignMe = target.assignMe
                } else {
                    accountId = app.accounts.first?.id
                }
            }
            .task(id: accountId) {
                guard let accountId, let account = app.account(accountId) else { return }
                boards = BoardDirectory.cached(accountId)
                if let fresh = try? await BoardDirectory.fetch(account) { boards = fresh }
                if !boards.contains(where: { $0.id == boardId }) { boardId = "" }
            }
            .task(id: boardId) {
                guard !boardId.isEmpty, let accountId, let account = app.account(accountId) else { lists = []; return }
                lists = (try? await HackbanAPI(account).board(boardId))?.lists ?? []
                if !lists.contains(where: { $0.id == listId }) { listId = lists.first?.id ?? "" }
            }
        }
    }
}
