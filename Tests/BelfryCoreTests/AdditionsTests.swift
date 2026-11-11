import Foundation
import XCTest
@testable import BelfryCore

// SPEC 19 (additions since milestone 1): channel references (vectors/channel-refs.json), edits,
// pins, to-dos, guest labels, Belfry events (rule B), the channel line, invite links, API pieces.

private let A = String(repeating: "a", count: 64)
private let B = String(repeating: "b", count: 64)
private let C = String(repeating: "c", count: 64)
private let RELAY = String(repeating: "d", count: 64)
private var counter = 0

private func ev(_ pubkey: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "", id: String? = nil) -> NostrEvent {
    counter += 1
    let i = id ?? String(format: "%064x", counter)
    return NostrEvent(id: i, pubkey: pubkey, createdAt: at, kind: kind, tags: tags, content: content)
}

final class ChannelRefsTests: XCTestCase {
    func testVectors() throws {
        let v = try vector("channel-refs")
        for c in v.list("encode") {
            let a = Nip19.Addr(kind: c.int("kind")!, pubkey: c.str("pubkey")!, identifier: c.str("identifier")!, relays: c.strs("relays"))
            XCTAssertEqual(Nip19.naddr(a), c.str("naddr"), c.str("identifier")!)
            let back = Nip19.decodeNaddr(c.str("naddr")!)
            XCTAssertEqual(back?.identifier, c.str("identifier"))
            XCTAssertEqual(back?.pubkey, c.str("pubkey"))
            XCTAssertEqual(back?.relays, c.strs("relays"))
        }
        for c in v.list("decode") {
            XCTAssertEqual(ChannelRefs.groupOf(c.str("naddr")!), c.str("group"), c.str("naddr")!)
        }
        let names = v.dict("groups")
        for c in v.list("plain") {
            XCTAssertEqual(ChannelRefs.plain(c.str("text")!) { names[$0] as? String }, c.str("plain"), c.str("text")!)
        }
    }

    func testRefFromMetadataAndPicker() {
        let evs = [ev(RELAY, 39000, 100, [["d", "general"], ["name", "General"]]), ev(RELAY, 39000, 100, [["d", "garden-1"], ["name", "Garden club"]])]
        let d = Derive(events: evs, context: WorldContext(me: A, groupsRelay: "wss://groups-relay.example.org"))
        let ref = d.channelRef("general")!
        XCTAssertTrue(ref.hasPrefix("nostr:naddr1"))
        XCTAssertEqual(ChannelRefs.groupOf(String(ref.dropFirst(6))), "general")
        XCTAssertNil(d.channelRef("nope"))
        XCTAssertEqual(d.channelCandidates("clu").map(\.group.id), ["garden-1"])
        XCTAssertEqual(ChannelRefs.query(beforeCaret: "see #gar"), "gar")
        XCTAssertNil(ChannelRefs.query(beforeCaret: "a&#gar"))
        let sent = ChannelRefs.substitute("in #Garden club now", picked: [("#Garden club", d.channelRef("garden-1")!)])
        XCTAssertEqual(d.plainRefs(sent), "in #Garden club now")
        XCTAssertTrue(Topics.hashtags(sent).isEmpty)
        let back = d.unsubstituteChannels(sent)
        XCTAssertEqual(back.text, "in #Garden club now")
        XCTAssertEqual(back.picked.count, 1)
    }
}

final class EditsPinsTodosTests: XCTestCase {
    func testOnlyTheAuthorsLatestEditCounts() {
        let m = ev(A, 9, 100, [["h", "g"], ["t", "garden"]], "Hello wrld", id: String(repeating: "1", count: 64))
        let e1 = ev(A, 1010, 200, [["h", "g"], ["e", m.id], ["k", "9"]], "Hello world")
        let foreign = ev(B, 1010, 300, [["h", "g"], ["e", m.id], ["k", "9"]], "Hijacked")
        var d = Derive(events: [m, e1, foreign], me: A)
        XCTAssertEqual(d.messages("g").first?.text, "Hello world")
        XCTAssertEqual(d.messages("g").first?.edited, 200)
        XCTAssertEqual(d.messages("g").first?.id, m.id)
        // deleting the edit shows the original again
        let del = ev(A, 5, 400, [["h", "g"], ["e", e1.id]])
        d = Derive(events: [m, e1, foreign, del], me: A)
        XCTAssertEqual(d.messages("g").first?.text, "Hello wrld")
        XCTAssertNil(d.messages("g").first?.edited)
    }

