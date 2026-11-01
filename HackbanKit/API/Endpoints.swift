import Foundation

// Typed wrappers for the hackban tRPC procedures the app uses. Inputs mirror the zod schemas in
// src/server/api/routers/*. Optional fields are only sent when set; `.null` clears a field.

private func obj(_ pairs: [(String, JSONValue?)]) -> JSONValue {
    var out: [String: JSONValue] = [:]
    for (k, v) in pairs { if let v { out[k] = v } }
    return .object(out)
}

public extension HackbanAPI {
    // MARK: Me

    func profile() async throws -> Profile { try await query("me.profile") }

    func updateProfile(name: String? = nil, username: JSONValue? = nil) async throws {
        try await run("me.update", obj([("name", name.map(JSONValue.string)), ("username", username)]))
    }

    func myActivity(cursor: String?) async throws -> ActivityPage {
        try await query("me.activity", obj([("cursor", JSONValue.orNull(cursor))]))
    }

    func myCards() async throws -> [MyCard] { try await query("me.cards") }
    func connectedApps() async throws -> [ConnectedApp] { try await query("me.apps") }
    func revokeApp(_ id: String) async throws { try await run("me.revokeApp", ["id": .string(id)]) }

    func uploadAvatar(_ file: UploadFile) async throws { _ = try await upload("api/users/\(account.userId)/avatar", files: [file]) }
    func removeAvatar() async throws { try await delete("api/users/\(account.userId)/avatar") }

    // MARK: Workspaces

    func workspaces() async throws -> [Workspace] { try await query("workspace.list") }
    func workspace(_ id: String) async throws -> WorkspaceDetail { try await query("workspace.get", ["id": .string(id)]) }

    func createWorkspace(name: String) async throws -> Created {
        try await mutate("workspace.create", ["name": .string(name)])
    }

    func updateWorkspace(_ id: String, name: String? = nil, description: String? = nil) async throws {
        try await run("workspace.update", obj([("id", .string(id)), ("name", name.map(JSONValue.string)), ("description", description.map(JSONValue.string))]))
    }

    func addWorkspaceMember(_ id: String, userId: String? = nil, email: String? = nil, role: String = "normal") async throws {
        try await run("workspace.addMember", obj([("id", .string(id)), ("userId", userId.map(JSONValue.string)), ("email", email.map(JSONValue.string)), ("role", .string(role))]))
    }

    func removeWorkspaceMember(_ id: String, userId: String) async throws {
        try await run("workspace.removeMember", ["id": .string(id), "userId": .string(userId)])
    }

    func deleteWorkspace(_ id: String, confirmName: String) async throws {
        try await run("workspace.delete", ["id": .string(id), "confirmName": .string(confirmName)])
    }

    func autoJoins(_ id: String) async throws -> [AutoJoinRule] { try await query("workspace.autoJoins", ["id": .string(id)]) }

    func addAutoJoin(_ id: String, domain: String) async throws {
        try await run("workspace.addAutoJoin", ["id": .string(id), "domain": .string(domain), "role": "normal"])
    }

    func removeAutoJoin(_ id: String, ruleId: String) async throws {
        try await run("workspace.removeAutoJoin", ["id": .string(id), "ruleId": .string(ruleId)])
    }

    func uploadLogo(_ workspaceId: String, _ file: UploadFile) async throws { _ = try await upload("api/workspaces/\(workspaceId)/logo", files: [file]) }
    func removeLogo(_ workspaceId: String) async throws { try await delete("api/workspaces/\(workspaceId)/logo") }

    // MARK: Boards

    func board(_ id: String) async throws -> Board { try await query("board.get", ["id": .string(id)]) }
    func recentBoards() async throws -> [BoardSummary] { try await query("board.recent") }
    func guestBoards() async throws -> [BoardSummary] { try await query("board.guestBoards") }
    func closedBoards() async throws -> [BoardSummary] { try await query("board.closed") }

    func createBoard(name: String, workspaceId: String, background: String, visibility: String, template: String) async throws -> Created {
        try await mutate("board.create", [
            "name": .string(name), "workspaceId": .string(workspaceId), "background": .string(background),
            "visibility": .string(visibility), "template": .string(template),
        ])
    }

    func updateBoard(_ id: String, name: String? = nil, description: String? = nil, background: String? = nil,
                     bgImage: JSONValue? = nil, visibility: String? = nil, closed: Bool? = nil) async throws {
        try await run("board.update", obj([
            ("id", .string(id)), ("name", name.map(JSONValue.string)), ("description", description.map(JSONValue.string)),
            ("background", background.map(JSONValue.string)), ("bgImage", bgImage), ("visibility", visibility.map(JSONValue.string)),
            ("closed", closed.map(JSONValue.bool)),
        ]))
    }

