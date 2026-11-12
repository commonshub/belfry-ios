import Foundation
import Network

// The sync engine (SPEC 4-5): two relays (groups, main), subscriptions with overlapping `since`,
// the outbox flushed in order per relay, wake-ups (network back, foreground, 15 s watchdog).
// In local-only (demo) mode nothing leaves the device and the engine plays the relay's part.

public enum AccessState: String, Sendable { case unknown, ok, denied }

public final class SyncEngine: @unchecked Sendable {
    public static let kindsGroups = [0, 39000, 39001, 39002, 9, 1111, 1010, 7, 9007, 9002, 9008, 9000, 9001, 9005, 9021, 9022, 1068, 1018, 5, 1985, 30078, 2100, 2101, 2102, 2103, 31925, 8534, 8535, 8536, 8538]
    public static let kindsMain = [0, 31922, 31923, 31925, 30023, 30402, 5]
    public static let clientTag: Tag = ["client", "belfry-ios"]

    public let config: BelfryConfig
    public let db: Database
    public let signer: Signer
    public let localOnly: Bool
    public let attachmentsDir: URL
    /// Guest mode (SPEC 19.26): while reading, nothing is queued, signed for a request or uploaded.
    public let guestMode = GuestModeGate()

    private let lock = NSLock()
    private var events = [String: NostrEvent]()
    private var outbox = [String: OutboxItem]()
    private var relays = [Target: Relay]()
    private var attempts = [Target: Int]()
    private var connecting = Set<Target>()
    private var lastCreatedAt = 0
    private var flushing = false
    private var flushAgain = false
    private var started = false
    private var firstChannelTried = false
    private var watchdog: Timer?
    private let monitor = NWPathMonitor()
    public private(set) var online = true
    public private(set) var access: AccessState = .unknown
    public private(set) var relayStates = [String: Relay.State]()
    private var cache: (version: Int, list: [NostrEvent])?
    public private(set) var version = 0

    /// Something changed (events, outbox, status): views read again. Called on any thread.
    public var onChange: (() -> Void)?
    /// An outbox item went out (with its event) or failed for good.
    public var onSent: ((OutboxItem, NostrEvent?) -> Void)?
    public var onFailed: ((OutboxItem) -> Void)?
    /// New events arrived (after storing).
    public var onNewEvents: (([NostrEvent]) -> Void)?

    public init(config: BelfryConfig, db: Database, signer: Signer, localOnly: Bool, attachmentsDir: URL) {
        self.config = config
        self.db = db
        self.signer = signer
        self.localOnly = localOnly
        self.attachmentsDir = attachmentsDir
        for e in db.allEvents() { events[e.id] = e }
        for o in db.outbox() { outbox[o.localId] = o }
        lastCreatedAt = events.values.filter { $0.pubkey == signer.pubkey }.map(\.createdAt).max() ?? 0
    }

    public var me: String { signer.pubkey }

    private func changed() {
        lock.lock(); version += 1; lock.unlock()
        onChange?()
    }

    // ---- the log ----------------------------------------------------------------------------------

