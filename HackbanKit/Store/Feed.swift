import Foundation

/// A card assigned to me, tagged with its account (for merged, all-accounts views).
public struct FeedCard: Codable, Hashable, Identifiable, Sendable {
    public var accountId: UUID
    public var accountLabel: String
    public var card: MyCard

    public var id: String { "\(accountId.uuidString)|\(card.id)" }
    public var scoped: ScopedID { ScopedID(account: accountId, id: card.id) }
}

/// "My cards" across accounts: fetched by the app, read by widgets and intents.
public enum MyCardsFeed {
    static func key(_ account: UUID) -> String { "mycards-\(account.uuidString)" }

    public static func cached(_ accounts: [Account] = AccountRepository.load()) -> [FeedCard] {
        sort(accounts.flatMap { a in
            (DiskCache.read([MyCard].self, key(a.id)) ?? []).map { FeedCard(accountId: a.id, accountLabel: a.displayLabel, card: $0) }
        })
    }

    public static func store(_ cards: [MyCard], for account: UUID) { DiskCache.write(cards, key(account)) }

    public static func lastUpdated(_ account: UUID) -> Date? { DiskCache.modified(key(account)) }

    /// Fetches every account in parallel; accounts that fail fall back to their cache.
    public static func fetch(_ accounts: [Account] = AccountRepository.load()) async -> [FeedCard] {
        await withTaskGroup(of: [FeedCard].self) { group in
            for a in accounts {
                group.addTask {
                    let cards: [MyCard]
                    if !a.needsReauth, let fresh = try? await HackbanAPI(a).myCards() {
                        store(fresh, for: a.id)
                        cards = fresh
                    } else {
                        cards = DiskCache.read([MyCard].self, key(a.id)) ?? []
                    }
                    return cards.map { FeedCard(accountId: a.id, accountLabel: a.displayLabel, card: $0) }
                }
            }
            var all: [FeedCard] = []
            for await chunk in group { all += chunk }
            return sort(all)
        }
    }

    /// Open cards first, by due date (undated last), then most recently updated.
    public static func sort(_ cards: [FeedCard]) -> [FeedCard] {
        cards.sorted { a, b in
            if a.card.dueComplete != b.card.dueComplete { return !a.card.dueComplete }
            let x = a.card.due ?? .distantFuture, y = b.card.due ?? .distantFuture
            if x != y { return x < y }
            return (a.card.updatedAt ?? .distantPast) > (b.card.updatedAt ?? .distantPast)
        }
    }

    /// Marks a card complete (or not) in every cache, so widgets reflect it before the next fetch.
    public static func setComplete(_ id: ScopedID, _ complete: Bool) {
        guard var cards = DiskCache.read([MyCard].self, key(id.account)) else { return }
        if let i = cards.firstIndex(where: { $0.id == id.id }) {
            cards[i].dueComplete = complete
            store(cards, for: id.account)
        }
    }
}
