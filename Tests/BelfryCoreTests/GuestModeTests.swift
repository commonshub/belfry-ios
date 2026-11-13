import Foundation
import XCTest
@testable import BelfryCore

private let ME = String(repeating: "a", count: 64)
private let ANA = String(repeating: "b", count: 64)
private let READER = String(repeating: "c", count: 64)
private let HELD = String(repeating: "e", count: 64)
private let GK = String(repeating: "9", count: 64)
private let RELAY = String(repeating: "d", count: 64)
private var n = 0

private func ev(_ pubkey: String, _ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
    n += 1
    return NostrEvent(id: String(format: "%064x", n), pubkey: pubkey, createdAt: at, kind: kind, tags: tags, content: content)
}

/// Guest mode (SPEC 19.26): reading guests, the write gate, the join calls.
final class GuestModeTests: XCTestCase {
    let now = 1_800_000_000

    func base() -> [NostrEvent] {
        [
            ev(RELAY, 39000, now - 1000, [["d", "g"], ["name", "Garden"]]),
            ev(RELAY, 39002, now - 1000, [["d", "g"], ["p", ME], ["p", ANA]]),
            ev(ANA, 0, now - 1000, [], #"{"name":"Ana"}"#),
            ev(ANA, 9, now - 500, [["h", "g"]], "hello"),
        ]
    }

    func reading(_ p: String, _ at: Int) -> NostrEvent {
        ev(GK, 9000, at, [["h", "g"], ["p", p, "member"], ["guest", "2026-12-12"], ["invited-by", ANA], ["unsaved", "1"], ["reading", "1"]])
    }

    func testReadingGuestIsHiddenEverywhere() {
        // the relay's member list has the key too, and the key left a seen mark
        let list = base() + [reading(READER, now - 400),
                             ev(RELAY, 39002, now - 390, [["d", "g"], ["p", ME], ["p", ANA], ["p", READER]]),
                             ev(READER, 30078, now - 300, [["d", "seen:g"], ["h", "g"]])]
        let d = Derive(events: list, context: WorldContext(me: ME, groupsKey: GK))
        let g = d.group("g")!
        XCTAssertEqual(g.reading, [READER])
        XCTAssertFalse(g.members.contains(READER))
        XCTAssertTrue(d.guestJoins("g").isEmpty, "no join line, no guest chip")
        XCTAssertFalse(d.feed("g").contains { if case .join = $0 { return true }; return false })
        XCTAssertFalse(d.memberRows("g").contains { $0.pubkey == READER })
        XCTAssertFalse(d.recentlyActive("g", now: now).contains { $0.pubkey == READER })
        XCTAssertEqual(d.readingCount("g"), 1)
        XCTAssertEqual(d.onlyReading, [READER])
        XCTAssertFalse(d.isGuest(READER))
    }

    func testJoiningEndsReading() {
        // the belfry's second 9000 with the name, then the label `saved`
        let joined = ev(GK, 9000, now - 200, [["h", "g"], ["p", READER, "member"], ["guest", "2026-12-12"], ["invited-by", ANA], ["name", "Lou"]])
        var d = Derive(events: base() + [reading(READER, now - 400), joined], context: WorldContext(me: ME, groupsKey: GK))
        XCTAssertTrue(d.group("g")!.reading.isEmpty)
        XCTAssertTrue(d.group("g")!.members.contains(READER))
        XCTAssertEqual(d.guestJoins("g").map(\.pubkey), [READER])
        XCTAssertEqual(d.guestJoins("g")[0].at, now - 200, "the join line is the 9000 without `reading`")
        XCTAssertEqual(d.guestJoins("g")[0].chip, "guest")
        XCTAssertEqual(d.readingCount("g"), 0)
        XCTAssertTrue(d.people.contains { $0.pubkey == READER && $0.name == "Lou" })
        // the label alone ends reading too
        let saved = ev(GK, 1985, now - 100, [["h", "g"], ["L", "belfry/guest"], ["l", "saved", "belfry/guest"], ["p", READER]])
        d = Derive(events: base() + [reading(READER, now - 400), saved], context: WorldContext(me: ME, groupsKey: GK))
        XCTAssertTrue(d.group("g")!.reading.isEmpty)
        // and a 9001
        let out = ev(GK, 9001, now - 100, [["h", "g"], ["p", READER]])
        d = Derive(events: base() + [reading(READER, now - 400), out], context: WorldContext(me: ME, groupsKey: GK))
        XCTAssertTrue(d.group("g")!.reading.isEmpty)
        XCTAssertFalse(d.group("g")!.members.contains(READER))
    }

    func testHeldMeetingGuestIsNotHidden() {
        // a name and `unsaved`, never `reading`
        let held = ev(GK, 9000, now - 300, [["h", "g"], ["p", HELD, "member"], ["invited-by", ANA], ["unsaved", "1"], ["name", "Mo"]])
        let d = Derive(events: base() + [held], context: WorldContext(me: ME, groupsKey: GK))
        XCTAssertTrue(d.group("g")!.members.contains(HELD))
        XCTAssertEqual(d.guestJoins("g").map(\.chip), ["guest · not saved"])
        XCTAssertEqual(d.readingCount("g"), 0)
    }

    func testIAmReading() {
        let d = Derive(events: base() + [reading(ME, now - 400)], context: WorldContext(me: ME, groupsKey: GK))
        XCTAssertTrue(d.amReading("g"))
        XCTAssertTrue(d.group("g")!.members.contains(ME), "my own key stays in")
        XCTAssertEqual(d.readingCount("g"), 0, "I am not counted among the readers")
        XCTAssertTrue(d.guestJoins("g").isEmpty)
    }

    // ---- the gate ---------------------------------------------------------------------------------

    func testAllowedWhileReading() {
        let api = "https://belfry.example.org/api/v1"
        XCTAssertTrue(GuestModeGate.allowsWhileReading(url: api + "/guest/save", method: "POST"))
        XCTAssertTrue(GuestModeGate.allowsWhileReading(url: api + "/guest/save/verify", method: "POST"))
        XCTAssertTrue(GuestModeGate.allowsWhileReading(url: api + "/me/sessions/revoke", method: "POST"))
        XCTAssertTrue(GuestModeGate.allowsWhileReading(url: api + "/channel-invites/abcdefghijklmnopqrstuv/join", method: "POST"))
        XCTAssertTrue(GuestModeGate.allowsWhileReading(url: api + "/whois", method: "POST"))
        XCTAssertTrue(GuestModeGate.allowsWhileReading(url: api + "/me/follows", method: "GET"))
        XCTAssertFalse(GuestModeGate.allowsWhileReading(url: api + "/me/follows", method: "POST"))
        XCTAssertFalse(GuestModeGate.allowsWhileReading(url: api + "/channel-invites", method: "POST"))
        XCTAssertFalse(GuestModeGate.allowsWhileReading(url: api + "/push/devices", method: "POST"))
        XCTAssertFalse(GuestModeGate.allowsWhileReading(url: api + "/guest/save/verify/x", method: "POST"))
    }

    func testEngineSendsNothingWhileReading() async throws {
        let db = try Database.memory()
        let me = try LocalSigner(secret: Keys.generateSecret())
        let e = SyncEngine(config: .defaults(domain: "example.org"), db: db, signer: me, localOnly: true,
                           attachmentsDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        var asked = 0
        e.guestMode.onRefused = { asked += 1 }
        e.guestMode.reading = true
        XCTAssertEqual(e.enqueue(Actions.postMessage("g", text: "hi")), "")
        XCTAssertEqual(e.enqueue(Actions.react("g", messageId: String(repeating: "1", count: 64), author: ANA, emoji: "👍")), "")
        XCTAssertEqual(e.enqueue(Actions.seen("g")), "")
        let signed = try me.signNow(EventTemplate(kind: 1059, content: "x", tags: [], createdAt: now))
        XCTAssertEqual(e.enqueueSigned(signed, target: .main, dm: nil), "")
        XCTAssertTrue(e.outboxItems().isEmpty)
        XCTAssertEqual(asked, 4, "each refusal asks to join")
        do { _ = try await e.signedRequest("https://belfry.example.org/api/v1/channel-invites", method: "POST", json: [:]); XCTFail() }
        catch { XCTAssertTrue(error is GuestModeRefused) }
        do { _ = try await e.upload(Data([1]), name: "a.jpg", mime: "image/jpeg", sha: "00"); XCTFail() }
        catch { XCTAssertTrue(error is GuestModeRefused) }
        let dms = DirectMessages(engine: e)
        do { try await dms.send("hi", in: MailThreads.nostrConv(author: ANA, pTags: [], me: me.pubkey)); XCTFail() }
        catch { XCTAssertTrue(error is GuestModeRefused) }
        XCTAssertTrue(e.outboxItems().isEmpty)
        // joined: writes go out again
        e.guestMode.reading = false
        XCTAssertNotEqual(e.enqueue(Actions.postMessage("g", text: "hi")), "")
        XCTAssertEqual(e.outboxItems().count, 1)
    }

    // ---- the calls --------------------------------------------------------------------------------

    func config() -> BelfryConfig { .defaults(domain: "example.org") }

    func testJoinWithoutName() async throws {
        StubBelfry.reset()
        let pk = String(repeating: "f", count: 64)
        StubBelfry.enqueue(200, #"{"channel":"garden-3f2a","new":true,"guest":true,"reading":true,"bunker_url":"bunker://\#(pk)?relay=wss%3A%2F%2Fbunker.example.org","pubkey":"\#(READER)"}"#)
        let api = BelfryAPI(config: config(), signer: nil, session: StubBelfry.session())
        let j = try await api.joinAsNew(token: "abcdefghijklmnopqrstuv", sessionSecretHex: Keys.generateSecret().hex)
        let asked = try XCTUnwrap(StubBelfry.take())
        XCTAssertEqual(asked.body, "{}")
        XCTAssertTrue(asked.url.hasSuffix("/channel-invites/abcdefghijklmnopqrstuv/join"))
        XCTAssertTrue(asked.authorization.hasPrefix("Nostr "))
        XCTAssertTrue(j.reading)
        XCTAssertEqual(j.channel, "garden-3f2a")
        XCTAssertEqual(j.pubkey, READER)
        // a name (older flow): not reading
        StubBelfry.enqueue(200, #"{"channel":"g","new":true,"guest":true,"reading":false,"bunker_url":"bunker://\#(pk)?relay=wss%3A%2F%2Fbunker.example.org"}"#)
        let k = try await api.joinAsNew(token: "abcdefghijklmnopqrstuv", name: " Lou ", sessionSecretHex: Keys.generateSecret().hex)
        XCTAssertFalse(k.reading)
        XCTAssertEqual(StubBelfry.take()?.body, #"{"name":"Lou"}"#)
        // an older belfry that wants a name: a fixed message, not "tell us your name"
        StubBelfry.enqueue(422, #"{"error":"name_needed","message":"server text"}"#)
        do { _ = try await api.joinAsNew(token: "abcdefghijklmnopqrstuv", sessionSecretHex: Keys.generateSecret().hex); XCTFail() }
        catch let e as ApiError { XCTAssertEqual(e.message, "This belfry is being updated. Try again in a few minutes.") }
    }

    func testSaveAndVerify() async throws {
        StubBelfry.reset()
        let signer = try LocalSigner(secret: Keys.generateSecret())
        let gate = GuestModeGate(reading: true)
        var asked = 0
        gate.onRefused = { asked += 1 }
        let api = BelfryAPI(config: config(), signer: signer, session: StubBelfry.session(), guestMode: gate)
        StubBelfry.enqueue(202, #"{"sent":true}"#)
        try await api.guestSave(email: " ana@example.org ", name: "  Ana   Silva ")
        let s = try XCTUnwrap(StubBelfry.take())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.body.utf8)) as? [String: String])
        XCTAssertEqual(body, ["email": "ana@example.org", "name": "Ana Silva"])
        XCTAssertEqual(asked, 0, "joining itself passes the gate")
        StubBelfry.enqueue(200, #"{"saved":true,"joined":true}"#)
        let joined = try await api.guestVerify(email: "ana@example.org", code: "123456", name: "Ana Silva")
        XCTAssertTrue(joined)
        // refusals by code, never the server's text
        for (status, json, want, moved) in [
            (422, #"{"error":"wrong_code","message":"x"}"#, GuestJoinError.wrongCode, false),
            (410, #"{"error":"expired"}"#, .expired, false),
            (422, #"{"error":"name_needed"}"#, .nameNeeded, false),
            (409, #"{"error":"not_guest"}"#, .notGuest, false),
            (409, #"{"error":"taken","message":"x","moved":true}"#, .taken, true),
            (409, #"{"error":"taken","moved":false}"#, .taken, false),
            (500, #"{"error":"boom"}"#, .failed, false),
        ] {
            StubBelfry.enqueue(status, json)
            do { try await api.guestVerify(email: "ana@example.org", code: "000000", name: "Ana"); XCTFail() }
            catch let f as GuestJoinFailure { XCTAssertEqual(f.error, want); XCTAssertEqual(f.moved, moved) }
        }
        XCTAssertEqual(GuestJoinError.taken.message, "This address already has an account here.")
        // collective-belfry d2b4c52: tries_left on a wrong code, the account's nip05 on taken
        StubBelfry.enqueue(422, #"{"error":"wrong_code","tries_left":2}"#)
        do { try await api.guestVerify(email: "ana@example.org", code: "000000"); XCTFail() }
        catch let f as GuestJoinFailure { XCTAssertEqual(f.triesLeft, 2); XCTAssertEqual(f.display, "That code is not right. 2 tries left.") }
        XCTAssertEqual(GuestJoinFailure(.wrongCode, triesLeft: 1).display, "That code is not right. 1 try left.")
        XCTAssertEqual(GuestJoinFailure(.wrongCode, triesLeft: 0).display, "That code is not right. Ask for a new one.")
        XCTAssertEqual(GuestJoinFailure(.wrongCode).display, GuestJoinError.wrongCode.message)
        StubBelfry.enqueue(409, #"{"error":"taken","moved":true,"nip05":"ana@example.org"}"#)
        do { try await api.guestVerify(email: "ana@mail.example", code: "000000"); XCTFail() }
        catch let f as GuestJoinFailure { XCTAssertEqual(f.error, .taken); XCTAssertTrue(f.moved); XCTAssertEqual(f.nip05, "ana@example.org") }
        // anything else that writes is refused on the device and asks to join
        do { _ = try await api.createGuestLink(channel: "g"); XCTFail() }
        catch let e as ApiError { XCTAssertEqual(e.code, "guest_mode") }
        XCTAssertEqual(asked, 1)
    }

    func testCodeStepAfterFailure() {
        // only a refused code clears the boxes; a lost connection keeps them (#issues 2026-11-13)
        XCTAssertTrue(GuestJoinError.wrongCode.clearsCode)
        XCTAssertTrue(GuestJoinError.expired.clearsCode)
        for e in [GuestJoinError.offline, .failed, .tooMany, .notGuest, .taken] { XCTAssertFalse(e.clearsCode, e.rawValue) }
        XCTAssertTrue(GuestJoinError.offline.mayHaveReached)
        XCTAssertTrue(GuestJoinError.failed.mayHaveReached)
        XCTAssertFalse(GuestJoinError.wrongCode.mayHaveReached)
        XCTAssertEqual(GuestJoinError.allCases.filter(\.mayMeanSavedAlready), [.wrongCode, .expired, .notGuest])

        let since = now - 5
        let label = ev(GK, 1985, now, [["h", "g"], ["L", "belfry/guest"], ["l", "saved", "belfry/guest"], ["p", ME]])
        let member = ev(GK, 1985, now, [["h", "g"], ["L", "belfry/guest"], ["l", "member", "belfry/guest"], ["p", ME]])
        let named = ev(GK, 9000, now, [["h", "g"], ["p", ME, "member"], ["guest", ""], ["name", "Lou"]])
        XCTAssertTrue(GuestJoinSaved.saved(in: [label], me: ME, channel: "g", since: since))
        XCTAssertTrue(GuestJoinSaved.saved(in: [member], me: ME, channel: "g", since: since))
        XCTAssertTrue(GuestJoinSaved.saved(in: [named], me: ME, channel: "g", since: since))
        // not: older than the attempt, another channel, someone else, the reading join, another label
        XCTAssertFalse(GuestJoinSaved.saved(in: [ev(GK, 1985, now - 60, label.tags)], me: ME, channel: "g", since: since))
        XCTAssertFalse(GuestJoinSaved.saved(in: [label, named], me: ME, channel: "h", since: since))
        XCTAssertTrue(GuestJoinSaved.saved(in: [label], me: ME, channel: nil, since: since)) // a guest saving from any channel
        XCTAssertFalse(GuestJoinSaved.saved(in: [label, named], me: ANA, channel: "g", since: since))
        XCTAssertFalse(GuestJoinSaved.saved(in: [ev(GK, 9000, now, [["h", "g"], ["p", ME, "member"], ["unsaved", "1"], ["reading", "1"]])], me: ME, channel: "g", since: since))
        XCTAssertFalse(GuestJoinSaved.saved(in: [ev(GK, 9000, now, [["h", "g"], ["p", ME, "member"], ["name", "Lou"], ["reading", "1"]])], me: ME, channel: "g", since: since))
        XCTAssertFalse(GuestJoinSaved.saved(in: [ev(GK, 1985, now, [["h", "g"], ["L", "belfry/guest"], ["l", "unsaved", "belfry/guest"], ["p", ME]])], me: ME, channel: "g", since: since))
        XCTAssertFalse(GuestJoinSaved.saved(in: [ev(GK, 1985, now, [["h", "g"], ["L", "belfry/pin"], ["l", "saved", "belfry/pin"], ["p", ME]])], me: ME, channel: "g", since: since))
    }

    func testSignInAddress() {
        XCTAssertEqual(GuestJoinForm.signInAddress(nip05: "Ana@Example.org", typed: "ana@mail.example", domain: "example.org"), "ana@example.org")
        XCTAssertEqual(GuestJoinForm.signInAddress(nip05: nil, typed: " ana@example.org ", domain: "example.org"), "ana@example.org")
        XCTAssertNil(GuestJoinForm.signInAddress(nip05: "ana@other.org", typed: "ana@gmail.com", domain: "example.org"))
        XCTAssertNil(GuestJoinForm.signInAddress(nip05: "a b@example.org", typed: "", domain: "example.org"))
    }

    /// vectors/guestmode.json (Android's, hand-written from the web's model.ts at b2e968b).
    func testVectors() throws {
        for c in try vector("guestmode").list("cases") {
            let name = c.str("name") ?? ""
            let me = c.str("me") ?? ""
            let d = Derive(events: try events(c["events"]), context: WorldContext(me: me))
            let want = c.dict("expect")
            for (id, v) in want.dict("channels") {
                guard let w = v as? [String: Any] else { continue }
                let g = try XCTUnwrap(d.group(id), name)
                XCTAssertEqual(g.reading, Set(w.strs("reading")), name)
                XCTAssertEqual(g.members, Set(w.strs("members")), name)
                let lines = d.guestJoins(id).map { ["pubkey": $0.pubkey, "unsaved": $0.unsaved] as [String: AnyHashable] }
                let wantLines = w.list("join_lines").map { ["pubkey": $0["pubkey"] as? String ?? "", "unsaved": $0["unsaved"] as? Bool ?? false] as [String: AnyHashable] }
                XCTAssertEqual(lines, wantLines, name)
                XCTAssertEqual(Set(d.recentlyActive(id, now: c.int("now") ?? 0).map(\.pubkey)), Set(w.strs("active")), name)
                XCTAssertEqual(d.readingCount(id), w.int("reading_count"), name)
            }
            XCTAssertEqual(d.onlyReading, Set(want.strs("reading_only")), name)
            XCTAssertEqual(d.amGuest, want["am_guest"] as? Bool, name)
        }
    }

    func testForm() {
        XCTAssertEqual(GuestJoinForm.cleanName("  Ana \n  Silva "), "Ana Silva")
        XCTAssertTrue(GuestJoinForm.canContinue(name: "Ana", email: "a@b.org", askName: true))
        XCTAssertFalse(GuestJoinForm.canContinue(name: "  ", email: "a@b.org", askName: true))
        XCTAssertTrue(GuestJoinForm.canContinue(name: "", email: "a@b.org", askName: false))
        XCTAssertFalse(GuestJoinForm.canContinue(name: "Ana", email: "a@b", askName: true))
    }
}