    func testEditKeepsTopicAndPhotos() {
        let m = ev(A, 9, 100, [["h", "g"], ["t", "garden"], ["imeta", "url https://x.example/p.jpg", "m image/jpeg"]], "Look #seeds\nhttps://x.example/p.jpg")
        let msg = Derive(events: [m], me: A).messages("g")[0]
        let d = Actions.editMessage("g", msg, text: "Look at #tomatoes")
        XCTAssertEqual(d.kind, 1010)
        XCTAssertEqual(d.content, "Look at #tomatoes\nhttps://x.example/p.jpg")
        XCTAssertEqual(d.tags.filter { $0[0] == "t" }.map { $0[1] }, ["garden", "tomatoes"])
        XCTAssertTrue(d.tags.contains { $0[0] == "imeta" })
        XCTAssertEqual(Array(d.tags.prefix(3)), [["h", "g"], ["e", m.id], ["k", "9"]])
    }

    func testCanEditAndDeletePreview() {
        let mine = ev(A, 9, 100, [["h", "g"]], "Mine nostr:\(Bech32.npub(B)!) ok")
        let theirs = ev(B, 9, 101, [["h", "g"]], "Theirs")
        let card = ev(A, 9, 102, [["h", "g"], ["pod", "pod-x-1"]], "⬡ New pod: X")
        let d = Derive(events: [mine, theirs, card], context: WorldContext(me: A, pending: []))
        let ms = d.messages("g")
        XCTAssertTrue(d.canEdit(ms[0]))
        XCTAssertFalse(d.canEdit(ms[1]))
        XCTAssertFalse(d.canEdit(ms[2]))
        XCTAssertEqual(d.deletePreview(ms[0]), "Mine @… ok")
        let queued = Derive(events: [mine], context: WorldContext(me: A, pending: [mine.id]))
        XCTAssertFalse(queued.canEdit(queued.messages("g")[0]))
        XCTAssertFalse(queued.canDelete(queued.messages("g")[0]))
    }

    func testPinsCountOnlyFromAdmins() {
        let meta = ev(RELAY, 39001, 50, [["d", "g"], ["p", A, "admin"]])
        let m1 = ev(B, 9, 100, [["h", "g"]], "First")
        let m2 = ev(B, 9, 110, [["h", "g"]], "**Second** line\nmore")
        let p1 = ev(A, 1985, 200, Actions.pinMessage("g", messageId: m1.id, pin: true).tags)
        let p2 = ev(A, 1985, 210, Actions.pinMessage("g", messageId: m2.id, pin: true).tags)
        let byNonAdmin = ev(C, 1985, 220, Actions.pinMessage("g", messageId: m1.id, pin: false).tags)
        var d = Derive(events: [meta, m1, m2, p1, p2, byNonAdmin], me: A)
        XCTAssertEqual(d.pinned("g").map(\.id), [m2.id, m1.id])
        XCTAssertEqual(d.pinLine(d.pinned("g")[0]), "Second line")
        let unpin = ev(A, 1985, 230, Actions.pinMessage("g", messageId: m1.id, pin: false).tags)
        d = Derive(events: [meta, m1, m2, p1, p2, byNonAdmin, unpin], me: A)
        XCTAssertEqual(d.pinned("g").map(\.id), [m2.id])
        // a community admin may pin too
        let cp = ev(C, 1985, 240, Actions.pinMessage("g", messageId: m1.id, pin: true).tags)
        d = Derive(events: [meta, m1, m2, p1, p2, unpin, cp], me: A, communityAdmins: [C])
        XCTAssertEqual(d.pinned("g").map(\.id), [m1.id, m2.id])
    }

    func testTodoFromMessage() {
        let m = ev(B, 9, 100, [["h", "g"]], "Fix   the\ngate nostr:\(Bech32.npub(C)!)")
        var d = Derive(events: [m], me: A)
        let msg = d.messages("g")[0]
        XCTAssertEqual(d.todoTitle(msg), "Fix the gate")
        XCTAssertTrue(d.canMakeTodo("g", msg))
        let t = ev(A, 2100, 200, Actions.addTask("g", title: d.todoTitle(msg), from: m.id).tags, "Fix the gate")
        d = Derive(events: [m, t], me: A)
        XCTAssertFalse(d.canMakeTodo("g", msg))
        XCTAssertEqual(d.todoChip(d.todosBySource("g")[m.id]!), "To do")
        let claim = ev(B, 2101, 210, Actions.taskAction("g", taskId: t.id, action: "claim").tags)
        let done = ev(A, 2101, 220, Actions.taskAction("g", taskId: t.id, action: "done").tags)
        d = Derive(events: [m, t, claim, done], me: A)
        let task = d.tasks("g")[0]
        XCTAssertTrue(task.done)
        XCTAssertEqual(task.assignee, B)
        XCTAssertEqual(task.source, m.id)
        XCTAssertEqual(d.todoChip(task), "Done")
    }
}

