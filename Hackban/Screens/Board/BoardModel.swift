import SwiftUI
import WidgetKit

/// One open board: data, live updates and optimistic mutations.
@MainActor @Observable
final class BoardModel {
    let account: Account
    let boardId: String
    var board: Board?
    var error: String?
    var filters = CardFilters()
    var groupByAssignee: Set<String> = []
    @ObservationIgnored weak var app: AppModel?

    @ObservationIgnored private var live: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(account: Account, boardId: String) {
        self.account = account
        self.boardId = boardId
        board = DiskCache.read(Board.self, cacheKey)
    }

    var api: HackbanAPI { HackbanAPI(account) }
    private var cacheKey: String { "board-\(account.id.uuidString)-\(boardId)" }
    var canWrite: Bool { board?.canWrite ?? false }

    func load() async {
        do {
            let b = try await api.board(boardId)
            board = b
            error = nil
            DiskCache.write(b, cacheKey)
            ListCache.store(b, account: account.id)
        } catch {
            if board == nil || (error as? HackbanError)?.isAuth == true { self.error = error.localizedDescription }
            else { app?.report(error) }
        }
    }

    /// Coalesces bursts of live events into one refetch.
    func scheduleReload(after delay: Duration = .milliseconds(250)) {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    func startLive() {
        guard live == nil else { return }
        live = Task { [weak self] in
            var backoff: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    for try await event in self.api.boardEvents(self.boardId) {
                        backoff = 1
                        if event.origin == Shared.clientId { continue }
                        self.scheduleReload()
                    }
                } catch {}
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
                await self.load()
            }
        }
    }

    func stopLive() {
        live?.cancel()
        live = nil
    }

    /// Applies a local change, runs the request, and refetches if it fails.
    func mutate(_ local: (inout Board) -> Void, _ remote: @escaping () async throws -> Void) {
        if var b = board { local(&b); board = b }
        Task {
            do {
                try await remote()
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                app?.report(error)
                await load()
            }
        }
    }

    // MARK: Lookup

    func card(_ id: String) -> BoardCard? { board?.lists.lazy.flatMap(\.cards).first { $0.id == id } }

    func visibleCards(_ list: BoardList) -> [BoardCard] {
        let cards = filters.isActive ? list.cards.filter { filters.matches($0) } : list.cards
        return cards
    }

    private func updateCardLocal(_ id: String, _ change: (inout BoardCard) -> Void) -> (inout Board) -> Void {
        { b in
            for l in b.lists.indices {
                if let i = b.lists[l].cards.firstIndex(where: { $0.id == id }) { change(&b.lists[l].cards[i]); return }
            }
        }
    }

    // MARK: Cards

    func updateCard(_ id: String, _ fields: [String: JSONValue], local: @escaping (inout BoardCard) -> Void) {
        let needsReload = fields["dueComplete"] == .bool(true) && card(id)?.recurrence != nil
        mutate(updateCardLocal(id, local)) { [api] in
            try await api.updateCard(id, fields)
            if needsReload { await self.load() }
        }
    }

    func toggleComplete(_ c: BoardCard) {
        let next = !c.dueComplete
        updateCard(c.id, ["dueComplete": .bool(next)]) { $0.dueComplete = next }
    }

    func archive(_ c: BoardCard) {
        mutate({ b in
            for l in b.lists.indices { b.lists[l].cards.removeAll { $0.id == c.id } }
        }) { [api] in try await api.updateCard(c.id, ["closed": .bool(true)]) }
    }

    func toggleMember(_ c: BoardCard, user: UserRef) {
        let on = !c.members.contains { $0.userId == user.id }
        mutate(updateCardLocal(c.id) { card in
            if on { card.members.append(CardMemberLink(userId: user.id, user: user)) } else { card.members.removeAll { $0.userId == user.id } }
        }) { [api] in try await api.toggleMember(card: c.id, user: user.id, on: on) }
    }

    func toggleLabel(_ c: BoardCard, label: BoardLabel) {
        let on = !c.labels.contains { $0.labelId == label.id }
        mutate(updateCardLocal(c.id) { card in
            if on { card.labels.append(CardLabelLink(labelId: label.id, label: label)) } else { card.labels.removeAll { $0.labelId == label.id } }
        }) { [api] in try await api.toggleLabel(card: c.id, label: label.id, on: on) }
    }

    var me: UserRef? { board?.members.first { $0.userId == account.userId }?.user ?? UserRef(id: account.userId, name: account.name, image: account.image) }

    /// Moves a card to `listId`, after `afterId` (nil = top).
    func moveCard(_ id: String, to listId: String, after afterId: String?) {
        guard let moving = card(id) else { return }
        if moving.listId == listId && afterId == id { return }
        mutate({ b in
            for l in b.lists.indices { b.lists[l].cards.removeAll { $0.id == id } }
            guard let l = b.lists.firstIndex(where: { $0.id == listId }) else { return }
            var c = moving
            c.listId = listId
            let at = afterId.flatMap { a in b.lists[l].cards.firstIndex { $0.id == a }.map { $0 + 1 } } ?? 0
            b.lists[l].cards.insert(c, at: min(at, b.lists[l].cards.count))
        }) { [api] in try await api.moveCard(id, listId: listId, afterId: afterId) }
    }

    func moveCardToEdge(_ c: BoardCard, top: Bool) {
        guard let list = board?.lists.first(where: { $0.id == c.listId }) else { return }
        let others = list.cards.filter { $0.id != c.id }
        moveCard(c.id, to: list.id, after: top ? nil : others.last?.id)
    }

    func addCard(listId: String, title: String, top: Bool) {
        let tmpId = "tmp-\(UUID().uuidString)"
        let tmp = BoardCard(id: tmpId, listId: listId, title: title, description: "", pos: nil, start: nil, due: nil, dueComplete: false,
                            recurrence: nil, coverColor: nil, coverAttachmentId: nil, coverSize: nil, closed: false, shortId: nil,
                            createdAt: .now, updatedAt: .now, labels: [], members: [], _count: nil, blockedBy: [], blocking: [],
                            watching: false, checkTotal: 0, checkDone: 0, coverUrl: nil)
        mutate({ b in
            guard let l = b.lists.firstIndex(where: { $0.id == listId }) else { return }
            if top { b.lists[l].cards.insert(tmp, at: 0) } else { b.lists[l].cards.append(tmp) }
        }) { [api] in
            _ = try await api.createCard(listId: listId, title: title, top: top)
            await self.load()
        }
    }

    // MARK: Lists

    func addList(_ name: String) {
        attempt { [api, boardId] in _ = try await api.createList(boardId: boardId, name: name) }
    }

    func renameList(_ id: String, _ name: String) {
        mutate({ b in if let i = b.lists.firstIndex(where: { $0.id == id }) { b.lists[i].name = name } }) { [api] in
            try await api.updateList(id, name: name)
        }
    }

    func setListColor(_ id: String, _ color: String?) {
        mutate({ b in if let i = b.lists.firstIndex(where: { $0.id == id }) { b.lists[i].color = color } }) { [api] in
            try await api.updateList(id, color: JSONValue.orNull(color))
        }
    }

    func archiveList(_ id: String) {
        mutate({ b in b.lists.removeAll { $0.id == id } }) { [api] in try await api.updateList(id, closed: true) }
    }

    func moveList(_ id: String, after afterId: String?) {
        mutate({ b in
            guard let from = b.lists.firstIndex(where: { $0.id == id }) else { return }
            let l = b.lists.remove(at: from)
            let at = afterId.flatMap { a in b.lists.firstIndex { $0.id == a }.map { $0 + 1 } } ?? 0
            b.lists.insert(l, at: min(at, b.lists.count))
        }) { [api] in try await api.moveList(id, afterId: afterId) }
    }

    func sort(_ list: BoardList, by sort: CardSort) {
        var sorted = sort.sorted(list.cards)
        if groupByAssignee.contains(list.id) { sorted = CardSort.groupByAssignee(sorted) }
        let ids = sorted.map(\.id)
        mutate({ b in if let i = b.lists.firstIndex(where: { $0.id == list.id }) { b.lists[i].cards = sorted } }) { [api] in
            try await api.sortCards(list.id, ids: ids)
        }
    }

    /// Runs a request and reloads the board afterwards (for changes we don't model locally).
    func attempt(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work(); await load(); WidgetCenter.shared.reloadAllTimelines() } catch { app?.report(error) }
        }
    }
}
