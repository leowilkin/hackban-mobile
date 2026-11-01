import Foundation

// Shapes of the hackban tRPC outputs (src/server/api/routers/*). Fields the server may drop or add
// later are optional so a server upgrade degrades the UI instead of failing to decode.

public struct UserRef: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var image: String?
    public var username: String?
    public var email: String?
    public var isGhost: Bool?
    public var invitedEmail: String?

    public init(id: String, name: String? = nil, image: String? = nil, username: String? = nil) {
        self.id = id; self.name = name; self.image = image; self.username = username
    }

    public var displayName: String { name ?? username ?? email ?? "Unknown" }
    public var ghost: Bool { isGhost ?? false }
    /// Sub-line for a placeholder member who hasn't logged in yet.
    public var ghostNote: String { invitedEmail != nil ? "Invited, hasn't logged in yet" : "Imported from Trello" }
}

public struct BoardLabel: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var boardId: String?
    public var name: String
    public var color: String?

    public init(id: String, boardId: String? = nil, name: String, color: String?) {
        self.id = id; self.boardId = boardId; self.name = name; self.color = color
    }
}

public struct CardLabelLink: Codable, Hashable, Sendable {
    public var labelId: String
    public var label: BoardLabel
}

public struct CardMemberLink: Codable, Hashable, Sendable {
    public var userId: String
    public var user: UserRef
}

public struct Counts: Codable, Hashable, Sendable {
    public var comments: Int?
    public var attachments: Int?
    public var members: Int?
}

public struct TitleRef: Codable, Hashable, Sendable { public var title: String }
public struct BlockerRef: Codable, Hashable, Sendable { public var blocker: TitleRef }
public struct BlockedRef: Codable, Hashable, Sendable { public var blocked: TitleRef }

/// A card as it appears on the board (board.get).
public struct BoardCard: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var listId: String
    public var title: String
    public var description: String?
    public var pos: String?
    public var start: Date?
    public var due: Date?
    public var dueComplete: Bool
    public var recurrence: String?
    public var coverColor: String?
    public var coverAttachmentId: String?
    public var coverSize: String?
    public var closed: Bool?
    public var shortId: Int?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var labels: [CardLabelLink]
    public var members: [CardMemberLink]
    public var _count: Counts?
    public var blockedBy: [BlockerRef]?
    public var blocking: [BlockedRef]?
    public var watching: Bool?
    public var checkTotal: Int?
    public var checkDone: Int?
    public var coverUrl: String?

    public var commentCount: Int { _count?.comments ?? 0 }
    public var attachmentCount: Int { _count?.attachments ?? 0 }
    public var hasDescription: Bool { !(description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var isBlocked: Bool { !(blockedBy ?? []).isEmpty }
    public var isBlocking: Bool { !(blocking ?? []).isEmpty }
}

public struct BoardList: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var boardId: String
    public var name: String
    public var pos: String?
    public var color: String?
    public var closed: Bool?
    public var cards: [BoardCard]
}

public struct BoardMemberRow: Codable, Hashable, Identifiable, Sendable {
    public var boardId: String?
    public var userId: String
    public var role: String
    public var user: UserRef
    public var guest: Bool?
    public var id: String { userId }
}

public struct WorkspaceRef: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String
}

public struct Board: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var workspaceId: String
    public var background: String
    public var bgImage: String?
    public var visibility: String
    public var closed: Bool
    public var inviteRole: String?
    public var inviteToken: String?
    public var workspace: WorkspaceRef?
    public var members: [BoardMemberRow]
    public var labels: [BoardLabel]
    public var lists: [BoardList]
    public var starred: Bool
    public var myRole: String

    public var canWrite: Bool { myRole != "observer" }
    public var isAdmin: Bool { myRole == "admin" }
}

/// Board tile data from workspace.list, board.recent, board.guestBoards, board.closed, search.
public struct BoardSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var background: String
    public var bgImage: String?
    public var visibility: String?
    public var closed: Bool?
    public var workspaceId: String?
    public var starred: Bool?
    public var workspace: WorkspaceRef?
    public var lastActive: Date?
    public var updatedAt: Date?
    public var _count: Counts?
}

public struct Workspace: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var logo: String?
    public var boards: [BoardSummary]
}

public struct WorkspaceMemberRow: Codable, Hashable, Identifiable, Sendable {
    public var workspaceId: String
    public var userId: String
    public var role: String
    public var user: UserRef
    public var id: String { userId }
}

public struct WorkspaceDetail: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var logo: String?
    public var members: [WorkspaceMemberRow]
    public var boards: [BoardSummary]
    public var myRole: String
}

public struct AutoJoinRule: Codable, Hashable, Identifiable, Sendable {
    public struct Creator: Codable, Hashable, Sendable { public var name: String? }
    public var id: String
    public var workspaceId: String
    public var domain: String
    public var role: String
    public var createdAt: Date?
    public var createdBy: Creator?
    public var memberCount: Int?
}

