import Foundation
import XCTest
@testable import BelfryCore

// push.md §4: the payload is NIP-44 v2 with the device key K as the conversation key.
final class PushTests: XCTestCase {
    let key = Data((0..<32).map { UInt8($0) })
    let ev = String(repeating: "e", count: 64)

    func sample(_ o: [String: Any]) throws -> String {
        try NIP44.encrypt(JSON.encode(o), conversationKey: key, nonce: Data(repeating: 7, count: 32))
    }

    func testMentionOpensIntoItsContent() throws {
        let b = try sample(["v": 1, "domain": "belfry.sh", "type": "mention", "title": "#general", "body": "Ada: are you coming tonight?",
                            "channel": "general", "event": ev, "from": String(repeating: "a", count: 64),
                            "url": "https://chat.belfry.sh/#/c/general/m/\(ev)"])
        let c = try XCTUnwrap(Push.open(b, key: key))
        XCTAssertEqual(c.title, "#general")
        XCTAssertEqual(c.body, "Ada: are you coming tonight?")
        XCTAssertEqual(c.threadId, "general")
        XCTAssertEqual(c.event, ev)
        XCTAssertEqual(Push.route(c.url, domain: "belfry.sh"), .channel("general", message: ev))
        XCTAssertEqual(Push.route(c.url, domain: "enspiral.eu"), .home)
    }

    func testDmAndBadPayloads() throws {
        let b = try sample(["v": 1, "domain": "belfry.sh", "type": "dm", "title": "Belfry", "body": "New message", "url": "https://chat.belfry.sh/#/dm"])
        let c = try XCTUnwrap(Push.open(b, key: key))
        XCTAssertEqual(c.threadId, "dm")
        XCTAssertEqual(Push.route(c.url, domain: "belfry.sh"), .messages)
        XCTAssertNil(Push.open(b, key: Data(repeating: 1, count: 32)))
        XCTAssertNil(Push.open(try sample(["v": 2, "domain": "belfry.sh"]), key: key))
        XCTAssertNil(Push.open("not base64", key: key))
        XCTAssertEqual(Push.route("https://evil.example/#/c/general", domain: "belfry.sh"), .home)
        XCTAssertEqual(Push.route("http://chat.belfry.sh/#/c/general", domain: "belfry.sh"), .home)
        let long = try sample(["v": 1, "domain": "belfry.sh", "type": "message", "body": String(repeating: "x", count: 500)])
        XCTAssertEqual(Push.open(long, key: key)?.body.count, 180)
    }

    func testRegistrationBodyAndSettings() {
        let token = Data([0xde, 0xad, 0xbe, 0xef])
        let add = Push.addBody(token: token, sandbox: true, key: key, name: "iPhone")["add"] as? [String: Any]
        XCTAssertEqual(add?["token"] as? String, "deadbeef")
        XCTAssertEqual(add?["env"] as? String, "sandbox")
        XCTAssertEqual(add?["platform"] as? String, "apns")
        XCTAssertEqual(add?["app"] as? String, "belfry-ios")
        XCTAssertEqual(Data(base64Encoded: add?["key"] as? String ?? ""), key)
        let s = NotificationSettings.parse(["dms": false, "channels": ["general": "mentions", "x": "loud"]])
        XCTAssertFalse(s.dms)
        XCTAssertTrue(s.pins)
        XCTAssertEqual(s.level("general"), "mentions")
        XCTAssertEqual(s.level("x"), "default")
    }
}
