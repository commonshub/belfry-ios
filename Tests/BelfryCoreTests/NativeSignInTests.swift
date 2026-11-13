import Foundation
import XCTest
@testable import BelfryCore

/// A belfry that answers what the test queued, and remembers what it was asked.
final class StubBelfry: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let body: String }
    struct Asked { let url: String; let method: String; let authorization: String; let body: String }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies = [Reply]()
    nonisolated(unsafe) private static var asked = [Asked]()

    static func reset() { lock.lock(); replies = []; asked = []; lock.unlock() }
    static func enqueue(_ status: Int, _ body: String) { lock.lock(); replies.append(Reply(status: status, body: body)); lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return asked.count }
    /// The oldest request not taken yet.
    static func take() -> Asked? { lock.lock(); defer { lock.unlock() }; return asked.isEmpty ? nil : asked.removeFirst() }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubBelfry.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        StubBelfry.lock.lock()
        StubBelfry.asked.append(Asked(url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "",
                                      authorization: request.value(forHTTPHeaderField: "Authorization") ?? "", body: String(decoding: body, as: UTF8.self)))
        let reply = StubBelfry.replies.isEmpty ? nil : StubBelfry.replies.removeFirst()
        StubBelfry.lock.unlock()
        guard let reply, let url = request.url,
              let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class Clock: @unchecked Sendable {
    var now: Int
    init(_ now: Int) { self.now = now }
}

/// Signing in without a browser (SPEC 19.20): name@domain → a code by e-mail → a NIP-46 session.
final class NativeSignInTests: XCTestCase {
    let endpoint = "https://belfry.example.org/api/v1/session"
    let ab = String(repeating: "ab", count: 32)
    let cd = String(repeating: "cd", count: 32)
    let sentBody = #"{"state":"code_sent","to":"m•••@mail.example.org","nip05":"maya@example.org"}"#

    override func setUp() { StubBelfry.reset() }

    func config() -> BelfryConfig {
        BelfryConfig.from(domain: "example.org", document: ["sign_in": ["sessions": ["api": endpoint]]])
    }

    /// The NIP-98 event of a request, checked against the request itself.
    func auth(_ r: StubBelfry.Asked, file: StaticString = #filePath, line: UInt = #line) throws -> NostrEvent {
        XCTAssertTrue(r.authorization.hasPrefix("Nostr "), file: file, line: line)
        let data = try XCTUnwrap(Data(base64Encoded: String(r.authorization.dropFirst(6))), file: file, line: line)
        let ev = try XCTUnwrap(NostrEvent.from(json: String(decoding: data, as: UTF8.self)), file: file, line: line)
        XCTAssertTrue(ev.isValid, file: file, line: line)
        XCTAssertEqual(ev.kind, 27235, file: file, line: line)
        XCTAssertEqual(r.method, "POST", file: file, line: line)
        XCTAssertTrue(ev.hasTag("method", "POST"), file: file, line: line)
        XCTAssertTrue(ev.hasTag("u", r.url), file: file, line: line)
        XCTAssertTrue(ev.hasTag("payload", Crypto.sha256(Data(r.body.utf8)).hex), file: file, line: line)
        return ev
    }

    func signedBy() throws -> String { try auth(try XCTUnwrap(StubBelfry.take())).pubkey }

