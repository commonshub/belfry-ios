import Foundation

// Direct messages and e-mail (SPEC 10): unwraps gift wraps as they arrive, keeps the decrypted
// messages on this device (Database kv), sends NIP-17 messages and Nostr Mail through the outbox,
// follows delivery reports. From src/core/dm.ts.

public struct DmThread: Hashable, Sendable, Identifiable {
    public let conv: String
    public let last: Dm
    public let unread: Int
    public let count: Int
    public var id: String { conv }
}

public final class DirectMessages: @unchecked Sendable {
    let engine: SyncEngine
    let db: Database
    private let lock = NSLock()
    private var items = [String: Dm]()
    private var seen = Set<String>()
    private var read = [String: Int]()
    private var reports = [String: DeliveryReport]()
    private var busy = false
    public var myAddress: String?
    public private(set) var bridge: String?
    public var onChange: (() -> Void)?

    public init(engine: SyncEngine) {
        self.engine = engine
        self.db = engine.db
        for d in db.get("dm-items", as: [Dm].self) ?? [] { items[d.rid] = d }
        seen = Set(db.get("dm-seen", as: [String].self) ?? [])
        read = db.get("dm-read", as: [String: Int].self) ?? [:]
        reports = db.get("dm-reports", as: [String: DeliveryReport].self) ?? [:]
        bridge = db.get("dm-bridge", as: String.self)
    }

    var me: String { engine.me }

    private func save() {
        lock.lock()
        let list = Array(items.values), s = Array(seen), rp = reports
        lock.unlock()
        db.set("dm-items", list)
        db.set("dm-seen", s)
        db.set("dm-reports", rp)
        onChange?()
    }

    /// The mail bridge key (`_smtp@<domain>`), cached.
    public func loadBridge() async {
        if engine.localOnly { return }
        if let k = await Discovery.nip05(name: "_smtp", domain: engine.config.domain) {
            bridge = k
            db.set("dm-bridge", k)
        }
    }

    /// Demo mode: a stand-in bridge key.
    public func setBridge(_ k: String) { bridge = k }

    // ---- reading ----------------------------------------------------------------------------------

