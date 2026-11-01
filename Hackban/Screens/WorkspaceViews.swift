import PhotosUI
import SwiftUI

struct WorkspaceSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let account: Account
    let workspaceId: String

    @State private var ws: WorkspaceDetail?
    @State private var rules: [AutoJoinRule] = []
    @State private var name = ""
    @State private var description = ""
    @State private var query = ""
    @State private var results: [UserRef] = []
    @State private var newDomain = ""
    @State private var logoItem: PhotosPickerItem?
    @State private var confirmName = ""
    @State private var confirmDelete = false
    @State private var sort = 0

    private var api: HackbanAPI { HackbanAPI(account) }
    private var isAdmin: Bool { ws?.myRole == "admin" }

    var body: some View {
        Form {
            if let ws {
                Section {
                    HStack(spacing: 14) {
                        WorkspaceLogo(name: ws.name, logo: ws.logo, account: account, size: 56)
                        if isAdmin {
                            VStack(alignment: .leading, spacing: 6) {
                                PhotosPicker(selection: $logoItem, matching: .images) { Text("Change logo") }
                                if ws.logo != nil {
                                    Button("Remove logo", role: .destructive) { run { try await api.removeLogo(workspaceId) } }
                                }
                            }
                        }
                    }
                    TextField("Name", text: $name).disabled(!isAdmin)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...6).disabled(!isAdmin)
                    if isAdmin && (name != ws.name || description != (ws.description ?? "")) {
                        Button("Save") { let n = name, d = description; run { try await api.updateWorkspace(workspaceId, name: n, description: d) } }
                    }
                }

                Section {
                    Picker("Sort", selection: $sort) {
                        Text("Name").tag(0)
                        Text("Recently active").tag(1)
                    }
                    .pickerStyle(.segmented)
                    ForEach(sortedBoards(ws.boards)) { b in
                        Button { app.openBoard(BoardRoute(account: account.id, boardId: b.id)) } label: {
                            HStack {
                                BoardBackground(b.background, image: b.bgImage).frame(width: 40, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
                                VStack(alignment: .leading) {
                                    Text(b.name + (b.closed == true ? " (closed)" : ""))
                                    Text([b.visibility?.capitalized, b._count?.members.map { "\($0) members" }, b.lastActive.map { Fmt.relative($0) }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if b.starred == true { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("Boards") }

                Section {
                    TextField("Add by name or email", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    ForEach(results) { u in
                        Button { addMember(userId: u.id, email: nil) } label: {
                            HStack { AvatarView(u, account: account, size: 26); Text(u.displayName) }
                        }
                        .buttonStyle(.plain)
                    }
                    if query.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil {
                        Button { addMember(userId: nil, email: query) } label: { SwiftUI.Label("Invite \(query) by email", systemImage: "envelope") }
                    }
                    ForEach(ws.members) { m in memberRow(m) }
                } header: { Text("Members (\(ws.members.count))") }

                Section {
                    ForEach(rules) { r in
                        VStack(alignment: .leading) {
                            Text("@\(r.domain) → \(r.role == "admin" ? "Admin" : "Member")")
                            Text("\(r.memberCount ?? 0) members · added by \(r.createdBy?.name ?? "someone")").font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            if isAdmin { Button("Remove", role: .destructive) { run { try await api.removeAutoJoin(workspaceId, ruleId: r.id) } } }
                        }
                    }
                    if isAdmin {
                        HStack {
                            TextField("yourdomain.com", text: $newDomain).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            Button("Add") { let d = newDomain; newDomain = ""; run { try await api.addAutoJoin(workspaceId, domain: d) } }
                                .disabled(newDomain.isEmpty)
                        }
                    }
                } header: { Text("Auto-join by email domain") } footer: {
                    Text("Anyone who logs in with an email on these domains joins as a member. Workspace admins can add their own domain only.")
                }

                Section {
                    Button("Leave workspace", role: .destructive) {
                        run {
                            try await api.removeWorkspaceMember(workspaceId, userId: account.userId)
                            dismiss()
                        }
                    }
                    if isAdmin {
                        Button("Delete workspace", role: .destructive) { confirmName = ""; confirmDelete = true }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(ws?.name ?? "Workspace")
        .task { await load() }
        .refreshable { await load() }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            let existing = Set(ws?.members.map(\.userId) ?? [])
            results = ((try? await api.searchUsers(q)) ?? []).filter { !existing.contains($0.id) }
        }
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            run {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let t = item.supportedContentTypes.first
                try await api.uploadLogo(workspaceId, .init(name: "logo.\(t?.preferredFilenameExtension ?? "png")", mimeType: t?.preferredMIMEType ?? "image/png", data: data))
            }
        }
        .alert("Delete \(ws?.name ?? "")?", isPresented: $confirmDelete) {
            TextField("Type the workspace name", text: $confirmName)
            Button("Delete", role: .destructive) {
                let n = confirmName
                run {
                    try await api.deleteWorkspace(workspaceId, confirmName: n)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every board in it, for everyone. Type the name to confirm.")
        }
    }

    private func sortedBoards(_ boards: [BoardSummary]) -> [BoardSummary] {
        sort == 0 ? boards.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            : boards.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    @ViewBuilder
    private func memberRow(_ m: WorkspaceMemberRow) -> some View {
        let isMe = m.userId == account.userId
        HStack {
            AvatarView(m.user, account: account, size: 30)
            VStack(alignment: .leading) {
                Text(m.user.displayName + (isMe ? " (you)" : ""))
                Text(m.user.ghost ? m.user.ghostNote : (m.user.email ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isAdmin {
                Menu(m.role == "admin" ? "Admin" : "Member") {
                    Button("Admin") { run { try await api.addWorkspaceMember(workspaceId, userId: m.userId, role: "admin") } }
                    Button("Member") { run { try await api.addWorkspaceMember(workspaceId, userId: m.userId, role: "normal") } }
                    Divider()
                    Button("Remove", role: .destructive) { run { try await api.removeWorkspaceMember(workspaceId, userId: m.userId) } }
                }
            } else {
                Text(m.role == "admin" ? "Admin" : "Member").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func addMember(userId: String?, email: String?) {
        query = ""
        run { try await api.addWorkspaceMember(workspaceId, userId: userId, email: email, role: "normal") }
    }

    private func load() async {
        do {
            let w = try await api.workspace(workspaceId)
            ws = w
            name = w.name
            description = w.description ?? ""
            rules = (try? await api.autoJoins(workspaceId)) ?? []
        } catch { app.report(error) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        attempt(app) { try await work(); await load() }
    }
}

// MARK: Create / closed / join

struct CreateBoardSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let account: Account
    let workspaces: [Workspace]
    var onCreated: (BoardRoute) -> Void

    @State private var name = ""
    @State private var workspaceId = ""
    @State private var background = Palette.boardGradients[0]
    @State private var visibility = "workspace"
    @State private var template = "basic"
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BoardBackground.fill(background)
                        .frame(height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topLeading) { Text(name.isEmpty ? "Board title" : name).font(.headline).foregroundStyle(.white).padding(12) }
                        .listRowInsets(EdgeInsets())
                }
                Section("Background") { BackgroundPicker(selected: background) { background = $0 } }
                Section {
                    TextField("Board title", text: $name)
                    Picker("Workspace", selection: $workspaceId) { ForEach(workspaces) { Text($0.name).tag($0.id) } }
                    Picker("Visibility", selection: $visibility) {
                        Text("Private").tag("private")
                        Text("Workspace").tag("workspace")
                        Text("Public").tag("public")
                    }
                    Picker("Start with", selection: $template) {
                        Text("To Do, Doing, Done").tag("basic")
                        Text("Empty board").tag("empty")
                    }
                }
            }
            .navigationTitle("New board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        busy = true
                        attempt(app) {
                            defer { busy = false }
                            let b = try await HackbanAPI(account).createBoard(name: name, workspaceId: workspaceId, background: background, visibility: visibility, template: template)
                            dismiss()
                            onCreated(BoardRoute(account: account.id, boardId: b.id))
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || workspaceId.isEmpty || busy)
                }
            }
            .onAppear { workspaceId = workspaces.first?.id ?? "" }
        }
    }
}

struct CreateWorkspaceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let account: Account
    var onCreated: () -> Void
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form { TextField("Workspace name", text: $name) }
                .navigationTitle("New workspace")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            attempt(app) { _ = try await HackbanAPI(account).createWorkspace(name: name); onCreated(); dismiss() }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

struct ClosedBoardsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let account: Account
    var onChange: () -> Void
    @State private var boards: [BoardSummary]?

    var body: some View {
        NavigationStack {
            List {
                if boards?.isEmpty == true { Text("No closed boards").foregroundStyle(.secondary) }
                ForEach(boards ?? []) { b in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(b.name)
                            if let w = b.workspace?.name { Text(w).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Reopen") { run { try await HackbanAPI(account).updateBoard(b.id, closed: false) } }.glassButton()
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { run { try await HackbanAPI(account).deleteBoard(b.id) } }
                    }
                }
            }
            .navigationTitle("Closed boards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async { boards = (try? await HackbanAPI(account).closedBoards()) ?? [] }

    private func run(_ work: @escaping () async throws -> Void) {
        attempt(app) { try await work(); await load(); onChange() }
    }
}

struct JoinBoardSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let account: UUID
    let token: String
    @State private var preview: InvitePreview?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let preview {
                    BoardTile(name: preview.name, background: preview.background, image: preview.bgImage)
                        .frame(maxWidth: 320)
                    Text("\(preview.workspace?.name ?? "") · \(preview._count?.members ?? 0) members").foregroundStyle(.secondary)
                    if preview.alreadyMember {
                        Button("Open board") { dismiss(); app.openBoard(BoardRoute(account: account, boardId: preview.id)) }.prominentGlassButton()
                    } else {
                        Text("You'll join as a guest \(preview.inviteRole == "observer" ? "observer" : "member") of this board only.")
                            .multilineTextAlignment(.center).font(.footnote)
                        Button("Join board") {
                            attempt(app) {
                                guard let api = app.api(account) else { return }
                                let r = try await api.joinByInvite(token)
                                dismiss()
                                app.openBoard(BoardRoute(account: account, boardId: r.boardId))
                            }
                        }
                        .prominentGlassButton()
                    }
                } else if let error {
                    EmptyState(title: "Invite link", systemImage: "link.badge.plus", message: error)
                } else {
                    ProgressView()
                }
            }
            .padding()
            .navigationTitle("Join board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do { preview = try await app.api(account)?.invitePreview(token) } catch { self.error = error.localizedDescription }
            }
        }
        .presentationDetents([.medium])
    }
}
