import BelfryCore
import Foundation
import SwiftUI

// The app's state: the session (Keychain), the sync engine and direct messages, and a cached
// Derive over the event log that views read. Every user action goes through here into the outbox.

struct StoredSession: Codable, Equatable {
    var domain: String
    var bunkerURL: String?
    var clientSecret: String // hex, this device's key for the bunker
    var pubkey: String?
    var demo: Bool = false
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case signedOut, ready }

    @Published var phase: Phase = .signedOut
    @Published private(set) var version = 0
    @Published var config: BelfryConfig = .defaults(domain: "belfry.sh")
    @Published var signInError: String?
    @Published var busy = false

    private(set) var engine: SyncEngine?
    private(set) var dms: DirectMessages?
    private var session: StoredSession?
    private var cachedDerive: (Int, Derive)?
    private var cachedGroups: (Int, [BelfryCore.Group])?
    private var cachedProfiles: (Int, [String: Profile])?
    private var seenSentHere = [String: Int]()
    /// `_groups@<domain>`: posts e-mail cards, answers sent as the channel, guest joins.
    @Published var groupsKey: String?
    /// What the register says people are (`POST /whois`), this session.
    @Published var kinds = [String: String]()
    private var whoisAsked = Set<String>()
    private var configCheckedAt = Date.distantPast
    private var bump: DispatchWorkItem?
    let launch = LaunchOptions()

    static let redirectScheme = "sh.belfry.app"
    static let redirectURI = "sh.belfry.app://connect"

    init() {
        if launch.demo {
            startDemo()
        } else if let s = Keychain.load() {
            open(s)
        }
    }

    // ---- reading -----------------------------------------------------------------------------------

    var me: String { engine?.me ?? "" }
    var isDemo: Bool { session?.demo ?? false }

    var derive: Derive {
        if let c = cachedDerive, c.0 == version { return c.1 }
        let pendingIds = Set((engine?.outboxItems() ?? []).filter { $0.signed == nil }.map(\.localId))
        let ctx = WorldContext(me: me, domain: config.domain, communityName: config.name, communityAdmins: Set(config.admins),
                               groupsKey: groupsKey, bridgeKey: dms?.bridge, groupsRelay: config.groupsRelay,
                               agents: config.agents, kinds: kinds, pending: pendingIds)
        let d = Derive(events: engine?.snapshot() ?? [], context: ctx)
        cachedDerive = (version, d)
        return d
    }

    var groups: [BelfryCore.Group] {
        if let c = cachedGroups, c.0 == version { return c.1 }
        let g = derive.groups()
        cachedGroups = (version, g)
        return g
    }

    var profiles: [String: Profile] {
        if let c = cachedProfiles, c.0 == version { return c.1 }
        let p = derive.profiles()
        cachedProfiles = (version, p)
        return p
    }

    func group(_ id: String) -> BelfryCore.Group? { groups.first { $0.id == id } }
    func name(_ pk: String) -> String { derive.displayName(pk, profiles) }
    func realName(_ pk: String) -> String { Derive.realName(pk, profiles) }
    func pending(_ id: String) -> OutboxItem? { engine?.pending(id) }
    var online: Bool { engine?.online ?? true }
    var access: AccessState { engine?.access ?? .unknown }
    var unreadDMs: Int { dms?.unreadTotal ?? 0 }

    private func changed() {
        bump?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.version += 1 }
        bump = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
    }

    // ---- session -----------------------------------------------------------------------------------

    func signIn(domain raw: String, auth: WebAuth) async {
        let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        signInError = nil
        guard Discovery.isDomain(domain) else { signInError = "Type your community's address, like belfry.sh."; return }
        busy = true
        defer { busy = false }
        let cfg = (try? await Discovery.fetch(domain: domain)) ?? .defaults(domain: domain)
        let flow = SignIn(config: cfg, redirectURI: AppModel.redirectURI)
        do {
            let callback = try await auth.start(url: flow.authorizeURL, scheme: AppModel.redirectScheme)
            let code = try flow.code(from: callback)
            let token = try await flow.exchange(code: code)
            guard BunkerURL(token.bunkerURL) != nil else { throw SignIn.Failure.refused }
            let s = StoredSession(domain: domain, bunkerURL: token.bunkerURL, clientSecret: Keys.generateSecret().hex, pubkey: token.pubkey)
            Keychain.save(s)
            config = cfg
            open(s, config: cfg)
        } catch let f as SignIn.Failure {
            signInError = f.message
        } catch WebAuth.Cancelled.cancelled {
            signInError = SignIn.Failure.cancelled.message
        } catch {
            signInError = SignIn.Failure.unknown.message
        }
    }

    private func open(_ s: StoredSession, config cfg: BelfryConfig? = nil) {
        session = s
        let db: Database
        if s.demo {
            db = (try? .memory())!
        } else {
            db = (try? Database(path: AppModel.dbURL(s.domain).path)) ?? (try! .memory())
        }
        config = cfg ?? db.get("config", as: BelfryConfig.self) ?? .defaults(domain: s.domain)
        db.set("config", config)
        let signer: Signer
        if s.demo {
            signer = try! LocalSigner(secretHex: s.clientSecret)
        } else if let b = s.bunkerURL.flatMap(BunkerURL.init), let secret = Data(hex: s.clientSecret),
                  let bs = try? BunkerSigner(bunker: b, clientSecret: secret, pubkey: s.pubkey ?? db.get("pubkey", as: String.self)) {
            signer = bs
        } else {
            signOut()
            return
        }
        let e = SyncEngine(config: config, db: db, signer: signer, localOnly: s.demo, attachmentsDir: AppModel.attachmentsDir)
        let d = DirectMessages(engine: e)
        e.onChange = { [weak self] in DispatchQueue.main.async { self?.changed() } }
        d.onChange = { [weak self] in DispatchQueue.main.async { self?.changed() } }
        e.onNewEvents = { [weak d] list in
            if list.contains(where: { $0.kind == 1059 || $0.kind == 4 }) { Task { await d?.process() } }
        }
        e.onSent = { [weak d] item, _ in d?.outboxSent(item) }
        e.onFailed = { [weak d] item in d?.outboxFailed(item) }
        engine = e
        dms = d
        phase = .ready
        if !s.demo {
            Task {
                if let bs = signer as? BunkerSigner, s.pubkey == nil, let pk = try? await bs.ensurePubkey() { db.set("pubkey", pk) }
                await self.revalidateConfig(force: true)
                if let k = db.get("groups-key", as: String.self) { self.groupsKey = k }
                if let k = await Discovery.nip05(name: "_groups", domain: s.domain) {
                    db.set("groups-key", k)
                    self.groupsKey = k
                }
                self.version += 1
                await self.askWhois()
                await d.loadBridge()
                self.updateAddress()
                await d.process()
            }
        }
        e.start()
        updateAddress()
    }

    /// belfry.json again (ETag, no-cache; SPEC 19.15): at start, after an admin / agent change, and
    /// when a profile or members list opens (at most every 30 s unless FORCE).
    func revalidateConfig(force: Bool = false) async {
        guard let engine, !engine.localOnly else { return }
        if !force && Date().timeIntervalSince(configCheckedAt) < 30 { return }
        configCheckedAt = Date()
        let current = config
        do {
            if let fresh = try await Discovery.revalidate(domain: current.domain, etag: current.etag) {
                engine.db.set("config", fresh)
                config = fresh
                version += 1
            }
        } catch {}
    }

    /// Ask the register who the people brought in by links or as agents are (once per session per
    /// key; KEYS again when a profile or members list opens).
    func askWhois(_ keys: [String]? = nil) async {
        guard let engine, !engine.localOnly else { return }
        let list = (keys ?? derive.guestJoinKeys).filter { keys != nil || !whoisAsked.contains($0) }
        guard !list.isEmpty else { return }
        whoisAsked.formUnion(list)
        if let got = try? await api.whois(list) {
            var k = kinds
            for p in list { k[p] = got[p] }
            kinds = k
            version += 1
        }
    }

    /// The belfry's HTTP API, signed as me.
    var api: BelfryAPI { BelfryAPI(config: config, signer: engine?.signer) }

    func updateAddress() {
        guard let dms else { return }
        if let n5 = profiles[me]?.nip05, n5.contains("@") { dms.myAddress = n5.lowercased() }
        else if isDemo { dms.myAddress = "you@\(config.domain)" }
    }

    func signOut() {
        engine?.stop()
        if let b = engine?.signer as? BunkerSigner { b.disconnect() }
        if let s = session, !s.demo {
            let cfg = config
            Task.detached {
                var req = URLRequest(url: URL(string: cfg.revoke)!, timeoutInterval: 3)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["client_id": SignIn.clientId])
                _ = try? await URLSession.shared.data(for: req)
            }
            try? FileManager.default.removeItem(at: AppModel.dbURL(s.domain))
        }
        try? FileManager.default.removeItem(at: AppModel.attachmentsDir)
        Keychain.clear()
        engine = nil
        dms = nil
        session = nil
        cachedDerive = nil
        groupsKey = nil
        kinds = [:]
        whoisAsked = []
        cachedGroups = nil
        cachedProfiles = nil
        phase = .signedOut
        version += 1
    }

    static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func dbURL(_ domain: String) -> URL { supportDir.appendingPathComponent("belfry-\(domain).sqlite") }

    static var attachmentsDir: URL {
        let u = supportDir.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // ---- demo --------------------------------------------------------------------------------------

    func startDemo() {
        let s = StoredSession(domain: "demo.belfry.sh", bunkerURL: nil, clientSecret: Demo.meSecret.hex, pubkey: nil, demo: true)
        var cfg = BelfryConfig.defaults(domain: "demo.belfry.sh")
        cfg.name = "Riverside Commons"
        cfg.admins = []
        open(s, config: cfg)
        groupsKey = Demo.signer("groups").pubkey
        if let e = engine, let d = dms {
            Task { await Demo.seed(engine: e, dms: d) ; self.updateAddress() }
        }
    }

    // ---- actions -----------------------------------------------------------------------------------

    func post(_ text: String, in group: String, attachments: [Attachment] = [], announce: Bool = false, topic: String? = nil) {
        let tags = derive.eventTagsFor(text, mainRelay: config.mainRelay)
        engine?.enqueue(Actions.postMessage(group, text: text, topic: topic, announce: announce, eventTags: tags), attachments: attachments)
    }

    /// Edit my own message or thread reply (kind 1010; SPEC 19.1).
    func edit(_ m: Message, in group: String, text: String) {
        guard derive.canEdit(m) else { return }
        engine?.enqueue(Actions.editMessage(group, m, text: text))
    }

    func pin(_ m: Message, in group: String, _ on: Bool) {
        engine?.enqueue(Actions.pinMessage(group, messageId: m.id, pin: on))
    }

    /// "Turn into a to-do" (SPEC 19.11).
    func makeTodo(_ m: Message, in group: String) {
        guard derive.canMakeTodo(group, m) else { return }
        engine?.enqueue(Actions.addTask(group, title: derive.todoTitle(m), from: m.id))
    }

    func addTodo(_ title: String, in group: String) {
        let t = title.jsTrim()
        guard !t.isEmpty else { return }
        engine?.enqueue(Actions.addTask(group, title: t))
    }

    /// ACTION: claim | unclaim | done | undone | delete
    func todo(_ t: TodoTask, in group: String, _ action: String) {
        engine?.enqueue(Actions.taskAction(group, taskId: t.id, action: action))
    }

    func commentTodo(_ t: TodoTask, in group: String, text: String) {
        engine?.enqueue(Actions.commentTask(group, taskId: t.id, text: text))
    }

    func createPod(name: String, about: String, parent: String, closed: Bool, prompt: String) -> String {
        let id = Actions.newPodId(name)
        for d in Actions.createPod(id: id, name: name, about: about, parent: parent, access: PodAccess(closed: closed, prompt: prompt)) { engine?.enqueue(d) }
        return id
    }

    func editPod(_ id: String, name: String, about: String, closed: Bool, prompt: String) {
        engine?.enqueue(Actions.editPod(id, name: name, about: about, access: PodAccess(closed: closed, prompt: prompt)))
    }

    func createProposal(_ n: NewProposal, parent: String) -> String {
        let (id, drafts) = Actions.createProposal(n, parent: parent, me: me, groupsRelay: config.groupsRelay, mainRelay: config.mainRelay, now: .now)
        for d in drafts { engine?.enqueue(d) }
        return id
    }

    func reviseProposal(_ p: Proposal, title: String, summary: String, text: String, note: String) {
        for d in Actions.reviseProposal(p, title: title, summary: summary, text: text, note: note, groupsRelay: config.groupsRelay, mainRelay: config.mainRelay, now: .now) { engine?.enqueue(d) }
    }

    func vote(_ p: Proposal, _ option: String) {
        if let d = Actions.vote(p, option: option) { engine?.enqueue(d) }
    }

    func setStatus(_ p: Proposal, _ status: ProposalStatus) {
        for d in Actions.setProposalStatus(p, status) { engine?.enqueue(d) }
    }

    func apply(_ id: String, answer: String) { engine?.enqueue(Actions.join(id, answer: answer)) }
    func leave(_ id: String) { engine?.enqueue(Actions.leave(id)) }
    func admit(_ id: String, _ pk: String) { engine?.enqueue(Actions.admit(id, pubkey: pk)) }
    func declineApplicant(_ id: String, _ pk: String) { engine?.enqueue(Actions.decline(id, pubkey: pk)) }

    func pinTopic(_ topic: String, in group: String, _ on: Bool) {
        engine?.enqueue(Actions.pinTopic(group, pinned: derive.pinnedTopics(group), topic: topic, pin: on))
    }

    func setMemberLabels(_ pk: String, in group: String, labels: [String]) {
        engine?.enqueue(Actions.setMemberLabels(group, pubkey: pk, labels: labels))
    }

    /// Drop a message that could not be sent (its outbox item).
    func discard(_ localId: String) { engine?.cancel(localId) }

    func assignCard(_ card: Message, in group: String, to assignee: String) {
        engine?.enqueue(Actions.assignCard(group, card: card.id, assignee: assignee))
    }

    func setCard(_ card: Message, in group: String, closed: Bool) {
        engine?.enqueue(Actions.setCardStatus(group, card: card.id, closed: closed))
    }

    /// Answer an inbox card by e-mail as the channel (after the 8 s undo). Fixed messages only.
    func replyAsChannel(_ card: Message, in group: String, to: String, subject: String, text: String) async -> String? {
        guard let dms else { return "Not signed in." }
        let base = MailThreads.baseSubject(subject)
        let subj = base.isEmpty ? "(no subject)" : (subject.lowercased().hasPrefix("re:") ? subject : "Re: " + subject)
        do {
            try await dms.sendAsChannel(channel: group, channelName: self.group(group)?.name ?? group, to: to, subject: subj, text: text,
                                        inReplyTo: card.ev.tag("message-id"), cardId: card.id, myName: realName(me))
            return nil
        } catch let e as BelfryError {
            return e.errorDescription ?? "The e-mail could not be prepared. Try again."
        } catch {
            return "The e-mail could not be prepared. Try again."
        }
    }

    /// "Kofi", or the start of their key (never "You").
    func realNameOrKey(_ pk: String) -> String {
        let n = realName(pk)
        return n.isEmpty ? Derive.shortKey(pk) : n
    }

    /// Someone to write to (a NIP-17 conversation), from a message menu or a profile.
    @Published var messageAuthor: String?
    /// The last "Make this the website" answer (a fixed message), shown once.
    @Published var website: String?

    func publishWebsite(ref: String, message: String) async -> String {
        guard let engine, !engine.localOnly else { return "Demo mode publishes nothing." }
        do {
            try await api.publishWebsite(ref: ref, messageId: message)
            return "Published: it is the website now."
        } catch let e as ApiError {
            return e.message
        } catch {
            return BelfryAPI.generic
        }
    }

    /// Bring someone who is here already into a channel (SPEC 19.15): a guest becomes its guest
    /// (`/channel-guests`); a member gets a direct message with the link (in a closed group I
    /// administer they are let in first). Returns a fixed line saying what happened.
    func inviteHere(_ pk: String, to groupId: String) async -> String {
        let d = derive
        let g = d.group(groupId)
        if d.isGuest(pk) {
            if engine?.localOnly == true { return "Added as a guest (demo)." }
            do {
                let r = try await api.addChannelGuest(channel: groupId, pubkey: pk)
                if !r.member { return r.already ? "They're in already." : "Added as a guest." }
            } catch let e as ApiError {
                return e.message
            } catch {
                return BelfryAPI.generic
            }
        }
        var asked = false
        if let g, g.closed {
            if d.canAdmin(g) { engine?.enqueue(Actions.admit(groupId, pubkey: pk)) } else { asked = true }
        }
        guard let dms else { return "Not signed in." }
        do {
            try await dms.send(d.inviteText(groupId, asked: asked), in: MailThreads.nostrConv(author: pk, pTags: [], me: me))
            return asked ? "Sent: they can ask to join." : "Invited: they got a message with the link."
        } catch {
            return "The invite could not be sent. Try again."
        }
    }

    /// RSVP: a member's on the community relay, a guest's on the groups relay (SPEC 19.18).
    func rsvp(_ e: CalEvent, _ r: Rsvp) {
        let d = derive
        let ticket = e.isNew ? d.eventPeople(e).holders[me] : nil
        engine?.enqueue(EventActions.rsvp(e, r, me: me, ticketD: ticket, onGroups: e.remote || d.amGuest, eventPending: d.isPending(e.ev.id)))
    }

    /// Opens a channel's events list (All events of that channel), from the pull-down.
    @Published var showEvents: String?

    /// An event to show (its coordinate or link), from a card anywhere.
    @Published var openEvent: String?
    /// Screenshots: open the delete confirmation / the ＋ menu once.
    @Published var launchDelete = false
    @Published var launchAdd = false

    // ---- pins I hid on this phone ("Got it, hide"; at most 200; SPEC 19.10) ---------------------

    @Published private(set) var hiddenPins: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "belfry-pins-hidden") ?? [])

    func hidePin(_ id: String) {
        var list = UserDefaults.standard.stringArray(forKey: "belfry-pins-hidden") ?? []
        list.removeAll { $0 == id }
        list.append(id)
        list = Array(list.suffix(200))
        UserDefaults.standard.set(list, forKey: "belfry-pins-hidden")
        hiddenPins = Set(list)
    }

    func reply(_ text: String, in group: String, to root: Message) {
        engine?.enqueue(Actions.postThreadReply(group, rootId: root.ev.id, rootPubkey: root.ev.pubkey, rootKind: root.ev.kind, text: text))
    }

    func toggleReaction(_ emoji: String, on m: Message, in group: String) {
        guard let engine else { return }
        let mine = derive.reactions(group)[m.id]?.first { $0.emoji == emoji }?.mine
        if let mine {
            if engine.pending(mine) != nil { engine.cancel(mine); return }
            engine.enqueue(Actions.unreact(group, reactionId: mine))
        } else {
            EmojiUsage.used(emoji)
            engine.enqueue(Actions.react(group, messageId: m.ev.id, author: m.ev.pubkey, emoji: emoji))
        }
    }

    func delete(_ m: Message, in group: String) {
        if let p = engine?.pending(m.id) { engine?.cancel(p.localId); return }
        engine?.enqueue(Actions.deleteMessage(group, id: m.id))
    }

    func retry(_ localId: String) { engine?.retry(localId) }

    func createChannel(name: String, about: String) -> String {
        let id = Actions.newChannelId(name)
        for d in Actions.createChannel(id: id, name: name, about: about) { engine?.enqueue(d) }
        return id
    }

    func editChannel(_ id: String, name: String, about: String, inbox: Bool?) {
        engine?.enqueue(Actions.editChannel(id, name: name, about: about))
        if let inbox, inbox != derive.isInbox(group(id)) { engine?.enqueue(Actions.setInbox(id, on: inbox)) }
    }

    func join(_ id: String) { engine?.enqueue(Actions.join(id)) }

    /// Opening a channel tells it, at most every 6 hours.
    func markSeen(_ id: String) {
        guard let g = group(id), !(g.type == .pod && g.closed && !g.members.contains(me)) else { return }
        let now = Int.now
        guard Actions.shouldMarkSeen(now: now, mySeen: derive.mySeen(id), lastSentHere: seenSentHere[id] ?? 0) else { return }
        seenSentHere[id] = now
        engine?.enqueue(Actions.seen(id))
    }

    func refresh() async {
        await engine?.refresh()
        await dms?.process()
    }

    func wake() { engine?.wake() }

    /// A guest link for a channel (SPEC 13). Errors are fixed messages chosen by the server's code.
    func guestLink(_ channel: String) async -> Result<String, GuestLinkError> {
        guard let engine else { return .failure(.network) }
        if engine.localOnly { return .success("https://\(config.domain)/invite/demo-guest-link") }
        do {
            let (data, status) = try await engine.signedRequest(config.channelInvites, method: "POST", json: ["channel": channel])
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if status == 200, let u = obj["url"] as? String, u.hasPrefix("https://") { return .success(u) }
            return .failure(GuestLinkError(code: obj["error"] as? String))
        } catch {
            return .failure(.network)
        }
    }

    // ---- attachments -------------------------------------------------------------------------------

    func saveAttachment(_ data: Data, name: String, mime: String, width: Int?, height: Int?) -> Attachment? {
        let file = Crypto.random(8).hex + "-" + name.replacingOccurrences(of: "/", with: "_")
        do { try data.write(to: AppModel.attachmentsDir.appendingPathComponent(file)) } catch { return nil }
        return Attachment(file: file, name: name, mime: mime, size: data.count, width: width, height: height)
    }
}

