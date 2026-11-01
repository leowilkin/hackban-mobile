import AuthenticationServices
import SwiftUI
import UIKit
import WidgetKit

enum AccountScope: Hashable {
    case all
    case one(UUID)
}

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

struct BoardRoute: Hashable, Identifiable {
    var account: UUID
    var boardId: String
    var id: String { "\(account)|\(boardId)" }
}

struct CardRoute: Hashable, Identifiable {
    var account: UUID
    var cardId: String
    var id: String { "\(account)|\(cardId)" }
}

enum AppTab: Hashable { case home, myCards, notifications, search }

/// App-wide state: accounts, scope, navigation, transient banners.
@MainActor @Observable
final class AppModel {
    var accounts: [Account] = AccountRepository.load()
    var scope: AccountScope = .all { didSet { Shared.defaults.set(scopeKey, forKey: "scope") } }
    var tab: AppTab = .home
    var homePath = NavigationPath()
    var presentedCard: CardRoute?
    var quickAdd: QuickAddRequest?
    var joinToken: (account: UUID, token: String)?
    var toast: String?
    var unread: [UUID: Int] = [:]
    var theme: Theme = Theme(rawValue: Shared.defaults.string(forKey: "theme") ?? "") ?? .system {
        didSet { Shared.defaults.set(theme.rawValue, forKey: "theme") }
    }

    struct QuickAddRequest: Identifiable { let id = UUID(); var target: UUID? }

    init() {
        if let s = Shared.defaults.string(forKey: "scope"), let id = UUID(uuidString: s), accounts.contains(where: { $0.id == id }) {
            scope = .one(id)
        }
    }

    private var scopeKey: String? { if case .one(let id) = scope { return id.uuidString } else { return nil } }

    var scopedAccounts: [Account] {
        switch scope {
        case .all: return accounts
        case .one(let id): return accounts.filter { $0.id == id }
        }
    }

    var showAccountBadges: Bool { accounts.count > 1 && scope == .all }

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
    func api(_ id: UUID) -> HackbanAPI? { account(id).map(HackbanAPI.init) }

    func reloadAccounts() {
        accounts = AccountRepository.load()
        if case .one(let id) = scope, !accounts.contains(where: { $0.id == id }) { scope = .all }
        updateQuickActions()
    }

    func flash(_ message: String) {
        toast = message
        Task { try? await Task.sleep(for: .seconds(2.5)); if toast == message { toast = nil } }
    }

    func report(_ error: Error) {
        if let e = error as? HackbanError, e == .cancelled { return }
        if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
        if let e = error as? HackbanError, e.isAuth { reloadAccounts() }
        flash(error.localizedDescription)
    }

    // MARK: Accounts

    func updateAccount(_ id: UUID, _ change: (inout Account) -> Void) {
        AccountRepository.update(id, change)
        reloadAccounts()
    }

    func remove(_ account: Account) {
        Task { try? await HackbanAPI(account).revokeApp(account.clientId) }
        TokenStore.delete(account.id)
        DiskCache.remove(prefix: "mycards-\(account.id.uuidString)")
        DiskCache.remove(prefix: "boards-\(account.id.uuidString)")
        DiskCache.remove(prefix: "lists-\(account.id.uuidString)")
        AccountRepository.save(AccountRepository.load().filter { $0.id != account.id })
        QuickAddTargets.save(QuickAddTargets.load().filter { $0.accountId != account.id })
        reloadAccounts()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Routing

    func open(_ url: URL) {
        if url.scheme == Shared.urlScheme {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
            switch url.host() {
            case "quickadd": quickAdd = QuickAddRequest(target: v("target").flatMap(UUID.init(uuidString:)))
            case "board":
                if let a = v("account").flatMap(UUID.init(uuidString:)), let id = v("id") { openBoard(BoardRoute(account: a, boardId: id)) }
            case "card":
                if let a = v("account").flatMap(UUID.init(uuidString:)), let id = v("id") { presentedCard = CardRoute(account: a, cardId: id) }
            case "mycards": tab = .myCards
            default: break
            }
            return
        }
        openWebLink(url)
    }

    /// https://<instance>/b/<id>, /c/<id>, /join/<token> for a signed-in instance.
    @discardableResult
    func openWebLink(_ url: URL) -> Bool {
        guard let account = accounts.first(where: { $0.baseURL.host() == url.host() }) else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return false }
        switch parts[0] {
        case "b": openBoard(BoardRoute(account: account.id, boardId: parts[1]))
        case "c": presentedCard = CardRoute(account: account.id, cardId: parts[1])
        case "join": joinToken = (account.id, parts[1])
        default: return false
        }
        return true
    }

    func openBoard(_ route: BoardRoute) {
        tab = .home
        homePath = NavigationPath()
        homePath.append(route)
    }

