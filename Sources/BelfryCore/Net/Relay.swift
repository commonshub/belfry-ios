import Foundation

// One relay connection over URLSessionWebSocketTask (SPEC 4): REQ/EVENT/OK/EOSE/CLOSED/AUTH,
// NIP-42 authentication with the member's signer, publish with a timeout.

public final class Relay: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    public enum State: String, Sendable { case down, connecting, auth, up }

    public let url: String
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pendingOK = [String: CheckedContinuation<Void, Error>]()
    private var subs = [String: [[String: Any]]]() // sub id → filters, resent after AUTH
    private var openWaiters = [String: CheckedContinuation<Void, Error>]()
    private var authWaiters = [String: CheckedContinuation<Void, Error>]()
    private var authEventId: String?
    private(set) public var state: State = .down
    private var opened = false
    private var queries = [String: QueryBox]()

    /// The signer for NIP-42 (nil: no AUTH).
    public var authSigner: Signer?
    public var onEvent: ((String, NostrEvent) -> Void)?
    public var onEOSE: ((String) -> Void)?
    public var onClosed: ((String, String) -> Void)?
    public var onState: ((State) -> Void)?
    /// Called when the socket closes or fails (not after an explicit close()).
    public var onDisconnect: (() -> Void)?

    public init(url: String) {
        self.url = url
    }

    private func set(_ s: State) {
        lock.lock(); state = s; lock.unlock()
        onState?(s)
    }

    public var isUp: Bool { lock.lock(); defer { lock.unlock() }; return state == .up || state == .auth }

    // ---- connecting ---------------------------------------------------------------------------

    public func connect(timeout: TimeInterval = 15) async throws {
        if isUp { return }
        guard let u = URL(string: url) else { throw BelfryError.relay("bad relay url") }
        set(.connecting)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        let t = s.webSocketTask(with: u)
        lock.lock(); session = s; task = t; opened = false; lock.unlock()
        t.resume()
        receive(t)
        let key = UUID().uuidString
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                if self.opened { self.lock.unlock(); c.resume(); return }
                self.openWaiters[key] = c
                self.lock.unlock()
                self.expire(after: timeout) {
                    self.lock.lock(); let w = self.openWaiters.removeValue(forKey: key); self.lock.unlock()
                    w?.resume(throwing: BelfryError.relay("timeout: no connection to the relay"))
                }
            }
        } catch {
            close()
            throw error
        }
        set(.up)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        opened = true
        let w = openWaiters.values
        openWaiters = [:]
        lock.unlock()
        w.forEach { $0.resume() }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        dropped()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        dropped()
    }

    private func dropped() {
        lock.lock()
        let wasActive = task != nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
        let oks = pendingOK
        pendingOK = [:]
        let w = Array(openWaiters.values) + Array(authWaiters.values)
        openWaiters = [:]
        authWaiters = [:]
        lock.unlock()
        oks.values.forEach { $0.resume(throwing: BelfryError.relay("connection closed")) }
        w.forEach { $0.resume(throwing: BelfryError.relay("connection closed")) }
        set(.down)
        if wasActive { onDisconnect?() }
    }

    public func close() {
        lock.lock()
        let t = task
        let s = session
        task = nil
        session = nil
        lock.unlock()
        t?.cancel(with: .goingAway, reason: nil)
        s?.invalidateAndCancel()
        set(.down)
    }

    // ---- sending ------------------------------------------------------------------------------

    private func send(_ array: [Any]) {
        lock.lock(); let t = task; lock.unlock()
        guard let t else { return }
        t.send(.string(JSON.encode(array))) { _ in }
    }

    /// Text frames with events need the canonical event JSON (JSONSerialization reorders and escapes).
    private func sendRaw(_ text: String) {
        lock.lock(); let t = task; lock.unlock()
        t?.send(.string(text)) { _ in }
    }

    public func subscribe(_ id: String, filters: [[String: Any]]) {
        lock.lock(); subs[id] = filters; lock.unlock()
        send(["REQ", id] + filters)
    }

    public func unsubscribe(_ id: String) {
        lock.lock(); subs[id] = nil; lock.unlock()
        send(["CLOSE", id])
    }

    private func resubscribe() {
        lock.lock(); let all = subs; lock.unlock()
        for (id, f) in all { send(["REQ", id] + f) }
    }

    /// Publishes EVENT and waits for OK (15 s). Throws the relay's reason ("restricted: …").
    public func publish(_ event: NostrEvent, timeout: TimeInterval = 15) async throws {
        do {
            try await publishOnce(event, timeout: timeout)
        } catch let e as BelfryError {
            guard e.relayMessage.hasPrefix("auth-required"), authSigner != nil else { throw e }
            try await waitForAuth(timeout: timeout)
            try await publishOnce(event, timeout: timeout)
        }
    }

    private func expire(after seconds: TimeInterval, _ f: @escaping () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: f)
    }

    private func publishOnce(_ event: NostrEvent, timeout: TimeInterval) async throws {
        lock.lock(); let connected = task != nil; lock.unlock()
        guard connected else { throw BelfryError.relay("timeout: no connection to the relay") }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.lock.lock()
            if let old = self.pendingOK[event.id] { old.resume(throwing: BelfryError.relay("timeout: replaced")) }
            self.pendingOK[event.id] = c
            self.lock.unlock()
            self.sendRaw("[\"EVENT\",\(event.json)]")
            self.expire(after: timeout) {
                self.lock.lock(); let w = self.pendingOK.removeValue(forKey: event.id); self.lock.unlock()
                w?.resume(throwing: BelfryError.relay("timeout: the relay did not answer"))
            }
        }
    }

    private func waitForAuth(timeout: TimeInterval) async throws {
        let key = UUID().uuidString
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.lock.lock()
            if self.authEventId == "done" { self.lock.unlock(); c.resume(); return }
            self.authWaiters[key] = c
            self.lock.unlock()
            self.expire(after: timeout) {
                self.lock.lock(); let w = self.authWaiters.removeValue(forKey: key); self.lock.unlock()
                w?.resume(throwing: BelfryError.relay("timeout: sign-in to the relay"))
            }
        }
    }

    // ---- receiving ----------------------------------------------------------------------------

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.dropped()
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(s)
                case .data(let d): self.handle(String(decoding: d, as: UTF8.self))
                @unknown default: break
                }
                self.lock.lock(); let same = self.task === t; self.lock.unlock()
                if same { self.receive(t) }
            }
        }
    }

    private func handle(_ text: String) {
        guard let arr = JSON.parse(text) as? [Any], let type = arr.first as? String else { return }
        switch type {
        case "EVENT":
            guard arr.count >= 3, let sub = arr[1] as? String, let obj = arr[2] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: obj),
                  let ev = try? JSONDecoder().decode(NostrEvent.self, from: data) else { return }
            lock.lock(); let q = queries[sub]; lock.unlock()
            if let q { q.add(ev) } else { onEvent?(sub, ev) }
        case "EOSE":
            guard arr.count >= 2, let sub = arr[1] as? String else { return }
            lock.lock(); let q = queries[sub]; lock.unlock()
            if let q { q.finish() } else { onEOSE?(sub) }
        case "OK":
            guard arr.count >= 3, let id = arr[1] as? String else { return }
            let ok = (arr[2] as? Bool) ?? ((arr[2] as? NSNumber)?.boolValue ?? false)
            let reason = arr.count > 3 ? (arr[3] as? String ?? "") : ""
            lock.lock()
            if id == authEventId {
                authEventId = ok ? "done" : nil
                let w = Array(authWaiters.values)
                authWaiters = [:]
                lock.unlock()
                if ok {
                    set(.up)
                    resubscribe()
                    w.forEach { $0.resume() }
                } else {
                    w.forEach { $0.resume(throwing: BelfryError.relay(reason.isEmpty ? "restricted: sign-in refused" : reason)) }
                }
                return
            }
            let c = pendingOK.removeValue(forKey: id)
            lock.unlock()
            if ok { c?.resume() } else { c?.resume(throwing: BelfryError.relay(reason.isEmpty ? "error: refused" : reason)) }
        case "CLOSED":
            if arr.count >= 2, let sub = arr[1] as? String { onClosed?(sub, arr.count > 2 ? (arr[2] as? String ?? "") : "") }
        case "AUTH":
            guard arr.count >= 2, let challenge = arr[1] as? String, let signer = authSigner else { return }
            set(.auth)
            Task {
                do {
                    let ev = try await signer.sign(Actions.relayAuth(relay: self.url, challenge: challenge))
                    self.lock.lock(); self.authEventId = ev.id; self.lock.unlock()
                    self.sendRaw("[\"AUTH\",\(ev.json)]")
                } catch {
                    self.lock.lock(); let w = Array(self.authWaiters.values); self.authWaiters = [:]; self.lock.unlock()
                    w.forEach { $0.resume(throwing: error) }
                    self.set(.up)
                }
            }
        case "NOTICE":
            break
        default:
            break
        }
    }

    /// One-off query up to EOSE (or the timeout).
    public func query(_ filters: [[String: Any]], timeout: TimeInterval = 8) async -> [NostrEvent] {
        let id = "q" + Crypto.random(4).hex
        let box = QueryBox()
        return await withCheckedContinuation { (c: CheckedContinuation<[NostrEvent], Never>) in
            box.cont = c
            box.onFinish = { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.queries[id] = nil; self.lock.unlock()
                self.send(["CLOSE", id])
            }
            self.lock.lock(); self.queries[id] = box; let connected = self.task != nil; self.lock.unlock()
            if !connected { box.finish(); return }
            self.send(["REQ", id] + filters)
            self.expire(after: timeout) { box.finish() }
        }
    }
}

final class QueryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [NostrEvent]()
    var cont: CheckedContinuation<[NostrEvent], Never>?
    var onFinish: (() -> Void)?
    func add(_ e: NostrEvent) { lock.lock(); events.append(e); lock.unlock() }
    func finish() {
        lock.lock()
        let c = cont
        cont = nil
        let list = events
        let f = onFinish
        lock.unlock()
        if let c { f?(); c.resume(returning: list) }
    }
}

/// Runs OP; throws BelfryError.relay(MESSAGE) after SECONDS.
public func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ message: String, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw BelfryError.relay(message)
        }
        defer { g.cancelAll() }
        return try await g.next()!
    }
}