enum GuestLinkError: Error, Equatable {
    case network, guest, notAllowed, noChannel, unsupported, refused, unknown

    init(code: String?) {
        switch code {
        case "guest": self = .guest
        case "not_allowed": self = .notAllowed
        case "no_channel": self = .noChannel
        case "unsupported": self = .unsupported
        case "refused": self = .refused
        default: self = .unknown
        }
    }

    var message: String {
        switch self {
        case .network: return "No connection to the belfry."
        case .guest: return "Guests can't invite guests."
        case .notAllowed: return "You can't invite guests here."
        case .noChannel: return "This channel isn't on the belfry yet. Try again in a moment."
        case .unsupported: return "This belfry doesn't offer guest links yet."
        case .refused: return "The belfry refused to make a guest link."
        case .unknown: return "The guest link could not be made."
        }
    }
}

/// The emojis you use most come first.
enum EmojiUsage {
    static let key = "belfry-emoji-usage"
    static func used(_ e: String) {
        var u = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        u[e, default: 0] += 1
        UserDefaults.standard.set(u, forKey: key)
    }
    static func top(_ n: Int = 6) -> [String] {
        let u = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        var out = [String]()
        for e in u.sorted(by: { $0.value > $1.value }).map(\.key) + Actions.defaultEmojis where !out.contains(e) { out.append(e) }
        return Array(out.prefix(n))
    }
}

/// Launch arguments for tests and screenshots: -demo, -screen <name>.
struct LaunchOptions {
    let demo: Bool
    let screen: String?

    init() {
        let args = ProcessInfo.processInfo.arguments
        demo = args.contains("-demo")
        if let i = args.firstIndex(of: "-screen"), i + 1 < args.count { screen = args[i + 1] } else { screen = nil }
    }
}