public struct CheckItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var checklistId: String
    public var name: String
    public var pos: String?
    public var complete: Bool
    public var due: Date?
    public var memberId: String?
    public var member: UserRef?
}

public struct Checklist: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var cardId: String?
    public var name: String
    public var pos: String?
    public var items: [CheckItem]
}

public struct Attachment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var cardId: String?
    public var uploaderId: String?
    public var name: String
    public var url: String
    public var mimeType: String?
    public var size: Int?
    public var isUpload: Bool?
    public var createdAt: Date?
    public var uploader: UserRef?

    public var isImage: Bool { (mimeType ?? "").hasPrefix("image/") }
}

public struct Comment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var cardId: String?
    public var authorId: String
    public var text: String
    public var createdAt: Date
    public var editedAt: Date?
    public var author: UserRef
}

public struct IdTitle: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
}

public struct IdName: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
}

public struct Activity: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var boardId: String?
    public var cardId: String?
    public var actorId: String?
    public var type: String
    public var data: [String: JSONValue]?
    public var createdAt: Date
    public var actor: UserRef?
    public var card: IdTitle?
    public var board: IdName?
}

public struct ActivityPage: Codable, Hashable, Sendable {
    public var items: [Activity]
    public var next: String?
}

public struct Dependency: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var dueComplete: Bool
}

public struct CardListRef: Codable, Hashable, Sendable {
    public struct BoardName: Codable, Hashable, Sendable { public var name: String }
    public var id: String
    public var name: String
    public var boardId: String
    public var board: BoardName?
}

/// Full card (card.get).
public struct CardDetail: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var listId: String
    public var title: String
    public var description: String
    public var start: Date?
    public var due: Date?
    public var dueComplete: Bool
    public var recurrence: String?
    public var coverColor: String?
    public var coverAttachmentId: String?
    public var coverSize: String?
    public var closed: Bool
    public var createdAt: Date?
    public var list: CardListRef
    public var labels: [CardLabelLink]
    public var members: [CardMemberLink]
    public var checklists: [Checklist]
    public var attachments: [Attachment]
    public var comments: [Comment]
    public var activities: [Activity]
    public var watching: Bool
    public var blockedBy: [Dependency]
    public var blocking: [Dependency]
}

public struct NotificationItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var data: [String: JSONValue]?
    public var read: Bool
    public var createdAt: Date

    public func value(_ key: String) -> String? { data?[key]?.string }
}

public struct SearchCard: Codable, Hashable, Identifiable, Sendable {
    public struct ListRef: Codable, Hashable, Sendable {
        public var name: String
        public var board: IdName
    }
    public var id: String
    public var title: String
    public var listId: String?
    public var due: Date?
    public var dueComplete: Bool?
    public var closed: Bool?
    public var list: ListRef
}

public struct SearchResults: Codable, Hashable, Sendable {
    public var boards: [BoardSummary]
    public var cards: [SearchCard]
}

public struct MyCard: Codable, Hashable, Identifiable, Sendable {
    public struct BoardRef: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var background: String?
        public var bgImage: String?
    }
    public struct ListRef: Codable, Hashable, Sendable {
        public var name: String
        public var board: BoardRef
    }
    public var id: String
    public var listId: String
    public var title: String
    public var due: Date?
    public var start: Date?
    public var dueComplete: Bool
    public var recurrence: String?
    public var updatedAt: Date?
    public var list: ListRef
    public var labels: [CardLabelLink]
}

public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var email: String?
    public var image: String?
    public var avatarKey: String?
    public var username: String?
    public var isAdmin: Bool?
    public var createdAt: Date?
}

public struct ConnectedApp: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var lastActive: Date?
}

public struct ArchivedCard: Codable, Hashable, Identifiable, Sendable {
    public struct ListName: Codable, Hashable, Sendable { public var name: String }
    public var id: String
    public var title: String
    public var listId: String
    public var list: ListName?
    public var updatedAt: Date?
}

public struct ArchivedList: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var boardId: String
}

public struct ArchivedItems: Codable, Hashable, Sendable {
    public var cards: [ArchivedCard]
    public var lists: [ArchivedList]
}

public struct InvitePreview: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var background: String
    public var bgImage: String?
    public var closed: Bool?
    public var inviteRole: String
    public var workspace: WorkspaceRef?
    public var _count: Counts?
    public var alreadyMember: Bool
}

public struct InviteLink: Codable, Hashable, Sendable {
    public var inviteToken: String?
    public var inviteRole: String
}

/// Anything that comes back with an id (card.create, board.create, list.create, ...).
public struct Created: Codable, Hashable, Sendable {
    public var id: String
}

public struct JoinResult: Codable, Hashable, Sendable { public var boardId: String }

/// Live-update event from board.onEvent.
public struct BoardEvent: Codable, Hashable, Sendable {
    public var boardId: String
    public var cardId: String?
    public var origin: String?
    public var kind: String
}

public enum Recurrence: String, CaseIterable, Identifiable, Sendable {
    case daily, weekdays, weekly, monthly, yearly
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekdays: return "Every weekday"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}