    func failure<T>(_ work: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async -> SessionError? {
        do { _ = try await work(); XCTFail("did not throw", file: file, line: line); return nil }
        catch let e as SessionError { return e }
        catch { XCTFail("threw \(error)", file: file, line: line); return nil }
    }

    func testAddresses() {
        XCTAssertEqual(MemberAddress.parse("  Xavier@Belfry.SH "), MemberAddress(name: "xavier", domain: "belfry.sh"))
        XCTAssertEqual(MemberAddress.parse("maya.o-k_1@chat.example.org")?.description, "maya.o-k_1@chat.example.org")
        XCTAssertNotNil(MemberAddress.parse(String(repeating: "x", count: 64) + "@belfry.sh"))
        for bad in ["", "xavier", "belfry.sh", "@belfry.sh", "xavier@", "xavier@belfry", "x y@belfry.sh", "a@b@belfry.sh",
                    "xavier@belfry.sh/path", "xavier@https://belfry.sh", "-x@belfry.sh", "x@bel fry.sh", "<b>@belfry.sh", "x@belfry.sh?x=1",
                    "x\n@belfry.sh", "x@belfry.sh\nmore", "é@belfry.sh", String(repeating: "x", count: 65) + "@belfry.sh"] {
            XCTAssertNil(MemberAddress.parse(bad), bad)
        }
    }

    func testMaskedAddressesAndCodes() {
        XCTAssertTrue(NativeSignIn.isMaskedAddress("x•••@example.org"))
        XCTAssertTrue(NativeSignIn.isMaskedAddress("M•••@mail.example.co.uk"))
        for bad in ["", "your address", "xavier@example.org", "x•••@", "x•••@localhost", "x••@example.org", "xy•••@example.org",
                    "•••@example.org", "x•••@example.org and more", "x•••@<b>.org", "x•••@example.org\n", " •••@example.org",
                    "@•••@example.org", "x•••@" + String(repeating: "a", count: 300) + ".org"] {
            XCTAssertFalse(NativeSignIn.isMaskedAddress(bad), bad)
        }
        XCTAssertEqual(NativeSignIn.digits("123456"), "123456")
        XCTAssertEqual(NativeSignIn.digits("123 456"), "123456")
        XCTAssertEqual(NativeSignIn.digits("Your code: 123456789"), "123456")
        XCTAssertEqual(NativeSignIn.digits("a1b2"), "12")
        XCTAssertEqual(NativeSignIn.digits("١٢٣٤٥٦"), "")
        // pasting into the boxes (#issues 2026-11-13; Android's cases): fills all six, replaces a full row
        XCTAssertEqual(NativeSignIn.next(old: "", raw: "Code: 123 456"), "123456")
        XCTAssertEqual(NativeSignIn.next(old: "", raw: "123 456"), "123456")
        XCTAssertEqual(NativeSignIn.next(old: "12345", raw: "12345654321"), "654321")
        XCTAssertEqual(NativeSignIn.next(old: "123456", raw: "123456654321"), "654321")
        XCTAssertEqual(NativeSignIn.next(old: "123456", raw: "1234567"), "123456")
        XCTAssertEqual(NativeSignIn.next(old: "123456", raw: "12345"), "12345")
        XCTAssertEqual(NativeSignIn.next(old: "123456", raw: "Your code: 654321"), "654321")
        XCTAssertEqual(NativeSignIn.next(old: "12", raw: "12Code: 987 654"), "987654")
        XCTAssertEqual(NativeSignIn.next(old: "", raw: "Your code: 123456789"), "123456")
        XCTAssertEqual(NativeSignIn.next(old: "", raw: "١٢٣٤٥٦"), "")
        XCTAssertTrue(NativeSignIn.isCode("000000"))
        XCTAssertFalse(NativeSignIn.isCode("12345"))
        XCTAssertFalse(NativeSignIn.isCode("12345a"))
        XCTAssertFalse(NativeSignIn.isCode("١٢٣٤٥٦"))
        // signed events are accepted once: two in the same second never carry the same second
        let a = NativeSignIn.stamp(1000)
        let b = NativeSignIn.stamp(1000)
        XCTAssertGreaterThan(b, a)
    }

    func testErrorKeysBecomeFixedMessages() {
        func f(_ status: Int, _ body: String?, _ verifying: Bool = false) -> SessionFailure {
            NativeSignIn.failure(status: status, body: body.flatMap { JSON.parse($0) as? [String: Any] }, verifying: verifying)
        }
        XCTAssertEqual(f(404, #"{"error":"unknown","message":"No member is called <b>x</b> here."}"#), .unknownMember)
        XCTAssertEqual(f(409, #"{"error":"no_email"}"#), .noEmail)
        XCTAssertEqual(f(422, #"{"error":"invalid"}"#), .invalid)
        XCTAssertEqual(f(422, #"{"error":"app_address"}"#), .invalid)
        XCTAssertEqual(f(429, #"{"error":"too_many"}"#), .tooMany)
        XCTAssertEqual(f(401, #"{"error":"unauthorized"}"#), .unauthorized)
        XCTAssertEqual(f(422, #"{"error":"wrong_code","tries_left":3}"#, true), .wrongCode)
        XCTAssertEqual(f(410, #"{"error":"expired"}"#, true), .expired)
        XCTAssertEqual(f(409, #"{"error":"own_key"}"#, true), .ownKey)
        XCTAssertEqual(f(409, #"{"error":"mismatch"}"#, true), .mismatch)
        XCTAssertEqual(f(409, #"{"error":"key_taken"}"#, true), .keyTaken)
        XCTAssertEqual(f(403, #"{"error":"app_not_approved"}"#, true), .notApproved)
        XCTAssertEqual(f(503, #"{"error":"signer","message":"The signer isn't answering"}"#, true), .signer)
        // an older belfry: the route does not exist (FastAPI's own 404, a proxy's page, nothing)
        XCTAssertEqual(f(404, #"{"detail":"Not Found"}"#), .unsupported)
        XCTAssertEqual(f(404, nil), .unsupported)
        XCTAssertEqual(f(405, #"{"detail":"Method Not Allowed"}"#), .unsupported)
        XCTAssertEqual(f(429, nil), .tooMany)
        XCTAssertEqual(f(500, nil), .other)
        XCTAssertEqual(f(503, nil), .other)
        XCTAssertEqual(f(400, #"{"error":"<script>"}"#), .other)
        // which of them send the person back to screen 1
        XCTAssertEqual([SessionFailure.expired, .keyTaken, .ownKey, .mismatch, .notApproved, .wrongCode, .signer, .tooMany, .network, .connect].map(\.endsTheRequest),
                       [true, true, true, true, true, false, false, false, false, false])
        // no message ever carries the server's text
        XCTAssertEqual(SessionError(.wrongCode, triesLeft: 3).display, "That code is not right. 3 tries left.")
        XCTAssertEqual(SessionError(.wrongCode, triesLeft: 1).display, "That code is not right. 1 try left.")
        XCTAssertEqual(SessionError(.wrongCode, triesLeft: 0).display, "That code is not right. Ask for a new one.")
        XCTAssertEqual(SessionError(.wrongCode).display, "That code is not right.")
        XCTAssertEqual(SessionFailure.noBelfry("nowhere.example").message, "There is no belfry at nowhere.example. Check the address and your connection.")
    }

    func testDiscoveryNamesTheEndpoint() {
        XCTAssertEqual(config().sessionAPI, endpoint)
        XCTAssertNil(BelfryConfig.from(domain: "example.org", document: [:]).sessionAPI)
        XCTAssertNil(BelfryConfig.from(domain: "example.org", document: ["sign_in": ["connect": ["authorize": "https://belfry.example.org/connect/authorize"]]]).sessionAPI)
        XCTAssertNil(BelfryConfig.from(domain: "example.org", document: ["sign_in": ["sessions": ["api": "http://belfry.example.org/api/session"]]]).sessionAPI)
        XCTAssertNil(BelfryConfig.from(domain: "example.org", document: ["sign_in": ["sessions": ["api": 7]]]).sessionAPI)
        XCTAssertNil(BelfryConfig.defaults(domain: "example.org").sessionAPI)
    }

    func testTheTwoCalls() async throws {
        let flow = NativeSignIn(endpoint: endpoint, session: StubBelfry.session(), clock: { 1_800_000_000 })
        let key = try LocalSigner(secret: Keys.generateSecret())
        let address = try XCTUnwrap(MemberAddress.parse("maya@example.org"))

        StubBelfry.enqueue(200, sentBody)
        let sent = try await flow.request(address, sessionSecretHex: key.secret.hex)
        XCTAssertEqual(sent.to, "m•••@mail.example.org")
        XCTAssertEqual(sent.nip05, "maya@example.org")
        let r1 = try XCTUnwrap(StubBelfry.take())
        XCTAssertEqual(r1.url, endpoint)
        XCTAssertEqual(r1.body, #"{"nip05":"maya@example.org","app":"sh.belfry.app://connect","client":"belfry-ios"}"#)
        let e1 = try auth(r1)
        XCTAssertEqual(e1.pubkey, key.pubkey)

        // anything but a well-formed mask is not shown
        StubBelfry.enqueue(200, #"{"state":"code_sent","to":"<b>maya</b>@example.org","nip05":"maya@example.org"}"#)
        let second = try await flow.request(address, sessionSecretHex: key.secret.hex)
        XCTAssertNil(second.to)
        let e1b = try auth(try XCTUnwrap(StubBelfry.take()))
        XCTAssertGreaterThan(e1b.createdAt, e1.createdAt, "a resend in the same second is another event")
        XCTAssertNotEqual(e1b.id, e1.id)

        let bunker = "bunker://\(ab)?relay=wss://bunker.example.org&secret=xyz"
        StubBelfry.enqueue(200, #"{"state":"open","bunker_url":"\#(bunker)","pubkey":"\#(cd)","npub":"npub1x","nip05":"maya@example.org"}"#)
        let opened = try await flow.verify("123456", sessionSecretHex: key.secret.hex)
        XCTAssertEqual(opened.bunkerURL, bunker)
        XCTAssertEqual(opened.pubkey, cd)
        let r2 = try XCTUnwrap(StubBelfry.take())
        XCTAssertEqual(r2.url, endpoint + "/verify")
        XCTAssertEqual(r2.body, #"{"code":"123456"}"#)
        let e2 = try auth(r2)
        XCTAssertEqual(e2.pubkey, key.pubkey)
        XCTAssertGreaterThan(e2.createdAt, e1b.createdAt)

        StubBelfry.enqueue(422, #"{"error":"wrong_code","message":"That code is not right (4 tries left).","tries_left":4}"#)
        let wrong = await failure { try await flow.verify("000000", sessionSecretHex: key.secret.hex) }
        XCTAssertEqual(wrong, SessionError(.wrongCode, triesLeft: 4))
        _ = StubBelfry.take()

        // the signer did not answer the belfry
        StubBelfry.enqueue(503, #"{"error":"signer","message":"The signer isn't answering: try again in a moment."}"#)
        let down = await failure { try await flow.verify("123456", sessionSecretHex: key.secret.hex) }
        XCTAssertEqual(down?.failure, .signer)
        _ = StubBelfry.take()

        // not six digits: nothing is sent
        let short = await failure { try await flow.verify("12345", sessionSecretHex: key.secret.hex) }
        XCTAssertEqual(short?.failure, .wrongCode)
        XCTAssertNil(StubBelfry.take())

        // a 200 that is not a session is not a sign-in
        for body in [#"{"state":"open","bunker_url":"https://evil.example","pubkey":"\#(cd)"}"#, #"{"state":"open","bunker_url":"\#(bunker)"}"#,
                     #"{"bunker_url":"\#(bunker)","pubkey":"\#(cd)"}"#, "<html>"] {
            StubBelfry.enqueue(200, body)
            let e = await failure { try await flow.verify("123456", sessionSecretHex: key.secret.hex) }
            XCTAssertEqual(e?.failure, .other, body)
            _ = StubBelfry.take()
        }
        StubBelfry.enqueue(200, #"{"state":"open"}"#)
        let notSent = await failure { try await flow.request(address, sessionSecretHex: key.secret.hex) }
        XCTAssertEqual(notSent?.failure, .other)
        _ = StubBelfry.take()

        StubBelfry.enqueue(404, #"{"detail":"Not Found"}"#)
        let older = await failure { try await flow.request(address, sessionSecretHex: key.secret.hex) }
        XCTAssertEqual(older?.failure, .unsupported)
        // nothing answers
        let offline = await failure { try await flow.request(address, sessionSecretHex: key.secret.hex) }
        XCTAssertEqual(offline?.failure, .network)
        // never over plain http
        let plain = NativeSignIn(endpoint: "http://belfry.example.org/api/v1/session", session: StubBelfry.session())
        let count = StubBelfry.count
        let refused = await failure { try await plain.request(address, sessionSecretHex: key.secret.hex) }
        XCTAssertEqual(refused?.failure, .other)
        XCTAssertEqual(StubBelfry.count, count)
    }

    func testTheWholeFlow() async throws {
        let clock = Clock(1_800_000_000)
        let vault = MemoryVault()
        let cfg = config()
        let member = try LocalSigner(secret: Keys.generateSecret())
        let other = try LocalSigner(secret: Keys.generateSecret())
        let remoteGood = "bunker://\(ab)?relay=wss://bunker.example.org&secret=s3cret"
        let remoteBad = "bunker://\(cd)?relay=wss://bunker.example.org&secret=s3cret"
        let memberKey = member.pubkey, otherKey = other.pubkey, good = ab
        let connects = Clock(0)
        let down = Clock(0)
        func flow() -> NativeSignInFlow {
            NativeSignInFlow(vault: vault, session: StubBelfry.session(), clock: { clock.now }, discover: { domain in
                if domain == "example.org" { return cfg }
                if domain == "old.example.org" { return BelfryConfig.defaults(domain: domain) }
                throw BelfryError.network("no belfry.json")
            }, connect: { bunker, _ in
                connects.now += 1
                if down.now > 0 { down.now -= 1; throw BelfryError.signer("timeout") }
                return bunker.remotePubkey == good ? memberKey : otherKey
            })
        }
        let on = flow()
        XCTAssertNil(on.pending)

        let e1 = await failure { try await on.requestCode("example.org") }
        XCTAssertEqual(e1?.failure, .notAnAddress)
        let none = await failure { try await on.requestCode("maya@nowhere.example") }
        XCTAssertEqual(none?.failure, .noBelfry("nowhere.example"))
        // belfry.json without sign_in.sessions.api: an older belfry, nothing is asked
        let old = await failure { try await on.requestCode("maya@old.example.org") }
        XCTAssertEqual(old?.failure, .unsupported)
        XCTAssertEqual(StubBelfry.count, 0)
        XCTAssertNil(vault.get(NativeSignInFlow.vaultKey))

        StubBelfry.enqueue(404, #"{"error":"unknown","message":"No member is called nobody here."}"#)
        let unknown = await failure { try await on.requestCode("nobody@example.org") }
        XCTAssertEqual(unknown?.failure, .unknownMember)
        XCTAssertFalse(unknown?.display.contains("nobody") ?? true)
        _ = StubBelfry.take()
        XCTAssertNil(on.pending)

        // the route is not there after all: the screen offers the browser
        StubBelfry.enqueue(404, #"{"detail":"Not Found"}"#)
        let browser = await failure { try await on.requestCode("maya@example.org") }
        XCTAssertEqual(browser?.failure, .unsupported)
        let firstKey = try signedBy()

        StubBelfry.enqueue(200, sentBody)
        let pending = try await on.requestCode(" Maya@Example.org ")
        XCTAssertEqual(pending, PendingCode(address: "maya@example.org", to: "m•••@mail.example.org"))
        XCTAssertEqual(try signedBy(), firstKey, "the same address keeps this device's session key")

        // the app was killed while the person read the e-mail: screen 2 comes back
        let again = flow()
        XCTAssertEqual(again.pending, pending)

        // "Send a new code": the same key
        StubBelfry.enqueue(200, sentBody)
        _ = try await again.resendCode()
        XCTAssertEqual(try signedBy(), firstKey)

        StubBelfry.enqueue(422, #"{"error":"wrong_code","tries_left":4}"#)
        let wrong = await failure { try await again.verifyCode("111111") }
        XCTAssertEqual(wrong?.display, "That code is not right. 4 tries left.")
        XCTAssertEqual(try signedBy(), firstKey)
        XCTAssertNotNil(again.pending)

        // the belfry's signer is down: the request stays, a new code is asked with the same key
        StubBelfry.enqueue(503, #"{"error":"signer"}"#)
        let signerDown = await failure { try await again.verifyCode("111112") }
        XCTAssertEqual(signerDown?.failure, .signer)
        _ = StubBelfry.take()
        XCTAssertNotNil(again.pending)
        XCTAssertEqual(connects.now, 0)

        // the belfry names one key, its signer answers with another: no session
        StubBelfry.enqueue(200, #"{"state":"open","bunker_url":"\#(remoteBad)","pubkey":"\#(memberKey)"}"#)
        let mismatch = await failure { try await again.verifyCode("222222") }
        XCTAssertEqual(mismatch?.failure, .mismatch)
        _ = StubBelfry.take()
        XCTAssertNil(again.pending)
        XCTAssertNil(vault.get(NativeSignInFlow.vaultKey))

        // start again: the right code, but the signer does not answer this phone at first
        StubBelfry.enqueue(200, #"{"state":"code_sent","to":"m•••@mail.example.org"}"#)
        _ = try await again.requestCode("maya@example.org")
        let newKey = try signedBy()
        XCTAssertNotEqual(newKey, firstKey)
        StubBelfry.enqueue(200, #"{"state":"open","bunker_url":"\#(remoteGood)","pubkey":"\#(memberKey)"}"#)
        down.now = 1
        let timeout = await failure { try await again.verifyCode("333333") }
        XCTAssertEqual(timeout?.failure, .connect)
        XCTAssertEqual(try signedBy(), newKey)
        // killed again: the bunker address was kept, "Try again" does not spend another code
        let third = flow()
        XCTAssertNotNil(third.pending)
        let session = try await third.verifyCode("333333")
        XCTAssertNil(StubBelfry.take(), "no second verify")
        XCTAssertEqual(session.pubkey, memberKey)
        XCTAssertEqual(session.bunkerURL, remoteGood)
        XCTAssertEqual(session.config.domain, "example.org")
        // the NIP-46 client key is the key that signed the two calls
        XCTAssertEqual(try LocalSigner(secretHex: session.clientSecretHex).pubkey, newKey)
        XCTAssertNil(third.pending)
        XCTAssertNil(vault.get(NativeSignInFlow.vaultKey))
    }

    func testRequestsThatEnd() async throws {
        let clock = Clock(1_800_000_000)
        let vault = MemoryVault()
        let cfg = config()
        let on = NativeSignInFlow(vault: vault, session: StubBelfry.session(), clock: { clock.now }, discover: { _ in cfg }, connect: { _, _ in "" })
        let nothing = await failure { try await on.verifyCode("123456") }
        XCTAssertEqual(nothing?.failure, .expired)
        XCTAssertEqual(StubBelfry.count, 0)

        StubBelfry.enqueue(200, #"{"state":"code_sent","to":"m•••@mail.example.org"}"#)
        _ = try await on.requestCode("maya@example.org")
        let key = try signedBy()
        // 15 minutes later the belfry has forgotten the request: screen 1 again
        clock.now += 901
        XCTAssertNil(on.pending)
        clock.now -= 901
        XCTAssertNotNil(on.pending)

        StubBelfry.enqueue(410, #"{"error":"expired"}"#)
        let expired = await failure { try await on.verifyCode("123456") }
        XCTAssertEqual(expired?.failure, .expired)
        _ = StubBelfry.take()
        XCTAssertNil(on.pending)

        // this device's key is another account's in the signer: the next try makes a new one
        StubBelfry.enqueue(200, #"{"state":"code_sent"}"#)
        let p = try await on.requestCode("maya@example.org")
        XCTAssertNil(p.to)
        let second = try signedBy()
        StubBelfry.enqueue(409, #"{"error":"key_taken"}"#)
        let taken = await failure { try await on.verifyCode("123456") }
        XCTAssertEqual(taken?.failure, .keyTaken)
        _ = StubBelfry.take()
        StubBelfry.enqueue(200, #"{"state":"code_sent"}"#)
        _ = try await on.requestCode("maya@example.org")
        XCTAssertNotEqual(try signedBy(), second)
        XCTAssertNotEqual(second, key)

        // another address: another key
        StubBelfry.enqueue(200, #"{"state":"code_sent"}"#)
        _ = try await on.requestCode("maya@example.org")
        let mayas = try signedBy()
        StubBelfry.enqueue(200, #"{"state":"code_sent"}"#)
        _ = try await on.requestCode("ana@example.org")
        XCTAssertNotEqual(try signedBy(), mayas)
        XCTAssertEqual(on.pending?.address, "ana@example.org")

        // what is in the vault is checked again when read
        vault.set(NativeSignInFlow.vaultKey, #"{"config":{},"address":"<b>","secret":"x"}"#)
        XCTAssertNil(on.pending)

        on.cancel()
        XCTAssertNil(on.pending)
        XCTAssertNil(vault.get(NativeSignInFlow.vaultKey))
    }
}
