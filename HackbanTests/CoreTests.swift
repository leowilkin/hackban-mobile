import XCTest
@testable import Hackban

final class SuperJSONTests: XCTestCase {
    func testSerializesDatesWithMeta() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let data = SuperJSON.serialize(["id": "c1", "due": .date(due), "start": .null])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let json = try XCTUnwrap(obj["json"] as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "c1")
        XCTAssertEqual(json["due"] as? String, "2027-01-15T08:00:00.000Z")
        XCTAssertTrue(json["start"] is NSNull)
        let meta = try XCTUnwrap(obj["meta"] as? [String: Any])
        let values = try XCTUnwrap(meta["values"] as? [String: Any])
        XCTAssertEqual(values["due"] as? [String], ["Date"])
        XCTAssertNil(values["start"])
    }

    func testNoMetaWithoutDates() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: SuperJSON.serialize(["q": "x"])) as? [String: Any])
        XCTAssertNil(obj["meta"])
    }

    func testNilInputIsUndefined() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: SuperJSON.serialize(nil)) as? [String: Any])
        XCTAssertEqual((obj["meta"] as? [String: Any])?["values"] as? [String], ["undefined"])
    }

    func testDecodesTRPCResult() throws {
        let body = """
        {"result":{"data":{"json":{"id":"n1","type":"addedToCard","data":{"by":"Sam","title":"Ship"},"read":false,"createdAt":"2026-11-01T10:00:00.000Z"},"meta":{"values":{"createdAt":["Date"]}}}}}
        """
        let n = try HackbanAPI.decodeResult(NotificationItem.self, from: Data(body.utf8))
        XCTAssertEqual(n.value("by"), "Sam")
        XCTAssertEqual(n.createdAt, ISO8601.date("2026-11-01T10:00:00.000Z"))
        XCTAssertEqual(ActivityText.notification(n), "Sam added you to Ship")
    }

    func testDecodesVoidMutation() throws {
        let body = #"{"result":{"data":{"json":null,"meta":{"values":["undefined"]}}}}"#
        XCTAssertNoThrow(try HackbanAPI.decodeResult(Ignored.self, from: Data(body.utf8)))
    }

    func testParsesErrors() {
        let body = #"{"error":{"json":{"message":"Only board admins can move a board.","code":-32003,"data":{"code":"FORBIDDEN","httpStatus":403}}}}"#
        let e = HackbanAPI.error(from: Data(body.utf8), status: 403)
        XCTAssertEqual(e, .server(code: "FORBIDDEN", message: "Only board admins can move a board.", status: 403))
        let zod = #"{"error":{"json":{"message":"[{\"code\":\"too_small\",\"message\":\"String must contain at least 1 character(s)\"}]","data":{"code":"BAD_REQUEST"}}}}"#
        XCTAssertEqual(HackbanAPI.error(from: Data(zod.utf8), status: 400).errorDescription, "String must contain at least 1 character(s)")
        XCTAssertEqual(HackbanAPI.error(from: Data(), status: 401), .unauthorized)
    }

    func testParsesSSEEvents() {
        XCTAssertEqual(HackbanAPI.parseEvent(#"{"json":{"boardId":"b","cardId":"c","origin":"x","kind":"card"}}"#)?.cardId, "c")
        XCTAssertEqual(HackbanAPI.parseEvent(#"{"boardId":"b","kind":"board"}"#)?.kind, "board")
        XCTAssertNil(HackbanAPI.parseEvent("not json"))
    }

    func testQueryEscapeEncodesReservedCharacters() {
        let s = HackbanAPI.queryEscape(#"{"json":{"q":"a&b=c+d"}}"#)
        XCTAssertFalse(s.contains("&"))
        XCTAssertFalse(s.contains("+"))
        XCTAssertFalse(s.contains("="))
        XCTAssertEqual(s.removingPercentEncoding, #"{"json":{"q":"a&b=c+d"}}"#)
    }
}

final class QuickAddParserTests: XCTestCase {
    func testTokens() {
        let p = QuickAddParser.parse("Order stickers #Events/To_Do @me @sam !red ^top *weekly")
        XCTAssertEqual(p.title, "Order stickers")
        XCTAssertEqual(p.board, "Events")
        XCTAssertEqual(p.list, "To Do")
        XCTAssertEqual(p.members, ["me", "sam"])
        XCTAssertEqual(p.labels, ["red"])
        XCTAssertEqual(p.top, true)
        XCTAssertEqual(p.recurrence, .weekly)
    }

    func testDatePhraseBecomesDue() throws {
        let p = QuickAddParser.parse("Call venue tomorrow at 5pm")
        let due = try XCTUnwrap(p.due)
        XCTAssertTrue(Calendar.current.isDateInTomorrow(due))
        XCTAssertEqual(Calendar.current.component(.hour, from: due), 17)
        XCTAssertEqual(p.title, "Call venue")
    }

    func testPlainTextIsUntouched() {
        let p = QuickAddParser.parse("Fix #  the thing")
        XCTAssertEqual(p.title, "Fix # the thing")
        XCTAssertNil(p.board)
        XCTAssertNil(p.due)
    }

    func testFuzzyMatch() {
        let names = ["Hack Club Events", "Events", "Personal"]
        XCTAssertEqual(QuickAddParser.best("events", in: names, name: { $0 }), "Events")
        XCTAssertEqual(QuickAddParser.best("hackclub", in: names, name: { $0 }), "Hack Club Events")
        XCTAssertEqual(QuickAddParser.best("pers", in: names, name: { $0 }), "Personal")
        XCTAssertNil(QuickAddParser.best("zzz", in: names, name: { $0 }))
    }
}

final class BoardLogicTests: XCTestCase {
    private func card(_ id: String, title: String, due: Date? = nil, complete: Bool = false, members: [String] = [], labels: [String] = [], created: Date = .now) -> BoardCard {
        BoardCard(id: id, listId: "l", title: title, description: nil, pos: nil, start: nil, due: due, dueComplete: complete, recurrence: nil,
                  coverColor: nil, coverAttachmentId: nil, coverSize: nil, closed: false, shortId: nil, createdAt: created, updatedAt: nil,
                  labels: labels.map { CardLabelLink(labelId: $0, label: BoardLabel(id: $0, name: $0, color: "green")) },
                  members: members.map { CardMemberLink(userId: $0, user: UserRef(id: $0)) },
                  _count: nil, blockedBy: nil, blocking: nil, watching: nil, checkTotal: nil, checkDone: nil, coverUrl: nil)
    }

    func testFilters() {
        let now = Date()
        let cards = [
            card("a", title: "Alpha", due: now.addingTimeInterval(-3600), members: ["u1"], labels: ["L1"]),
            card("b", title: "Beta", due: now.addingTimeInterval(3600)),
            card("c", title: "Gamma", due: now.addingTimeInterval(3 * 86_400), complete: true, members: ["u2"]),
            card("d", title: "Delta"),
        ]
        var f = CardFilters()
        f.due = [.overdue]
        XCTAssertEqual(cards.filter { f.matches($0, now: now) }.map(\.id), ["a"])
        f.due = [.day]
        XCTAssertEqual(cards.filter { f.matches($0, now: now) }.map(\.id), ["b"])
        f.due = [.none, .complete]
        XCTAssertEqual(cards.filter { f.matches($0, now: now) }.map(\.id), ["c", "d"])
        f = CardFilters()
        f.members = ["none"]
        XCTAssertEqual(cards.filter { f.matches($0) }.map(\.id), ["b", "d"])
        f = CardFilters()
        f.labels = ["L1"]
        f.q = "alp"
        XCTAssertEqual(cards.filter { f.matches($0) }.map(\.id), ["a"])
        XCTAssertEqual(f.count, 2)
    }

    func testSortsAndGroups() {
        let now = Date()
        let cards = [
            card("1", title: "item 10", due: now.addingTimeInterval(500), members: ["x"]),
            card("2", title: "Item 2", members: ["y"]),
            card("3", title: "item 1", due: now.addingTimeInterval(100), members: ["x"]),
        ]
        XCTAssertEqual(CardSort.nameAZ.sorted(cards).map(\.id), ["3", "2", "1"])
        XCTAssertEqual(CardSort.due.sorted(cards).map(\.id), ["3", "1", "2"])
        let grouped = CardSort.groupByAssignee([cards[0], cards[1], cards[2]])
        XCTAssertEqual(grouped.map(\.id), ["1", "3", "2"])
    }

    func testScopedID() {
        let id = ScopedID(account: UUID(), id: "card|weird")
        XCTAssertEqual(ScopedID(id.description), id)
        XCTAssertNil(ScopedID("nope"))
    }

    func testDueState() {
        let now = Date()
        XCTAssertEqual(DueState.of(due: now.addingTimeInterval(-1), complete: false, now: now), .overdue)
        XCTAssertEqual(DueState.of(due: now.addingTimeInterval(3600), complete: false, now: now), .soon)
        XCTAssertEqual(DueState.of(due: now.addingTimeInterval(3 * 86_400), complete: false, now: now), .later)
        XCTAssertEqual(DueState.of(due: now.addingTimeInterval(-1), complete: true, now: now), .complete)
    }
}
