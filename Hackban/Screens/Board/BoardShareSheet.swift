import SwiftUI

/// Members, roles, invite by person or email, and the join link (board/members.tsx).
struct BoardShareSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: BoardModel
    @State private var query = ""
    @State private var results: [UserRef] = []
    @State private var role = "normal"

    private var isAdmin: Bool { model.board?.isAdmin ?? false }
    private var isMember: Bool { model.board?.members.contains { $0.userId == model.account.userId } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if isMember {
                    Section {
                        TextField("Name, username or email", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if isAdmin {
                            Picker("Role", selection: $role) {
                                Text("Member").tag("normal")
                                Text("Observer").tag("observer")
                                Text("Admin").tag("admin")
                            }
                        }
                        ForEach(results) { u in
                            Button { add(userId: u.id, email: nil) } label: {
                                HStack {
                                    AvatarView(u, account: model.account, size: 28)
                                    VStack(alignment: .leading) {
                                        Text(u.displayName)
                                        if let s = u.username ?? u.email { Text(s).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if looksLikeEmail(query) && !results.contains(where: { $0.email?.lowercased() == query.lowercased() }) {
                            Button { add(userId: nil, email: query) } label: {
                                SwiftUI.Label("Invite \(query) by email", systemImage: "envelope")
                            }
                        }
                    } header: {
                        Text("Add people")
                    } footer: {
                        Text("People added here join this board only, as guests, unless they're already in the workspace.")
                    }
                }
                Section("Members") {
                    ForEach(model.board?.members ?? []) { m in memberRow(m) }
                }
                if isAdmin { InviteLinkSection(model: model) }
                else if let token = model.board?.inviteToken, let url = model.account.resolve("/join/\(token)") {
                    Section("Invite link") { ShareLink(item: url) { SwiftUI.Label("Share invite link", systemImage: "link") } }
                }
            }
            .navigationTitle("Share board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { results = []; return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let found = (try? await model.api.searchUsers(q)) ?? []
                let existing = Set(model.board?.members.map(\.userId) ?? [])
                results = found.filter { !existing.contains($0.id) }
            }
        }
    }

    private func looksLikeEmail(_ s: String) -> Bool { s.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil }

    private func add(userId: String?, email: String?) {
        let r = isAdmin ? role : "normal"
        query = ""
        model.attempt { [api = model.api, id = model.boardId] in try await api.addBoardMember(id, userId: userId, email: email, role: r) }
    }

    @ViewBuilder
    private func memberRow(_ m: BoardMemberRow) -> some View {
        let isMe = m.userId == model.account.userId
        HStack {
            AvatarView(m.user, account: model.account, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(m.user.displayName + (isMe ? " (you)" : ""))
                    if m.guest == true { Text("Guest").font(.caption2.bold()).padding(.horizontal, 5).background(Color(.tertiarySystemFill), in: Capsule()) }
                }
                Text(m.user.ghost ? m.user.ghostNote : (m.user.username.map { "@\($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isAdmin {
                Menu(roleName(m.role)) {
                    ForEach(["admin", "normal", "observer"], id: \.self) { r in
                        Button(roleName(r)) {
                            model.attempt { [api = model.api, id = model.boardId] in try await api.addBoardMember(id, userId: m.userId, role: r) }
                        }
                    }
                    Divider()
                    Button(isMe ? "Leave board" : "Remove from board", role: .destructive) { remove(m) }
                }
            } else {
                Text(roleName(m.role)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            if isAdmin || isMe {
                Button(isMe ? "Leave" : "Remove", role: .destructive) { remove(m) }
            }
        }
    }

    private func remove(_ m: BoardMemberRow) {
        let leaving = m.userId == model.account.userId
        attempt(app) {
            try await model.api.removeBoardMember(model.boardId, userId: m.userId)
            if leaving { dismiss(); app.homePath = NavigationPath() } else { await model.load() }
        }
    }

    private func roleName(_ r: String) -> String {
        switch r { case "admin": return "Admin"; case "observer": return "Observer"; default: return "Member" }
    }
}

private struct InviteLinkSection: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: BoardModel

    var body: some View {
        let board = model.board
        Section {
            Toggle("Invite link", isOn: Binding(get: { board?.inviteToken != nil }, set: { on in set(enabled: on) }))
            if let token = board?.inviteToken, let url = model.account.resolve("/join/\(token)") {
                Picker("Joins as", selection: Binding(get: { board?.inviteRole ?? "normal" }, set: { set(enabled: true, role: $0) })) {
                    Text("Member").tag("normal")
                    Text("Observer").tag("observer")
                }
                ShareLink(item: url) { SwiftUI.Label("Share link", systemImage: "square.and.arrow.up") }
                Button { UIPasteboard.general.url = url; app.flash("Link copied") } label: { SwiftUI.Label("Copy link", systemImage: "doc.on.doc") }
                Button("Reset link", role: .destructive) { set(enabled: true, reset: true) }
            }
        } header: {
            Text("Invite link")
        } footer: {
            Text("Anyone with the link can log in and join this board as a guest. Links never grant admin.")
        }
    }

    private func set(enabled: Bool, role: String? = nil, reset: Bool = false) {
        attempt(app) {
            let link = try await model.api.setInviteLink(model.boardId, enabled: enabled, role: role, reset: reset)
            model.board?.inviteToken = link.inviteToken
            model.board?.inviteRole = link.inviteRole
        }
    }
}