    func moveBoard(_ id: String, workspaceId: String) async throws {
        try await run("board.move", ["id": .string(id), "workspaceId": .string(workspaceId)])
    }

    func copyBoard(_ id: String, name: String, workspaceId: String, keepCards: Bool) async throws -> Created {
        try await mutate("board.copy", ["id": .string(id), "name": .string(name), "workspaceId": .string(workspaceId), "keepCards": .bool(keepCards)])
    }

    func deleteBoard(_ id: String) async throws { try await run("board.delete", ["id": .string(id)]) }

    func starBoard(_ id: String, _ starred: Bool) async throws {
        try await run("board.star", ["id": .string(id), "starred": .bool(starred)])
    }

    func searchUsers(_ q: String) async throws -> [UserRef] { try await query("board.searchUsers", ["q": .string(q)]) }

    func addBoardMember(_ id: String, userId: String? = nil, email: String? = nil, role: String = "normal") async throws {
        try await run("board.addMember", obj([("id", .string(id)), ("userId", userId.map(JSONValue.string)), ("email", email.map(JSONValue.string)), ("role", .string(role))]))
    }

    func removeBoardMember(_ id: String, userId: String) async throws {
        try await run("board.removeMember", ["id": .string(id), "userId": .string(userId)])
    }

    func setInviteLink(_ id: String, enabled: Bool, role: String? = nil, reset: Bool = false) async throws -> InviteLink {
        try await mutate("board.setInviteLink", obj([("id", .string(id)), ("enabled", .bool(enabled)), ("role", role.map(JSONValue.string)), ("reset", reset ? .bool(true) : nil)]))
    }

    func invitePreview(_ token: String) async throws -> InvitePreview { try await query("board.invitePreview", ["token": .string(token)]) }
    func joinByInvite(_ token: String) async throws -> JoinResult { try await mutate("board.joinByInvite", ["token": .string(token)]) }

    func boardActivity(_ id: String, cursor: String?) async throws -> ActivityPage {
        try await query("board.activity", obj([("id", .string(id)), ("cursor", JSONValue.orNull(cursor))]))
    }

    func archived(_ boardId: String) async throws -> ArchivedItems { try await query("board.archived", ["id": .string(boardId)]) }

    func exportBoard(_ id: String) async throws -> Data { try await data("/api/boards/\(id)/export") }

    // MARK: Lists

    func createList(boardId: String, name: String) async throws -> Created {
        try await mutate("list.create", ["boardId": .string(boardId), "name": .string(name)])
    }

    func updateList(_ id: String, name: String? = nil, color: JSONValue? = nil, closed: Bool? = nil) async throws {
        try await run("list.update", obj([("id", .string(id)), ("name", name.map(JSONValue.string)), ("color", color), ("closed", closed.map(JSONValue.bool))]))
    }

    func moveList(_ id: String, boardId: String? = nil, afterId: String?) async throws {
        try await run("list.move", obj([("id", .string(id)), ("boardId", boardId.map(JSONValue.string)), ("afterId", JSONValue.orNull(afterId))]))
    }

    func copyList(_ id: String, name: String) async throws { try await run("list.copy", ["id": .string(id), "name": .string(name)]) }

    func moveAllCards(_ id: String, toListId: String) async throws {
        try await run("list.moveAllCards", ["id": .string(id), "toListId": .string(toListId)])
    }

    func sortCards(_ listId: String, ids: [String]) async throws {
        try await run("list.sortCards", ["id": .string(listId), "ids": .array(ids.map(JSONValue.string))])
    }

    func archiveAllCards(_ listId: String) async throws { try await run("list.archiveAllCards", ["id": .string(listId)]) }
    func deleteList(_ id: String) async throws { try await run("list.delete", ["id": .string(id)]) }

    // MARK: Cards

    func card(_ id: String) async throws -> CardDetail { try await query("card.get", ["id": .string(id)]) }

    /// `top` puts the card first; otherwise it goes to the bottom.
    func createCard(listId: String, title: String, top: Bool = false) async throws -> Created {
        try await mutate("card.create", obj([("listId", .string(listId)), ("title", .string(title)), ("afterId", top ? .null : nil)]))
    }

    /// Fields set here are sent; pass `.null` to clear.
    func updateCard(_ id: String, _ fields: [String: JSONValue]) async throws {
        var input = fields
        input["id"] = .string(id)
        try await run("card.update", .object(input))
    }

    func moveCard(_ id: String, listId: String, afterId: String?) async throws {
        try await run("card.move", ["id": .string(id), "listId": .string(listId), "afterId": JSONValue.orNull(afterId)])
    }