    /// Unwraps every gift wrap (and kind 4) not read yet, newest first.
    public func process() async {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }
        let todo = engine.snapshot().filter { e in
            engine.pending(e.id) == nil && !seen.contains(e.id) &&
                ((e.kind == 1059 && e.tags.contains { $0.first == "p" && $0.count > 1 && $0[1] == me }) || e.kind == 4)
        }.sorted { $0.createdAt > $1.createdAt }
        var changed = false
        for e in todo {
            do {
                var d: Dm?
                if e.kind == 1059 {
                    if let opened = try await GiftWrap.unwrap(e, signer: engine.signer) {
                        lock.lock()
                        let known = items.values.map { (messageId: $0.messageId, conv: $0.conv) }
                        lock.unlock()
                        d = DmReader.dm(from: opened.rumor, me: me, bridge: bridge, known: known)
                    }
                } else if e.pubkey == me || e.hasTag("p", me), let bunker = engine.signer as? BunkerSigner {
                    let peer = e.pubkey == me ? (e.tag("p") ?? me) : e.pubkey
                    let text = (try? await bunker.nip04Decrypt(peer: peer, payload: e.content)) ?? "(an old-style message this app cannot read)"
                    d = Dm(rid: e.id, conv: "n:" + peer, from: e.pubkey, mine: e.pubkey == me, at: e.createdAt, kind: 4, text: text)
                }
                lock.lock()
                if let d {
                    var n = d
                    if let old = items[d.rid] { n.mine = d.mine || old.mine; n.pending = old.pending; n.failed = old.failed }
                    items[d.rid] = n
                }
                seen.insert(e.id)
                lock.unlock()
                changed = true
            } catch {
                if "\(error)".contains("timeout") { break } // the signer is away: next time
                lock.lock(); seen.insert(e.id); lock.unlock()
                changed = true
            }
        }
        if changed { save() }
    }

    // ---- views ------------------------------------------------------------------------------------

    public func threads() -> [DmThread] {
        lock.lock(); defer { lock.unlock() }
        var by = [String: [Dm]]()
        for d in items.values { by[d.conv, default: []].append(d) }
        return by.map { conv, list in
            let sorted = list.sorted { $0.at < $1.at }
            let r = read[conv] ?? 0
            return DmThread(conv: conv, last: sorted.last!, unread: sorted.filter { !$0.mine && $0.at > r }.count, count: sorted.count)
        }.sorted { $0.last.at > $1.last.at }
    }

    public func thread(_ conv: String) -> [Dm] {
        lock.lock(); defer { lock.unlock() }
        return items.values.filter { $0.conv == conv }.sorted { $0.at < $1.at }
    }

    public var unreadTotal: Int { threads().filter { $0.unread > 0 }.count }

    public func report(_ emailId: String?) -> DeliveryReport? {
        guard let emailId else { return nil }
        lock.lock(); defer { lock.unlock() }
        return reports[emailId]
    }

    /// A mail thread's name: its subject without Re:/Fwd:.
    public func threadName(_ conv: String) -> String {
        let s = MailThreads.baseSubject(thread(conv).first { $0.subject != nil }?.subject)
        return s.isEmpty ? "(no subject)" : s
    }

    public func markRead(_ conv: String) {
        let last = thread(conv).last?.at ?? 0
        lock.lock()
        guard (read[conv] ?? 0) < last else { lock.unlock(); return }
        read[conv] = last
        let r = read
        lock.unlock()
        db.set("dm-read", r)
        onChange?()
    }

    // ---- sending ----------------------------------------------------------------------------------

    func deliver(_ rumor: NostrEvent, to: [String], selfCopy: Bool = true) async throws {
        try engine.guestMode.check()
        var targets = [String]()
        for p in to + (selfCopy ? [me] : []) where !targets.contains(p) { targets.append(p) }
        for p in targets {
            let w = try await GiftWrap.wrap(rumor, to: p, signer: engine.signer)
            if engine.localOnly, p == me { engine.add([w], verify: false) }
            engine.enqueueSigned(w, target: .main, dm: rumor.id)
        }
    }

    /// Called when this device sends a DM or an e-mail (push: stay quiet for its own echo).
    public var onSend: (() -> Void)?

    /// A NIP-17 message in a Nostr conversation.
    public func send(_ text: String, in conv: String) async throws {
        try engine.guestMode.check()
        onSend?()
        let to = MailThreads.peers(conv).filter { $0 != me }
        guard to.allSatisfy(isHex64) else { throw BelfryError.invalid("This is not a valid Nostr key.") }
        let rumor = GiftWrap.rumor(kind: 14, pubkey: me, tags: to.map { ["p", $0] }, content: text)
        var d = Dm(rid: rumor.id, conv: conv, from: me, mine: true, at: rumor.createdAt, kind: 14, text: text)
        d.pending = engine.localOnly ? nil : true
        lock.lock(); items[rumor.id] = d; lock.unlock()
        save()
        do {
            try await deliver(rumor, to: to)
        } catch {
            lock.lock(); items[rumor.id] = nil; lock.unlock()
            save()
            throw error
        }
    }

    /// An e-mail through the belfry's bridge. Returns the thread it lands in.
    @discardableResult
    public func sendMail(_ text: String, in conv: String, subject: String? = nil, fromName: String) async throws -> String {
        try engine.guestMode.check()
        onSend?()
        guard let b = bridge else { throw BelfryError.invalid("This belfry does not send e-mail yet.") }
        guard let from = myAddress else { throw BelfryError.invalid("You have no address here yet (name@domain).") }
        let to = MailThreads.address(conv)
        let fresh = MailThreads.isNewMail(conv)
        let before = fresh ? nil : thread(conv).last { $0.kind == 1301 }
        let base = fresh ? ((subject?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)")
            : (MailThreads.baseSubject(before?.subject).isEmpty ? "(no subject)" : MailThreads.baseSubject(before?.subject))
        let subj = fresh || before == nil ? base : "Re: " + base
        let (raw, messageId) = MIME.build(fromName: fromName.isEmpty ? String(from.split(separator: "@").first ?? "") : fromName,
                                          from: from, to: to, subject: subj, text: text,
                                          inReplyTo: before?.messageId, references: before?.references, domain: engine.config.domain)
        let target = fresh ? MailThreads.thread(address: to, subject: subj) : conv
        let emailId = UUID().uuidString.lowercased()
        let rumor = GiftWrap.rumor(kind: 1301, pubkey: me, tags: [["email-id", emailId], ["mail-from", from], ["rcpt-to", to], ["subject", subj]], content: raw)
        var d = Dm(rid: rumor.id, conv: target, from: me, mine: true, at: rumor.createdAt, kind: 1301, text: text)
        d.subject = subj
        d.emailId = emailId
        d.raw = raw
        d.messageId = messageId
        d.references = before.map { [$0.references, $0.messageId].compactMap { $0 }.joined(separator: " ") }
        d.pending = true
        lock.lock()
        items[rumor.id] = d
        reports[emailId] = DeliveryReport(status: "queued", details: "Waiting for the connection…")
        lock.unlock()
        save()
        do {
            try await deliver(rumor, to: [b])
        } catch {
            lock.lock()
            reports[emailId] = DeliveryReport(status: "failed", details: "It could not be prepared. Try again.")
            items[rumor.id]?.pending = false
            items[rumor.id]?.failed = "not sent"
            lock.unlock()
        }
        if engine.localOnly {
            lock.lock()
            reports[emailId] = DeliveryReport(status: "failed", details: "Demo mode sends no e-mail.")
            items[rumor.id]?.pending = false
            lock.unlock()
        }
        save()
        return target
    }

    /// Shared inbox: an answer by e-mail as the channel (mail-from = <channel>@domain), to the
    /// sender of the inbox card CARDID (SPEC 19.6). Returns the e-mail's id (its delivery report).
    @discardableResult
    public func sendAsChannel(channel: String, channelName: String, to: String, subject: String, text: String, inReplyTo: String?, cardId: String, myName: String) async throws -> String {
        try engine.guestMode.check()
        guard let b = bridge else { throw BelfryError.invalid("This belfry does not send e-mail yet.") }
        let from = channel + "@" + engine.config.domain
        let (raw, _) = MIME.build(fromName: myName.isEmpty ? channelName : "\(myName) for \(channelName)", from: from, to: to, subject: subject, text: text,
                                  inReplyTo: inReplyTo, references: inReplyTo, domain: engine.config.domain)
        let emailId = UUID().uuidString.lowercased()
        let rumor = GiftWrap.rumor(kind: 1301, pubkey: me, tags: [["email-id", emailId], ["mail-from", from], ["rcpt-to", to], ["subject", subject], ["e", cardId]], content: raw)
        if engine.localOnly {
            lock.lock(); reports[emailId] = DeliveryReport(status: "failed", details: "Demo mode sends no e-mail."); lock.unlock()
            save()
            return emailId
        }
        lock.lock(); reports[emailId] = DeliveryReport(status: "queued", details: "Sending…"); lock.unlock()
        save()
        do {
            try await deliver(rumor, to: [b], selfCopy: false)
        } catch {
            lock.lock(); reports[emailId] = DeliveryReport(status: "failed", details: "It could not be prepared. Try again."); lock.unlock()
            save()
            throw BelfryError.invalid("The e-mail could not be prepared. Try again.")
        }
        return emailId
    }

    /// Outbox news: a DM is out once no wrap for someone else waits any more.
    public func outboxSent(_ item: OutboxItem) {
        guard let rid = item.dm else { return }
        let left = engine.outboxItems().filter { $0.dm == rid && $0.tags.contains { $0.first == "p" && $0.count > 1 && $0[1] != me } }
        guard left.isEmpty else { return }
        lock.lock()
        items[rid]?.pending = false
        items[rid]?.failed = nil
        let emailId = items[rid]?.kind == 1301 ? items[rid]?.emailId : nil
        if let emailId { reports[emailId] = DeliveryReport(status: "queued", details: "Sent: waiting for the delivery report…") }
        lock.unlock()
        save()
        if emailId != nil, !engine.localOnly {
            for wait in [3.0, 10, 30, 90] {
                DispatchQueue.global().asyncAfter(deadline: .now() + wait) { Task { await self.checkReports() } }
            }
        }
    }

    public func outboxFailed(_ item: OutboxItem) {
        guard let rid = item.dm, item.tags.contains(where: { $0.first == "p" && $0.count > 1 && $0[1] != me }) else { return }
        lock.lock()
        items[rid]?.failed = item.error ?? "The relay refused it."
        if let e = items[rid]?.emailId { reports[e] = DeliveryReport(status: "failed", details: "The relay refused it.") }
        lock.unlock()
        save()
    }

    public func retry(_ d: Dm) {
        for o in engine.outboxItems() where o.dm == d.rid { engine.retry(o.localId) }
        lock.lock()
        items[d.rid]?.failed = nil
        items[d.rid]?.pending = true
        if let e = d.emailId { reports[e] = DeliveryReport(status: "queued", details: "Waiting for the connection…") }
        lock.unlock()
        save()
    }

    /// Delivery reports (kind 7679) for my e-mails that have none yet.
    public func checkReports() async {
        guard let b = bridge, !engine.localOnly else { return }
        lock.lock()
        let open = items.values.filter { $0.mine && $0.emailId != nil && ["queued", nil].contains(reports[$0.emailId!]?.status) }.compactMap(\.emailId)
        lock.unlock()
        guard !open.isEmpty else { return }
        let found = await engine.query(.main, [["kinds": [7679], "authors": [b], "#r": Array(open.suffix(50))]])
        for e in found {
            guard let eph = e.tag("ephemeral-pubkey"), let r = e.tag("r"),
                  let text = try? await engine.signer.nip44Decrypt(peer: eph, payload: e.content),
                  let obj = JSON.parse(text) as? [String: Any], let status = obj["status"] as? String,
                  ["delivered", "failed", "delayed", "queued"].contains(status) else { continue }
            let fixed: String
            switch status {
            case "delivered": fixed = "Delivered."
            case "failed": fixed = "Not delivered: the receiving server refused it."
            case "delayed": fixed = "Delayed: the receiving server will be tried again."
            default: fixed = "Sent: waiting for the delivery report…"
            }
            lock.lock(); reports[r] = DeliveryReport(status: status, details: fixed); lock.unlock()
        }
        save()
    }

    /// Where a new conversation goes: a member (name, nip05, hex key) or an e-mail address.
    public func conv(for input: String, people: [(pubkey: String, name: String, nip05: String?)]) async -> String? {
        let v = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hit = people.first(where: { $0.nip05?.lowercased() == v || $0.name.lowercased() == v }) { return "n:" + hit.pubkey }
        if isHex64(v) { return "n:" + v }
        if let pk = Bech32.pubkey(npub: v) { return "n:" + pk }
        guard let m = Rx("^([^@\\s]+)@([^@\\s]+\\.[^@\\s]+)$").first(v), let name = m[1], let domain = m[2] else { return nil }
        if domain == engine.config.domain, !engine.localOnly, let pk = await Discovery.nip05(name: name, domain: domain) { return "n:" + pk }
        return "m:" + v
    }

    /// Demo mode: an e-mail arrives from SENDER as the belfry would deliver it.
    public func demoMail(bridgeSecret: Data, sender: String, subject: String, text: String, at: Int) async throws {
        let bridgeSigner = try LocalSigner(secret: bridgeSecret)
        bridge = bridgeSigner.pubkey
        let raw = "From: \(sender)\r\nTo: \(myAddress ?? "me@demo")\r\nSubject: \(subject)\r\nMessage-ID: <\(UUID().uuidString)@example.org>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(text)\r\n"
        let rumor = GiftWrap.rumor(kind: 1301, pubkey: bridgeSigner.pubkey, tags: [["email-id", UUID().uuidString], ["mail-from", MIME.address(sender).address], ["p", me], ["subject", subject], ["belfry-auth", "pass"]], content: raw, createdAt: at)
        let w = try await GiftWrap.wrap(rumor, to: me, signer: bridgeSigner)
        engine.add([w], verify: false)
    }

    /// Demo mode: a NIP-17 message from FROM.
    public func demoDM(from: LocalSigner, text: String, at: Int) async throws {
        let rumor = GiftWrap.rumor(kind: 14, pubkey: from.pubkey, tags: [["p", me]], content: text, createdAt: at)
        let w = try await GiftWrap.wrap(rumor, to: me, signer: from)
        engine.add([w], verify: false)
    }
}