final class GuestsTests: XCTestCase {
    func testLabelsAgentsAndCleanedUpJoins() {
        let gk = String(repeating: "9", count: 64)
        let j1 = ev(gk, 9000, 100, [["h", "g"], ["p", B, "member"], ["invited-by", A], ["unsaved", "1"], ["name", "Bea"]])
        let j2 = ev(gk, 9000, 110, [["h", "g"], ["p", C, "member"], ["invited-by", A], ["agent", "1"]])
        let ghost = String(repeating: "e", count: 64)
        let j3 = ev(gk, 9000, 120, [["h", "g"], ["p", ghost, "member"], ["invited-by", A]])
        let out = ev(gk, 9001, 130, [["h", "g"], ["p", ghost]])
        var d = Derive(events: [j1, j2, j3, out], context: WorldContext(me: A, groupsKey: gk))
        XCTAssertEqual(d.guestJoins("g").map(\.pubkey), [B, C])
        XCTAssertEqual(d.guestJoins("g")[0].chip, "guest · not saved")
        XCTAssertEqual(d.guestJoins("g")[1].chip, "agent")
        XCTAssertTrue(d.isGuest(B))
        XCTAssertTrue(d.isAgent(C))
        XCTAssertEqual(d.kindLabel(C), "Agent, a guest")
        XCTAssertEqual(d.noAdminReason(B), "This guest has no e-mail yet. Once they save their account, you can make them an admin.")
        XCTAssertEqual(d.noAdminReason(C), "An agent cannot be an admin.")
        XCTAssertEqual(d.profiles()[B]?.name, "Bea")
        // saved, then made a member
        let saved = ev(gk, 1985, 140, [["h", "g"], ["L", "belfry/guest"], ["l", "saved", "belfry/guest"], ["p", B]])
        d = Derive(events: [j1, j2, saved], context: WorldContext(me: A, groupsKey: gk))
        XCTAssertEqual(d.guestJoins("g")[0].chip, "guest")
        XCTAssertNil(d.noAdminReason(B))
        let member = ev(gk, 1985, 150, [["h", "g"], ["L", "belfry/guest"], ["l", "member", "belfry/guest"], ["p", B]])
        d = Derive(events: [j1, j2, saved, member], context: WorldContext(me: A, groupsKey: gk))
        XCTAssertNil(d.guestJoins("g")[0].chip)
        XCTAssertFalse(d.isGuest(B))
        // the register overrules the labels
        d = Derive(events: [j1, j2, saved, member], context: WorldContext(me: A, groupsKey: gk, kinds: [B: "guest"]))
        XCTAssertTrue(d.isGuest(B))
        // a member's own agent
        d = Derive(events: [j1, j2], context: WorldContext(me: A, groupsKey: gk, agents: [C: A]))
        XCTAssertEqual(d.agentOwner(C), A)
        XCTAssertFalse(d.isGuest(C))
        XCTAssertEqual(d.kindLabel(C), "Your agent")
        XCTAssertEqual(Set(d.guestJoinKeys), [B, C])
    }

    func testInChannel() {
        let gk = String(repeating: "9", count: 64)
        let open = ev(RELAY, 39000, 10, [["d", "open"], ["name", "Open"], ["open"]])
        let closed = ev(RELAY, 39000, 10, [["d", "pod-x-1"], ["name", "X"], ["closed"]])
        let j = ev(gk, 9000, 100, [["h", "other"], ["p", B, "member"], ["invited-by", A]])
        let d = Derive(events: [open, closed, j], context: WorldContext(me: A, groupsKey: gk))
        XCTAssertTrue(d.inChannel(d.group("open"), C))
        XCTAssertFalse(d.inChannel(d.group("open"), B))
        XCTAssertFalse(d.inChannel(d.group("pod-x-1"), C))
        XCTAssertEqual(d.inviteState(d.group("open"), C), "Can already open it")
        XCTAssertTrue(d.inviteText("open", asked: false).hasSuffix("https://chat./#/c/open"))
    }
}

