import Foundation

// NIP-46 remote signer (SPEC 3): the member's key stays in the belfry's signer; this device holds
// only a client key. Requests are kind 24133, NIP-44 encrypted JSON-RPC, 20 s timeout each; a
// timeout drops the connection so the next request starts fresh.

public final class BunkerSigner: Signer, @unchecked Sendable {
    public let bunker: BunkerURL
    private let client: LocalSigner
    public private(set) var pubkey: String
    private let lock = NSLock()
    private var relay: Relay?
    private var connected = false
    private var waiting = [String: CheckedContinuation<String, Error>]()
    public var timeout: TimeInterval = 20

    /// CLIENTSECRET: this device's key for the bunker (kept in the Keychain). PUBKEY: the member's
    /// key if known already (cached so the app opens offline).
    public init(bunker: BunkerURL, clientSecret: Data, pubkey: String?) throws {
        self.bunker = bunker
        self.client = try LocalSigner(secret: clientSecret)
        self.pubkey = pubkey ?? ""
    }

    /// Asks the signer for the member's key if it is not known yet.
    public func ensurePubkey() async throws -> String {
        if !pubkey.isEmpty { return pubkey }
        let pk = try await request("get_public_key", [])
        guard isHex64(pk) else { throw BelfryError.signer("the signer sent no key") }
        pubkey = pk
        return pk
    }

    private func ensureConnected() async throws -> Relay {
        lock.lock()
        if let r = relay, connected, r.isUp { lock.unlock(); return r }
        lock.unlock()
        let r = Relay(url: bunker.relays[0])
        r.onEvent = { [weak self] _, ev in self?.handle(ev) }
        r.onDisconnect = { [weak self] in self?.reset() }
        try await r.connect()
        r.subscribe("nip46", filters: [["kinds": [24133], "#p": [client.pubkey], "since": Int.now - 10]])
        lock.lock(); relay = r; lock.unlock()
        _ = try await rpc(r, "connect", [bunker.remotePubkey, bunker.secret ?? ""])
        lock.lock(); connected = true; lock.unlock()
        return r
    }

    private func reset() {
        lock.lock()
        let r = relay
        relay = nil
        connected = false
        let w = waiting
        waiting = [:]
        lock.unlock()
        r?.close()
        w.values.forEach { $0.resume(throwing: BelfryError.signer("timeout: the signer did not answer")) }
    }

    private func handle(_ ev: NostrEvent) {
        guard ev.kind == 24133, ev.pubkey == bunker.remotePubkey else { return }
        Task {
            guard let text = try? await client.nip44Decrypt(peer: ev.pubkey, payload: ev.content),
                  let obj = JSON.parse(text) as? [String: Any], let id = obj["id"] as? String else { return }
            lock.lock(); let c = waiting.removeValue(forKey: id); lock.unlock()
            guard let c else { return }
            if let err = obj["error"] as? String, !err.isEmpty {
                c.resume(throwing: BelfryError.signer("signer: " + err))
            } else if let result = obj["result"] as? String {
                if result == "auth_url" { return } // not used by Belfry's signer
                c.resume(returning: result)
            } else {
                c.resume(throwing: BelfryError.signer("signer: empty answer"))
            }
        }
    }

    private func rpc(_ r: Relay, _ method: String, _ params: [String]) async throws -> String {
        let id = Crypto.random(8).hex
        let body = JSON.encode(["id": id, "method": method, "params": params] as [String: Any])
        let content = try await client.nip44Encrypt(peer: bunker.remotePubkey, plaintext: body)
        let ev = try client.signNow(EventTemplate(kind: 24133, content: content, tags: [["p", bunker.remotePubkey]], createdAt: .now))
        let seconds = timeout
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            lock.lock(); waiting[id] = c; lock.unlock()
            Task { try? await r.publish(ev) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let w = self.waiting.removeValue(forKey: id); self.lock.unlock()
                if let w {
                    w.resume(throwing: BelfryError.signer("timeout: the signer did not answer"))
                    self.reset()
                }
            }
        }
    }

    private func request(_ method: String, _ params: [String]) async throws -> String {
        let r = try await ensureConnected()
        return try await rpc(r, method, params)
    }

    public func sign(_ t: EventTemplate) async throws -> NostrEvent {
        let pk = try await ensurePubkey()
        let unsigned = t.event(pubkey: pk)
        let json = "{\"kind\":\(t.kind),\"content\":\(JSON.string(t.content)),\"tags\":[" +
            t.tags.map { "[" + $0.map(JSON.string).joined(separator: ",") + "]" }.joined(separator: ",") +
            "],\"created_at\":\(t.createdAt),\"pubkey\":\(JSON.string(pk))}"
        let result = try await request("sign_event", [json])
        guard let ev = NostrEvent.from(json: result), ev.pubkey == pk, ev.kind == unsigned.kind, ev.content == unsigned.content, ev.isValid else {
            throw BelfryError.signer("signer: the signature does not check out")
        }
        return ev
    }

    public func nip44Encrypt(peer: String, plaintext: String) async throws -> String {
        try await request("nip44_encrypt", [peer, plaintext])
    }

    public func nip44Decrypt(peer: String, payload: String) async throws -> String {
        try await request("nip44_decrypt", [peer, payload])
    }

    public func nip04Decrypt(peer: String, payload: String) async throws -> String {
        try await request("nip04_decrypt", [peer, payload])
    }

    public func disconnect() { reset() }
}
