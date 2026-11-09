import Foundation
import XCTest
@testable import BelfryCore

final class NIP44Tests: XCTestCase {
    var v2: [String: Any] = [:]

    override func setUpWithError() throws { v2 = try vector("nip44").dict("v2") }

    func testConversationKeys() throws {
        let cases = v2.dict("valid").list("get_conversation_key")
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let k = try NIP44.conversationKey(secretHex: c.str("sec1")!, publicKeyHex: c.str("pub2")!)
            XCTAssertEqual(k.hex, c.str("conversation_key"), c.str("note") ?? "")
        }
    }

    func testInvalidConversationKeys() {
        for c in v2.dict("invalid").list("get_conversation_key") {
            XCTAssertThrowsError(try NIP44.conversationKey(secretHex: c.str("sec1")!, publicKeyHex: c.str("pub2")!), c.str("note") ?? "")
        }
    }

    func testMessageKeys() throws {
        let mk = v2.dict("valid").dict("get_message_keys")
        let ck = Data(hex: mk.str("conversation_key")!)!
        for k in mk.list("keys") {
            let keys = try NIP44.messageKeys(conversationKey: ck, nonce: Data(hex: k.str("nonce")!)!)
            XCTAssertEqual(keys.chachaKey.hex, k.str("chacha_key"))
            XCTAssertEqual(keys.chachaNonce.hex, k.str("chacha_nonce"))
            XCTAssertEqual(keys.hmacKey.hex, k.str("hmac_key"))
        }
    }

    func testPaddedLength() {
        for c in v2.dict("valid")["calc_padded_len"] as? [[Int]] ?? [] {
            XCTAssertEqual(NIP44.calcPaddedLen(c[0]), c[1], "len \(c[0])")
        }
    }

    func testEncryptDecrypt() throws {
        for c in v2.dict("valid").list("encrypt_decrypt") {
            let ck = try NIP44.conversationKey(secretHex: c.str("sec1")!, publicKeyHex: try Keys.publicKeyHex(secret: Data(hex: c.str("sec2")!)!))
            XCTAssertEqual(ck.hex, c.str("conversation_key"))
            let payload = try NIP44.encrypt(c.str("plaintext")!, conversationKey: ck, nonce: Data(hex: c.str("nonce")!)!)
            XCTAssertEqual(payload, c.str("payload"))
            XCTAssertEqual(try NIP44.decrypt(payload, conversationKey: ck), c.str("plaintext"))
        }
    }

    func testLongMessages() throws {
        for c in v2.dict("valid").list("encrypt_decrypt_long_msg") {
            let plaintext = String(repeating: c.str("pattern")!, count: c.int("repeat")!)
            XCTAssertEqual(Crypto.sha256(plaintext).hex, c.str("plaintext_sha256"))
            let ck = Data(hex: c.str("conversation_key")!)!
            let payload = try NIP44.encrypt(plaintext, conversationKey: ck, nonce: Data(hex: c.str("nonce")!)!)
            XCTAssertEqual(Crypto.sha256(payload).hex, c.str("payload_sha256"))
            XCTAssertEqual(try NIP44.decrypt(payload, conversationKey: ck), plaintext)
        }
    }

    func testInvalidDecrypt() {
        for c in v2.dict("invalid").list("decrypt") {
            let ck = Data(hex: c.str("conversation_key")!)!
            XCTAssertThrowsError(try NIP44.decrypt(c.str("payload")!, conversationKey: ck), c.str("note") ?? "")
        }
    }

    func testInvalidLengths() throws {
        let ck = Data(repeating: 1, count: 32)
        for n in v2.dict("invalid")["encrypt_msg_lengths"] as? [Int] ?? [] {
            XCTAssertThrowsError(try NIP44.encrypt(String(repeating: "a", count: n), conversationKey: ck))
        }
    }
}

final class EventTests: XCTestCase {
    func testSignedEvent() throws {
        let v = try vector("events")
        let signed = try event(v.dict("signed")["event"])
        XCTAssertEqual(signed.computedId, signed.id)
        XCTAssertTrue(signed.isValid)
        XCTAssertFalse(try event(v.dict("tampered")["event"]).isValid)
        for c in v.list("id_only") {
            let t = c.dict("template")
            let e = NostrEvent(pubkey: t.str("pubkey")!, createdAt: t.int("created_at")!, kind: t.int("kind")!, tags: tags(t["tags"]), content: t.str("content")!)
            XCTAssertEqual(e.computedId, c.str("id"))
        }
    }

    func testBech32() throws {
        let v = try vector("events")
        let b = v.list("bech32")
        XCTAssertEqual(Bech32.npub(b[0].str("hex")!), b[0].str("npub"))
        XCTAssertEqual(Bech32.pubkey(npub: b[0].str("npub")!), b[0].str("hex"))
        XCTAssertEqual(Bech32.nsec(b[1].str("secret")!), b[1].str("nsec"))
        XCTAssertNil(Bech32.pubkey(npub: "npub1notavalidkey"))
    }

    func testSignAndVerifyRoundTrip() throws {
        let secret = Keys.generateSecret()
        let s = try LocalSigner(secret: secret)
        let e = try s.signNow(EventTemplate(kind: 1, content: "hi \"there\"\n/é", tags: [["t", "x"]], createdAt: 1_700_000_000))
        XCTAssertTrue(e.isValid)
        XCTAssertEqual(NostrEvent.from(json: e.json), e)
    }

    func testGiftWraps() async throws {
        let v = try vector("events")
        for c in v.list("gift_wraps") {
            let signer = try LocalSigner(secretHex: c.str("recipient_secret")!)
            let wrap = try event(c["wrap"])
            XCTAssertTrue(wrap.isValid)
            let opened = try await GiftWrap.unwrap(wrap, signer: signer)
            let expect = c.dict("expect")
            if expect["rumor"] is NSNull {
                XCTAssertNil(opened, c.str("name")!)
                continue
            }
            let rumor = try event(expect["rumor"])
            XCTAssertEqual(opened?.rumor.id, rumor.id, c.str("name")!)
            XCTAssertEqual(opened?.rumor.content, rumor.content)
            XCTAssertEqual(opened?.sealPubkey, expect.str("seal_pubkey"))
            if let conv = expect.str("conv"), let r = opened?.rumor {
                let d = DmReader.dm(from: r, me: signer.pubkey, bridge: c.str("bridge"), known: [])
                XCTAssertEqual(d?.conv, conv)
                XCTAssertEqual(d?.text, "Hi from e-mail")
                XCTAssertEqual(d?.verified, true)
            }
        }
    }

    func testWrapThenUnwrap() async throws {
        let alice = try LocalSigner(secret: Keys.generateSecret())
        let bob = try LocalSigner(secret: Keys.generateSecret())
        let rumor = GiftWrap.rumor(kind: 14, pubkey: alice.pubkey, tags: [["p", bob.pubkey]], content: "hello")
        let wrap = try await GiftWrap.wrap(rumor, to: bob.pubkey, signer: alice)
        XCTAssertEqual(wrap.kind, 1059)
        XCTAssertTrue(wrap.isValid)
        let opened = try await GiftWrap.unwrap(wrap, signer: bob)
        XCTAssertEqual(opened?.rumor.content, "hello")
        XCTAssertEqual(opened?.rumor.id, rumor.id)
    }

    func testPKCE() {
        // RFC 7636 appendix B
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
}