final class EventsTests: XCTestCase {
    let dd = "2026-ab12cd"

    func testRuleBAndPeople() {
        let g = "ev-" + dd
        let create = ev(A, 9007, 100, [["h", g]])
        let v1 = ev(A, 31923, 110, [["d", dd], ["title", "Picnic"], ["start", "2000000000"], ["h", g]])
        let notHost = ev(C, 31923, 120, [["d", dd], ["title", "Spam"], ["start", "2000000000"]])
        let cohost = ev(A, 9000, 130, [["h", g], ["p", B, "admin"]])
        let v2 = ev(B, 31923, 140, [["d", dd], ["title", "Picnic in the park"], ["start", "2000000000"], ["location", "Park"], ["slug", "picnic"]])
        let msg = ev(C, 9, 150, [["h", "general"]], "Come! https://demo.example/events/picnic")
        let d = Derive(events: [create, v1, notHost, cohost, v2, msg], context: WorldContext(me: C, domain: "demo.example"))
        XCTAssertEqual(d.calendar.count, 1)
        let e = d.calendar[0]
        XCTAssertEqual(e.title, "Picnic in the park")
        XCTAssertEqual(e.coord, "31923:\(A):\(dd)")
        XCTAssertEqual(e.hosts, [A, B])
        XCTAssertEqual(e.channels, ["general"])
        XCTAssertEqual(e.link, "picnic")
        XCTAssertEqual(d.messages("general")[0].eventRefs, [EventRef(link: "picnic")])
        XCTAssertEqual(d.eventTagsFor("see https://demo.example/events/picnic", mainRelay: "wss://r"), [["a", e.coord, "wss://r"]])
        XCTAssertEqual(d.myState(e), MyState.none)
        // an application, then a decision
        let app = ev(C, 9021, 200, [["h", g], ["ticket", dd + ":t1"]], "I bring bread")
        var d2 = Derive(events: [create, v1, cohost, v2, app], me: C)
        XCTAssertEqual(d2.myState(d2.calendar[0]), .applied)
        let yes = ev(B, 9000, 210, EventActions.decide(d2.calendar[0], pubkey: C, approve: true, ticketD: dd + ":t1").tags)
        d2 = Derive(events: [create, v1, cohost, v2, app, yes], me: C)
        XCTAssertEqual(d2.myState(d2.calendar[0]), .ticket)
        XCTAssertEqual(d2.calendar[0].goingKeys, [C])
    }

    func testIdsAndLinks() {
        XCTAssertTrue(EventLinks.isD(EventLinks.newD(now: 1_800_000_000)))
        XCTAssertEqual(EventLinks.slugOf("Café night: Jazz!"), "cafe-night-jazz")
        XCTAssertEqual(EventLinks.slugProblem("new"), "That word is kept")
        XCTAssertNil(EventLinks.slugProblem("summer-fair"))
        XCTAssertEqual(EventLinks.linksIn("a https://x.org/events/one and https://y.org/events/two https://x.org/events/one", domain: "x.org"), ["one"])
    }
}

final class LineAndLinksTests: XCTestCase {
    func testChannelLinePriority() {
        let now = 2_000_000_000
        let meta = ev(RELAY, 39001, 10, [["d", "g"], ["p", A, "admin"]])
        let seen = ev(B, 30078, now - 100, [["d", "seen:g"], ["h", "g"]])
        var d = Derive(events: [meta, seen], me: A)
        var line = d.channelLine("g", now: now)
        XCTAssertEqual(line.text, "1 person active this month")
        XCTAssertTrue(line.quiet)
        let m = ev(B, 9, now - 50, [["h", "g"]], "Read the rules")
        let pin = ev(A, 1985, now - 40, Actions.pinMessage("g", messageId: m.id, pin: true).tags)
        d = Derive(events: [meta, seen, m, pin], me: A)
        line = d.channelLine("g", now: now)
        XCTAssertEqual(line.icon, .pin)
        XCTAssertEqual(line.text, "Read the rules")
        XCTAssertEqual(d.channelLine("g", now: now, hiddenPins: [m.id]).icon, .people)
        XCTAssertEqual(d.channelLine("g", now: now, topic: "garden").text, "#garden only")
        let todo = ev(A, 2100, now - 30, Actions.addTask("g", title: "Water").tags, "Water")
        d = Derive(events: [meta, seen, m, pin, todo], me: A)
        XCTAssertEqual(d.channelLine("g", now: now).counts.map(\.kind), ["todos"])
    }

