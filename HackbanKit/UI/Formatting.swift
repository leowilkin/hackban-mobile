import SwiftUI

/// Due-date state for badges (matches the web card front).
public enum DueState: Sendable {
    case complete, overdue, soon, later

    public static func of(due: Date, complete: Bool, now: Date = .now) -> DueState {
        if complete { return .complete }
        if due < now { return .overdue }
        if due.timeIntervalSince(now) < 24 * 3600 { return .soon }
        return .later
    }

    public var background: Color {
        switch self {
        case .complete: return Color(hex: "#1f845a")
        case .overdue: return Color(hex: "#c9372c")
        case .soon: return Color(hex: "#f5cd47")
        case .later: return Color(.tertiarySystemFill)
        }
    }

    public var foreground: Color {
        switch self {
        case .complete, .overdue: return .white
        case .soon: return Color(hex: "#172b4d")
        case .later: return .primary
        }
    }
}

public enum Fmt {
    /// "Today 5:00 PM", "Tomorrow", "Mon 3 Nov", "3 Nov 2027".
    public static func due(_ date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let hasTime = !(cal.component(.hour, from: date) == 0 && cal.component(.minute, from: date) == 0)
        if cal.isDateInToday(date) { return hasTime ? "Today \(time)" : "Today" }
        if cal.isDateInTomorrow(date) { return hasTime ? "Tomorrow \(time)" : "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    public static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    public static func bytes(_ n: Int?) -> String {
        guard let n else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// Human-readable activity sentences (port of board/activity.tsx).
public enum ActivityText {
    public static func describe(_ a: Activity, onCard: Bool) -> String {
        let card = (a.card != nil && !onCard) ? "\u{201C}\(a.card!.title)\u{201D}" : "this card"
        let d = a.data ?? [:]
        func s(_ k: String) -> String { d[k]?.string ?? "" }
        func date(_ k: String, _ style: Date.FormatStyle) -> String { d[k]?.date?.formatted(style) ?? "" }
        switch a.type {
        case "createBoard": return "created this board"
        case "importBoard": return "imported this board from Trello"
        case "renameBoard": return "renamed this board to \(s("name"))"
        case "closeBoard": return "closed this board"
        case "reopenBoard": return "reopened this board"
        case "moveBoard": return "moved this board from \(s("from")) to \(s("to"))"
        case "createList": return "added list \(s("name")) to this board"
        case "renameList": return "renamed list to \(s("name"))"
        case "archiveList": return "archived list \(s("name"))"
        case "restoreList": return "sent list \(s("name")) to the board"
        case "moveList": return "moved list \(s("name"))"
        case "createCard": return "added \(card) to this board"
        case "renameCard": return "renamed \(card)"
        case "updateDescription": return "updated the description of \(card)"
        case "archiveCard": return "archived \(card)"
        case "restoreCard": return "sent \(card) to the board"
        case "deleteCard": return "deleted card \(s("title"))"
        case "moveCard": return "moved \(card) from \(s("from")) to \(s("to"))"
        case "copyCard": return "copied \(card) from \(s("from"))"
        case "changeDue":
            if let due = d["due"], !due.isNull {
                return "set \(card) to be due \(date("due", .dateTime.month(.abbreviated).day().hour().minute()))"
            }
            return "removed the due date from \(card)"
        case "recurCard": return "completed \(card); it repeats, next due \(date("due", .dateTime.month(.abbreviated).day()))"
        case "changeRecurrence":
            if let r = d["recurrence"], !r.isNull { return "set \(card) to repeat \(s("recurrence") == "weekdays" ? "every weekday" : s("recurrence"))" }
            return "stopped \(card) repeating"
        case "completeDue": return "marked the due date on \(card) complete"
        case "incompleteDue": return "marked the due date on \(card) incomplete"
        case "addMemberToCard": return "joined \(card)"
        case "removeMemberFromCard": return "left \(card)"
        case "addChecklist": return "added \(s("name")) to \(card)"
        case "removeChecklist": return "removed \(s("name")) from \(card)"
        case "completeCheckItem": return "completed \(s("name")) on \(card)"
        case "incompleteCheckItem": return "marked \(s("name")) incomplete on \(card)"
        case "addBlocker": return "marked \(card) as blocked by \(s("name"))"
        case "removeBlocker": return "marked \(card) as no longer blocked by \(s("name"))"
        case "addAttachment": return "attached \(s("name")) to \(card)"
        case "addMemberToBoard": return "added a member to this board"
        case "joinBoard": return "joined this board via invite link"
        case "archiveAllCards": return "archived all cards in a list"
        case "sortList": return "sorted a list"
        case "moveAllCards": return "moved \(s("count")) cards"
        case "moveListFromBoard": return "moved list \(s("name")) to another board"
        case "deleteList": return "deleted a list"
        case "updateBoard": return "updated this board"
        default: return a.type
        }
    }

    public static func notification(_ n: NotificationItem) -> String {
        let by = n.value("by") ?? "Someone"
        let title = n.value("title") ?? "a card"
        switch n.type {
        case "addedToCard": return "\(by) added you to \(title)"
        case "commentCard": return "\(by) commented on \(title): \(n.value("text") ?? "")"
        default: return "\(by): \(title)"
        }
    }
}