    func consumePendingRoute() {
        if let url = AppSignals.take() { open(url) }
    }

    // MARK: Quick actions (long-press the app icon)

    func updateQuickActions() {
        var items = QuickAddTargets.load().prefix(3).map { t in
            UIApplicationShortcutItem(type: "quickadd", localizedTitle: "Add to \(t.name)", localizedSubtitle: t.subtitle,
                                      icon: UIApplicationShortcutIcon(systemImageName: "plus.circle"), userInfo: ["target": t.id.uuidString as NSString])
        }
        if items.isEmpty {
            items.append(UIApplicationShortcutItem(type: "quickadd", localizedTitle: "Quick Add", localizedSubtitle: nil,
                                                   icon: UIApplicationShortcutIcon(systemImageName: "plus.circle"), userInfo: nil))
        }
        items.append(UIApplicationShortcutItem(type: "mycards", localizedTitle: "My Cards", localizedSubtitle: nil,
                                               icon: UIApplicationShortcutIcon(systemImageName: "person.crop.rectangle.stack"), userInfo: nil))
        UIApplication.shared.shortcutItems = items
    }

    func handle(_ item: UIApplicationShortcutItem) {
        switch item.type {
        case "quickadd": quickAdd = QuickAddRequest(target: (item.userInfo?["target"] as? String).flatMap(UUID.init(uuidString:)))
        case "mycards": tab = .myCards
        default: break
        }
    }

    // MARK: Background refresh

    func refreshSharedData() async {
        _ = await MyCardsFeed.fetch(accounts)
        for a in accounts where !a.needsReauth { _ = try? await BoardDirectory.fetch(a) }
        await refreshUnread()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func refreshUnread() async {
        for a in accounts where !a.needsReauth {
            if let n = try? await HackbanAPI(a).notifications() { unread[a.id] = n.filter { !$0.read }.count }
        }
    }

    var totalUnread: Int { scopedAccounts.reduce(0) { $0 + (unread[$1.id] ?? 0) } }
}

/// Signs in to a Hackban server with OAuth (PKCE) in a system web sheet.
@MainActor
final class SignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s), c.host != nil else { return nil }
        c.path = ""; c.query = nil; c.fragment = nil
        return c.url
    }

    /// Full flow; returns the stored account. `replacing` re-authenticates an existing account in place.
    func signIn(to base: URL, replacing existing: Account? = nil) async throws -> Account {
        let server = try await OAuthServer.discover(base)
        let clientId = try await server.registerClient()
        let verifier = PKCE.verifier()
        let state = PKCE.verifier()
        let url = server.authorizeURL(clientId: clientId, challenge: PKCE.challenge(verifier), state: state)

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: Shared.urlScheme) { url, error in
                if let url { cont.resume(returning: url) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: HackbanError.cancelled) }
                else { cont.resume(throwing: error ?? HackbanError.cancelled) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            s.start()
        }
        let q = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = q.first(where: { $0.name == "error" })?.value {
            throw err == "access_denied" ? HackbanError.cancelled : HackbanError.invalidServer("Sign-in failed: \(err)")
        }
        guard q.first(where: { $0.name == "state" })?.value == state, let code = q.first(where: { $0.name == "code" })?.value else {
            throw HackbanError.invalidServer("Sign-in failed: bad response from the server.")
        }
        let tokens = try await server.exchange(code: code, verifier: verifier, clientId: clientId)

        var all = AccountRepository.load()
        let id = existing?.id ?? UUID()
        TokenStore.write(tokens, for: id)
        var account = existing ?? Account(id: id, baseURL: base, userId: "", name: nil, email: nil, image: nil, clientId: clientId, tint: all.count % AccountTint.all.count)
        account.clientId = clientId
        account.needsReauth = false
        let profile = try await HackbanAPI(account).profile()
        account.userId = profile.id
        account.name = profile.name
        account.email = profile.email
        account.image = profile.image
        if let dup = all.firstIndex(where: { $0.id != id && $0.baseURL == base && $0.userId == profile.id }) {
            // Same person on the same server: replace the old entry rather than listing it twice.
            TokenStore.delete(all[dup].id)
            all.remove(at: dup)
        }
        if let i = all.firstIndex(where: { $0.id == id }) { all[i] = account } else { all.append(account) }
        AccountRepository.save(all)
        return account
    }
}

enum AccountTint {
    static let all: [Color] = [Palette.brand, Color(hex: "#0c66e4"), Color(hex: "#1f845a"), Color(hex: "#6e5dc6"), Color(hex: "#c25100"), Color(hex: "#227d9b")]
    static func color(_ i: Int) -> Color { all[((i % all.count) + all.count) % all.count] }
}