    /// All events, with queued outbox items shown as if published (gift wraps excluded).
    public func snapshot() -> [NostrEvent] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.version == version { return c.list }
        var list = Array(events.values)
        for o in outbox.values where o.signed == nil { list.append(o.asEvent(me: me)) }
        cache = (version, list)
        return list
    }

    public func outboxItems() -> [OutboxItem] {
        lock.lock(); defer { lock.unlock() }
        return outbox.values.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.localId < $1.localId }
    }

    public func pending(_ id: String) -> OutboxItem? {
        lock.lock(); defer { lock.unlock() }
        return outbox[id]
    }

    /// Stores events (signatures checked for relay events), returns the new ones.
    @discardableResult
    public func add(_ list: [NostrEvent], verify: Bool = true) -> [NostrEvent] {
        let ok = verify ? list.filter(\.isValid) : list
        lock.lock()
        let unseen = ok.filter { events[$0.id] == nil }
        for e in unseen { events[e.id] = e }
        lock.unlock()
        guard !unseen.isEmpty else { return [] }
        db.add(unseen)
        changed()
        onNewEvents?(unseen)
        return unseen
    }

    /// The newest member profile extras (kind 30078, d = belfry:profile) held (SPEC 19.9).
    func latestProfileExtras() -> Int {
        lock.lock(); defer { lock.unlock() }
        return events.values.filter { $0.kind == 30078 && $0.hasTag("d", Derive.profileD) }.map(\.createdAt).max() ?? 0
    }

    public func latest(_ kinds: [Int]) -> Int {
        lock.lock(); defer { lock.unlock() }
        return events.values.filter { kinds.contains($0.kind) }.map(\.createdAt).max() ?? 0
    }

    // ---- the outbox -------------------------------------------------------------------------------

    func nextCreatedAt() -> Int {
        lock.lock(); defer { lock.unlock() }
        lastCreatedAt = Outbox.nextCreatedAt(last: lastCreatedAt)
        return lastCreatedAt
    }

    @discardableResult
    public func enqueue(_ d: Draft, attachments: [Attachment] = []) -> String {
        if guestMode.refuse() { return "" } // guest mode: nothing is sent; the Join sheet opens
        let item = OutboxItem(target: d.target, kind: d.kind, content: d.content, tags: d.tags + [SyncEngine.clientTag],
                              createdAt: nextCreatedAt(), attachments: attachments)
        put(item)
        flushSoon()
        return item.localId
    }

    @discardableResult
    public func enqueueSigned(_ ev: NostrEvent, target: Target, dm: String?) -> String {
        if guestMode.refuse() { return "" }
        let item = OutboxItem(target: target, kind: ev.kind, content: ev.content, tags: ev.tags, createdAt: ev.createdAt, signed: ev, dm: dm)
        put(item)
        flushSoon()
        return item.localId
    }

    func put(_ item: OutboxItem) {
        lock.lock(); outbox[item.localId] = item; lock.unlock()
        db.putOutbox(item)
        changed()
    }

    func drop(_ localId: String) {
        lock.lock(); outbox[localId] = nil; lock.unlock()
        db.dropOutbox(localId)
        changed()
    }

    public func retry(_ localId: String) {
        lock.lock()
        guard var item = outbox[localId] else { lock.unlock(); return }
        lock.unlock()
        item.status = .queued
        item.error = nil
        put(item)
        flushSoon()
    }

    /// Removes a queued item that has not gone out (a reaction taken back before it was sent).
    public func cancel(_ localId: String) { drop(localId) }

    public func flushSoon() { Task { await self.flush() } }

    public func flush() async {
        lock.lock()
        if flushing { flushAgain = true; lock.unlock(); return }
        flushing = true
        flushAgain = false
        lock.unlock()
        let items = outboxItems()
        let result = await OutboxPass.run(items) { item in
            if !self.localOnly && !self.online { return .error("timeout: offline") }
            do { return .ok(try await self.send(item)) } catch let e as BelfryError { return .error(e.relayMessage) } catch { return .error("timeout: \(error.localizedDescription)") }
        }
        for (item, ev) in result.sent {
            if let ev, item.signed == nil {
                lock.lock(); events[ev.id] = ev; lock.unlock()
                db.add([ev])
            }
            drop(item.localId)
            onSent?(item, ev)
        }
        for item in result.items {
            lock.lock(); let cur = outbox[item.localId]; lock.unlock()
            if cur != nil, cur != item { put(item) }
        }
        for f in result.failed { onFailed?(f) }
        lock.lock()
        flushing = false
        let again = flushAgain && result.items.allSatisfy { $0.status == .failed || $0.tries == 0 }
        lock.unlock()
        if again { await flush() }
    }

    private func send(_ item: OutboxItem) async throws -> NostrEvent {
        if let signed = item.signed {
            if localOnly { return signed }
            try await publish(item.target, signed)
            return signed
        }
        var content = item.content
        var tags = item.tags
        for a in item.attachments {
            let file = attachmentsDir.appendingPathComponent(a.file)
            let url: String
            var x: String?
            if localOnly {
                url = file.absoluteString
            } else {
                guard let data = try? Data(contentsOf: file) else { continue }
                x = Crypto.sha256(data).hex
                url = try await upload(data, name: a.name, mime: a.mime, sha: x!)
            }
            var imeta: Tag = ["imeta", "url \(url)", "m \(a.mime)", "size \(a.size)"]
            if let x { imeta.append("x \(x)") }
            if let w = a.width, let h = a.height { imeta.append("dim \(w)x\(h)") }
            imeta.append("alt \(a.name)")
            tags.append(imeta)
            content = content.isEmpty ? url : content + "\n" + url
        }
        let ev = try await signer.sign(EventTemplate(kind: item.kind, content: content, tags: tags, createdAt: item.createdAt))
        if localOnly {
            synthesizeRelayEvents(ev)
            return ev
        }
        try await publish(item.target, ev)
        return ev
    }

    /// Local-only mode: what the relay would publish for 9007 / 9002 / 9000.
    private func synthesizeRelayEvents(_ ev: NostrEvent) {
        guard let h = ev.tag("h"), ev.kind == 9007 || ev.kind == 9002 else { return }
        let meta = ev.tags.filter { ["name", "about", "picture"].contains($0.first ?? "") }
        var out = [NostrEvent]()
        if ev.kind == 9002 || !meta.isEmpty {
            out.append(NostrEvent(id: Crypto.sha256("meta-" + ev.id).hex, pubkey: ev.pubkey, createdAt: ev.createdAt, kind: 39000, tags: [["d", h]] + meta, content: ""))
        }
        if ev.kind == 9007 {
            out.append(NostrEvent(id: Crypto.sha256("members-" + ev.id).hex, pubkey: ev.pubkey, createdAt: ev.createdAt, kind: 39002, tags: [["d", h], ["p", ev.pubkey]], content: ""))
        }
        add(out, verify: false)
    }

    // ---- Blossom, NIP-98 -------------------------------------------------------------------------

    public func upload(_ data: Data, name: String, mime: String, sha: String) async throws -> String {
        try guestMode.check()
        let auth = try await signer.sign(Actions.blossomAuth(sha256: sha, name: name))
        guard let url = URL(string: config.blossom + "/upload") else { throw BelfryError.network("upload failed (no file server)") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "PUT"
        req.setValue("Nostr " + Data(auth.json.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        let (body, resp) = try await URLSession.shared.upload(for: req, from: data)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let u = obj["url"] as? String else {
            throw BelfryError.network("upload failed (\(status))")
        }
        return u
    }

    /// A request with a NIP-98 Authorization header signed by the member.
    public func signedRequest(_ urlString: String, method: String = "GET", json: [String: Any]? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw BelfryError.invalid("bad url") }
        try guestMode.check(url: urlString, method: method)
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let auth = try await signer.sign(Actions.httpAuth(url: urlString, method: method, body: body))
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Nostr " + Data(auth.json.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // ---- relays -----------------------------------------------------------------------------------

    func url(_ t: Target) -> String { t == .groups ? config.groupsRelay : config.mainRelay }

    func relay(_ t: Target) async throws -> Relay {
        lock.lock()
        if let r = relays[t], r.isUp { lock.unlock(); return r }
        lock.unlock()
        let r = Relay(url: url(t))
        r.authSigner = signer
        r.onEvent = { [weak self] _, ev in self?.add([ev]) }
        r.onEOSE = { [weak self] sub in self?.eose(t, sub) }
        r.onClosed = { [weak self] sub, reason in self?.closed(t, sub, reason) }
        r.onState = { [weak self] s in
            guard let self else { return }
            self.lock.lock(); self.relayStates[self.url(t)] = s; self.lock.unlock()
            self.changed()
        }
        r.onDisconnect = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let same = self.relays[t] === r
            if same { self.relays[t] = nil }
            self.lock.unlock()
            if same { self.retryLater(t) }
        }
        try await r.connect()
        lock.lock(); relays[t] = r; attempts[t] = 0; lock.unlock()
        return r
    }

    func backoff(_ t: Target) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let n = (attempts[t] ?? 0) + 1
        attempts[t] = n
        return min(30, 0.8 * pow(2, Double(n)))
    }

    func retryLater(_ t: Target) {
        let delay = backoff(t)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { await self?.connect(t) }
        }
    }

    func publish(_ t: Target, _ ev: NostrEvent) async throws {
        let r = try await relay(t)
        try await r.publish(ev)
    }

    /// One-off query up to EOSE.
    public func query(_ t: Target, _ filters: [[String: Any]], timeout: TimeInterval = 8) async -> [NostrEvent] {
        if localOnly { return [] }
        guard let r = try? await relay(t) else { return [] }
        return await r.query(filters, timeout: timeout)
    }

    func filters(_ t: Target) -> [[String: Any]] {
        let kinds = t == .groups ? SyncEngine.kindsGroups : SyncEngine.kindsMain
        let since = max(0, latest(kinds) - 3600)
        if t == .groups { return [["kinds": kinds, "since": since, "limit": 2000]] }
        let wraps = max(0, latest([1059]) - 3 * 86400)
        let old = max(0, latest([4]) - 3600)
        let extras = max(0, latestProfileExtras() - 3600)
        return [
            ["kinds": kinds, "since": since, "limit": 2000],
            ["kinds": [30078], "#d": [Derive.profileD], "since": extras, "limit": 2000],
            ["kinds": [1059], "#p": [me], "since": wraps, "limit": 1000],
            ["kinds": [4], "#p": [me], "since": old, "limit": 500],
            ["kinds": [4], "authors": [me], "since": old, "limit": 500],
        ]
    }

    func subscribe(_ t: Target, _ r: Relay) {
        r.subscribe("live-" + t.rawValue, filters: filters(t))
    }

    func eose(_ t: Target, _ sub: String) {
        guard t == .groups else { return }
        if access != .ok { access = .ok; changed() }
        firstChannel()
    }

    func closed(_ t: Target, _ sub: String, _ reason: String) {
        if reason.hasPrefix("auth-required") { return } // the relay resubscribes after AUTH
        if t == .groups { noteRefusal(reason) }
    }

    func noteRefusal(_ reason: String) {
        if Rx("^(restricted|blocked)|pass|member", [.caseInsensitive]).test(reason) {
            access = .denied
            changed()
        }
    }

    /// A new belfry has no channel yet: the first member in opens #general.
    func firstChannel() {
        lock.lock()
        let tried = firstChannelTried
        firstChannelTried = true
        let hasAny = events.values.contains { $0.kind == 39000 }
        lock.unlock()
        guard !tried, !hasAny, !guestMode.reading else { return }
        for d in Actions.createChannel(id: generalId, name: "general", about: "Everything about \(config.name). Say hi 👋") { enqueue(d) }
    }

    public func connect(_ t: Target) async {
        if localOnly { return }
        lock.lock()
        if relays[t]?.isUp == true || connecting.contains(t) || !online { lock.unlock(); return }
        connecting.insert(t)
        lock.unlock()
        defer { lock.lock(); connecting.remove(t); lock.unlock() }
        do {
            let r = try await relay(t)
            subscribe(t, r)
            await flush()
        } catch {
            retryLater(t)
        }
    }

    // ---- life cycle -------------------------------------------------------------------------------

    public func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let up = path.status == .satisfied
            let was = self.online
            self.online = up
            if up != was {
                self.changed()
                if up { self.wake() } else { self.dropSockets() }
            }
        }
        monitor.start(queue: DispatchQueue.global())
        DispatchQueue.main.async {
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        }
        if !localOnly { wake() } // local-only (demo) data is seeded by the app
        flushSoon()
    }

    /// Network back, app in the foreground, pull to refresh: reconnect, catch up, send.
    public func wake() {
        lock.lock(); attempts = [:]; lock.unlock()
        Task {
            await connect(.groups)
            await connect(.main)
            await flush()
        }
    }

    /// Re-sends the subscriptions (catching up from the latest event).
    public func refresh() async {
        if localOnly { return }
        for t in [Target.groups, .main] {
            if let r = try? await relay(t) { subscribe(t, r) }
        }
        await flush()
    }

    private func tick() {
        if localOnly { return }
        if online { for t in [Target.groups, .main] where relays[t]?.isUp != true { Task { await connect(t) } } }
        if outboxItems().contains(where: { $0.status != .failed }) { flushSoon() }
    }

    private func dropSockets() {
        lock.lock()
        let rs = relays
        relays = [:]
        lock.unlock()
        for r in rs.values { r.onDisconnect = nil; r.close() }
    }

    public func stop() {
        monitor.cancel()
        DispatchQueue.main.async { self.watchdog?.invalidate() }
        dropSockets()
    }

    public var relaysUp: Bool {
        if localOnly { return true }
        lock.lock(); defer { lock.unlock() }
        return relays[.groups]?.isUp == true
    }
}