    func copyCard(_ id: String, title: String, listId: String, keepChecklists: Bool, keepLabels: Bool, keepMembers: Bool, keepAttachments: Bool) async throws -> Created {
        try await mutate("card.copy", [
            "id": .string(id), "title": .string(title), "listId": .string(listId),
            "keep": ["checklists": .bool(keepChecklists), "labels": .bool(keepLabels), "members": .bool(keepMembers), "attachments": .bool(keepAttachments)],
        ])
    }

    func deleteCard(_ id: String) async throws { try await run("card.delete", ["id": .string(id)]) }

    func toggleLabel(card: String, label: String, on: Bool) async throws {
        try await run("card.toggleLabel", ["id": .string(card), "labelId": .string(label), "on": .bool(on)])
    }

    func toggleMember(card: String, user: String, on: Bool) async throws {
        try await run("card.toggleMember", ["id": .string(card), "userId": .string(user), "on": .bool(on)])
    }

    func watchCard(_ id: String, _ on: Bool) async throws { try await run("card.watch", ["id": .string(id), "on": .bool(on)]) }

    func setBlocker(card: String, blocker: String, on: Bool) async throws {
        try await run("card.setBlocker", ["id": .string(card), "blockerId": .string(blocker), "on": .bool(on)])
    }

    // Labels

    func createLabel(boardId: String, name: String, color: String?) async throws -> Created {
        try await mutate("card.createLabel", ["boardId": .string(boardId), "name": .string(name), "color": JSONValue.orNull(color)])
    }

    func updateLabel(_ id: String, name: String, color: String?) async throws {
        try await run("card.updateLabel", ["id": .string(id), "name": .string(name), "color": JSONValue.orNull(color)])
    }

    func deleteLabel(_ id: String) async throws { try await run("card.deleteLabel", ["id": .string(id)]) }

    // Checklists

    func addChecklist(card: String, name: String, copyFrom: String? = nil) async throws {
        try await run("card.addChecklist", obj([("id", .string(card)), ("name", .string(name)), ("copyFrom", copyFrom.map(JSONValue.string))]))
    }

    func renameChecklist(_ id: String, name: String) async throws {
        try await run("card.updateChecklist", ["checklistId": .string(id), "name": .string(name)])
    }

    func deleteChecklist(_ id: String) async throws { try await run("card.deleteChecklist", ["checklistId": .string(id)]) }

    func addCheckItem(checklist: String, name: String) async throws {
        try await run("card.addCheckItem", ["checklistId": .string(checklist), "name": .string(name)])
    }

    func updateCheckItem(_ id: String, _ fields: [String: JSONValue]) async throws {
        var input = fields
        input["itemId"] = .string(id)
        try await run("card.updateCheckItem", .object(input))
    }

    func moveCheckItem(_ id: String, checklist: String, afterId: String?) async throws {
        try await run("card.moveCheckItem", ["itemId": .string(id), "checklistId": .string(checklist), "afterId": JSONValue.orNull(afterId)])
    }

    func deleteCheckItem(_ id: String) async throws { try await run("card.deleteCheckItem", ["itemId": .string(id)]) }

    // Comments

    func addComment(card: String, text: String) async throws { try await run("card.addComment", ["id": .string(card), "text": .string(text)]) }
    func editComment(_ id: String, text: String) async throws { try await run("card.editComment", ["commentId": .string(id), "text": .string(text)]) }
    func deleteComment(_ id: String) async throws { try await run("card.deleteComment", ["commentId": .string(id)]) }

    // Attachments

    func addLink(card: String, url: String, name: String?) async throws {
        try await run("card.addLink", obj([("id", .string(card)), ("url", .string(url)), ("name", name.flatMap { $0.isEmpty ? nil : JSONValue.string($0) })]))
    }

    func renameAttachment(_ id: String, name: String) async throws {
        try await run("card.updateAttachment", ["attachmentId": .string(id), "name": .string(name)])
    }

    func deleteAttachment(_ id: String) async throws { try await run("card.deleteAttachment", ["attachmentId": .string(id)]) }

    func uploadAttachments(card: String, files: [UploadFile]) async throws {
        _ = try await upload("api/cards/\(card)/attachments", files: files)
    }

    // MARK: Notifications & search

    func notifications() async throws -> [NotificationItem] { try await query("notification.list") }
    func markAllNotificationsRead() async throws { try await run("notification.markAllRead") }
    func markNotificationRead(_ id: String) async throws { try await run("notification.markRead", ["id": .string(id)]) }

    func search(_ q: String) async throws -> SearchResults { try await query("search.query", ["q": .string(q)]) }
}