    func testPodShapes() {
        XCTAssertEqual(PodShapes.sides(1), 3)
        XCTAssertEqual(PodShapes.sides(5), 5)
        XCTAssertFalse(PodShapes.isCircle(12))
        XCTAssertTrue(PodShapes.isCircle(13))
    }

    func testInviteLinkParse() {
        let t = "abcdefghijklmnopqrstuvwx"
        XCTAssertEqual(InviteLink.parse(URL(string: "https://chat.belfry.sh/join/\(t)")!)?.token, t)
        XCTAssertEqual(InviteLink.parse(URL(string: "https://chat.belfry.sh/#/join/\(t)")!)?.domain, "belfry.sh")
        XCTAssertNil(InviteLink.parse(URL(string: "https://belfry.sh/join/\(t)")!))
        XCTAssertNil(InviteLink.parse(URL(string: "https://chat.belfry.sh/join/short")!))
        XCTAssertNil(InviteLink.parse(URL(string: "http://chat.belfry.sh/join/\(t)")!))
    }

    func testProfileExtras() {
        let content = People.extrasContent(tags: ["#Gardening", "bike repair", "gardening"], share: .city, place: People.demoPlaces[0])
        let x = People.parseExtras(content, at: 5)!
        XCTAssertEqual(x.tags, ["gardening", "bike-repair"])
        XCTAssertEqual(x.place?.name, "Brussels")
        let c2 = People.parseExtras(People.extrasContent(tags: [], share: .country, place: People.demoPlaces[0]), at: 5)!
        XCTAssertEqual(c2.place, Place(country: "BE"))
        XCTAssertNil(People.parseExtras("{\"share\":\"none\",\"place\":{\"country\":\"BE\"}}", at: 1)?.place)
    }

    func testRefusedUploadsArePermanent() {
        XCTAssertEqual(Outbox.classify("upload failed (413)"), .failed)
        XCTAssertEqual(Outbox.classify("upload failed (429)"), .retry)
        XCTAssertEqual(Outbox.classify("upload failed (503)"), .retry)
    }
}

final class EventsApiTests: XCTestCase {
    func testParseAnswer() throws {
        let json = """
        {"d":"2026-ab12cd","coord":"31923:\(String(repeating: "a", count: 64)):2026-ab12cd","kind":31923,"group":"ev-2026-ab12cd","link":"picnic",
         "url":"https://x.org/events/picnic","title":"Picnic","description":"Bring food","all_day":false,"start":"2026-12-01T18:00:00+01:00",
         "end":"2026-12-01T21:00:00+01:00","tz":"Europe/Brussels","location":"Park","online":true,"links":["https://meet.jit.si/x","javascript:alert(1)"],
         "cover":"https://x.org/events/picnic/cover","visibility":"link","status":"scheduled","status_reason":"","hosts":[{"pubkey":"\(String(repeating: "a", count: 64))","name":"Ana"}],
         "tickets":[{"d":"2026-ab12cd:t1","id":"t1","title":"Seat","quantity":10,"left":3,"closed":true,"prompt":"Why?","members":false,"position":1,"implicit":false}],
         "going":7,"community":"X","me":{"host":false,"ticket":null,"applied":true,"waitlist":false,"declined":false,"rsvp":null,"member":false}}
        """
        let o = try XCTUnwrap(JSON.parse(json) as? [String: Any])
        let a = try XCTUnwrap(BelfryAPI.parseEvent(o))
        XCTAssertEqual(a.links, ["https://meet.jit.si/x"])
        XCTAssertEqual(a.tickets.first?.ticket.apiLeft, 3)
        XCTAssertEqual(a.myState, .applied)
        let e = a.calEvent(timeZone: TimeZone(identifier: "UTC")!, me: B)
        XCTAssertEqual(e.start, 1_796_144_400)
        XCTAssertEqual(e.slug, "picnic")
        XCTAssertEqual(e.goingCount, 7)
        XCTAssertTrue(e.remote)
        XCTAssertEqual(e.visibility, .link)
        XCTAssertNil(BelfryAPI.parseEvent(["d": "x"]))
    }
}
