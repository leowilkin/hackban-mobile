import SwiftUI
import WidgetKit

@MainActor @Observable
final class CardDetailModel {
    let account: Account
    let cardId: String
    var card: CardDetail?
    var board: Board?
    var error: String?
    weak var app: AppModel?

    init(account: Account, cardId: String) {
        self.account = account
        self.cardId = cardId
    }

    var api: HackbanAPI { HackbanAPI(account) }
    var canWrite: Bool { board?.canWrite ?? false }
    var me: UserRef { board?.members.first { $0.userId == account.userId }?.user ?? UserRef(id: account.userId, name: account.name, image: account.image) }
    var boardCards: [BoardCard] { board?.lists.flatMap(\.cards) ?? [] }

    func load() async {
        do {
            let c = try await api.card(cardId)
            card = c
            error = nil
            if board?.id != c.list.boardId || board == nil {
                board = try? await api.board(c.list.boardId)
            }
        } catch {
            if card == nil { self.error = error.localizedDescription } else { app?.report(error) }
        }
    }

    func reloadBoard() async {
        guard let id = card?.list.boardId else { return }
        board = try? await api.board(id)
    }

    /// Local change first, then the request; reloads from the server afterwards either way.
    func mutate(_ local: ((inout CardDetail) -> Void)? = nil, _ remote: @escaping (HackbanAPI) async throws -> Void) {
        if let local, var c = card { local(&c); card = c }
        Task {
            do {
                try await remote(api)
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                app?.report(error)
            }
            await load()
        }
    }

    func update(_ fields: [String: JSONValue], local: ((inout CardDetail) -> Void)? = nil) {
        mutate(local) { [cardId] api in try await api.updateCard(cardId, fields) }
    }
}
