import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.accounts.isEmpty {
                OnboardingView()
            } else {
                MainTabs()
            }
        }
        .toasts()
        .sheet(item: $model.quickAdd) { req in
            QuickAddSheet(initialTarget: req.target)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $model.presentedCard) { route in
            CardDetailSheet(route: route)
        }
        .sheet(item: Binding(get: { model.joinToken.map { JoinRequest(account: $0.account, token: $0.token) } }, set: { if $0 == nil { model.joinToken = nil } })) { req in
            JoinBoardSheet(account: req.account, token: req.token)
        }
    }
}

struct JoinRequest: Identifiable {
    var account: UUID
    var token: String
    var id: String { token }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Boards", systemImage: "rectangle.split.3x1", value: AppTab.home) {
                HomeView()
            }
            Tab("My Cards", systemImage: "person.crop.rectangle.stack", value: AppTab.myCards) {
                NavigationStack { MyCardsView() }
            }
            Tab("Notifications", systemImage: "bell", value: AppTab.notifications) {
                NavigationStack { NotificationsView() }
            }
            .badge(model.totalUnread)
            Tab(value: AppTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.brand, Color(hex: "#a3142b")], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 34, height: 72)
                    RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 34, height: 44).frame(maxHeight: 72, alignment: .top)
                }
                .padding(18)
                .glassPanel(cornerRadius: 26)
                VStack(spacing: 8) {
                    Text("Hackban").font(.largeTitle.bold()).foregroundStyle(.white)
                    Text("Boards, lists and cards from every Hackban server you use, in one place.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 32)
                }
                Spacer()
                AddServerForm()
                    .padding(20)
                    .glassPanel(cornerRadius: 28)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
        }
    }
}

/// Server URL field + sign-in button. Used on first launch and in Settings → Add account.
struct AddServerForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var server = "hackban.hackclub.com"
    @State private var busy = false
    @State private var error: String?
    @State private var signIn = SignIn()
    var dismissOnSuccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            TextField("hackban.example.com", text: $server)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(go)
                .padding(12)
                .background(Color(.secondarySystemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button(action: go) {
                HStack {
                    if busy { ProgressView().tint(.white) }
                    Text("Sign in with Hack Club").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .prominentGlassButton()
            .disabled(busy || SignIn.normalize(server) == nil)
            Text("Works with any Hackban server. You'll approve the app on the server's sign-in page.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func go() {
        guard let url = SignIn.normalize(server) else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let account = try await signIn.signIn(to: url)
                model.reloadAccounts()
                model.flash("Signed in to \(account.host)")
                Task { await model.refreshSharedData() }
                if dismissOnSuccess { dismiss() }
            } catch HackbanError.cancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
