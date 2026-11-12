import Foundation

// Derived views over the event log (SPEC sections 6-13 and 19): pure functions of the events,
// the queued outbox items and who I am, ported from the web chat's src/core/model.ts (and the
// Android app's World.kt, its second reading) and checked against vectors/.
//
// A Derive is an immutable snapshot: build a new one when the log or the outbox changes. Every
// view is computed on first use and cached (not thread-safe: use one from one actor).

public let generalId = "general"
public let activeDays = 30

/// What a Derive needs to know besides the events.
public struct WorldContext: Hashable, Sendable {
    public var me: String
    public var domain: String
    public var communityName: String
    /// belfry.json `admins` ∪ `access.admins` (64-hex only).
    public var communityAdmins: Set<String>
    /// `_groups@domain`: posts e-mail cards, answers sent as a channel, guest joins.
    public var groupsKey: String?
    /// `_smtp@domain`: the mail bridge.
    public var bridgeKey: String?
    /// The groups relay's address: the relay hint in a channel reference.
    public var groupsRelay: String
    /// belfry.json `agents`: a member's own agent → that member.
    public var agents: [String: String]
    /// What the register says each key is (`POST /whois`): "member", "agent" or "guest".
    public var kinds: [String: String]
    /// Ids of events still in my outbox (queued or failed).
    public var pending: Set<String>
    /// For day separators and all-day calendar events.
    public var timeZone: TimeZone

    public init(me: String, domain: String = "", communityName: String = "", communityAdmins: Set<String> = [],
                groupsKey: String? = nil, bridgeKey: String? = nil, groupsRelay: String = "",
                agents: [String: String] = [:], kinds: [String: String] = [:], pending: Set<String> = [],
                timeZone: TimeZone = .current) {
        self.me = me
        self.domain = domain
        self.communityName = communityName
        self.communityAdmins = communityAdmins
        self.groupsKey = groupsKey
        self.bridgeKey = bridgeKey
        self.groupsRelay = groupsRelay
        self.agents = agents
        self.kinds = kinds
        self.pending = pending
        self.timeZone = timeZone
    }
}

public struct Profile: Hashable, Sendable {
    public var name: String?
    public var picture: String?
    public var nip05: String?
    public var about: String = ""
    public var at: Int = 0
    public init(name: String? = nil, picture: String? = nil, nip05: String? = nil, about: String = "", at: Int = 0) {
        self.name = name
        self.picture = picture
        self.nip05 = nip05
        self.about = about
        self.at = at
    }
}

public enum ChannelType: String, Sendable { case channel, event, pod, proposal }

public struct Application: Hashable, Sendable {
    public let pubkey: String
    public let answer: String
    public let at: Int
    public var id: String = ""
}

public struct Group: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var about: String
    public var picture: String?
    public var createdAt: Int
    public var lastActivity: Int
    public var members: Set<String> = []
    /// Guest mode (SPEC 19.26): keys that opened a guest link and have not joined. Left out of
    /// `members` (except me), member lists, counts, "active" and mention pickers.
    public var reading: Set<String> = []
    public var admins: Set<String> = []
    public var closed = false
    public var prompt: String?
    public var parent: String?
    public var applications: [Application] = []
    public var pending = false

    public static func typeOf(_ id: String) -> ChannelType {
        if id.hasPrefix("ws-") || id.hasPrefix("ev-") { return .event }
        if id.hasPrefix("pod-") { return .pod }
        if id.hasPrefix("prop-") { return .proposal }
        return .channel
    }

    public var type: ChannelType { Group.typeOf(id) }
    public var isPod: Bool { type == .pod }
    public var isEvent: Bool { type == .event }
    public var isProposal: Bool { type == .proposal }

    public var icon: String {
        switch type {
        case .event: return "📅"
        case .pod: return "⬡"
        case .proposal: return "📝"
        case .channel: return "#"
        }
    }
}

public struct Media: Hashable, Sendable, Codable {
    public let url: String
    public let mime: String
    public let name: String?
    public let w: Int?
    public let h: Int?
    public var isImage: Bool { mime.hasPrefix("image/") }
}

/// A member's e-mail kept whole on the file server (AES-256-GCM; key and nonce base64).
public struct MailOriginal: Hashable, Sendable { public let url: String; public let key: String; public let nonce: String }

/// What kind of post a message is, beyond plain text (SPEC 19.6).
public enum Special: Hashable, Sendable {
    case none
    /// Links a calendar event (`a` tag 31922/31923, the older 📅 post): shown as the event's card.
    case eventCard(coord: String)
    case podCard(podId: String)
    case proposalCard(groupId: String)
    /// A member's e-mail to `<channel>@domain`, posted as their message: "via e-mail".
    case memberMail(subject: String, original: MailOriginal?)
    /// Shared inbox: an e-mail from anyone, posted by the groups key as a card.
    case inboxCard(from: String, name: String, subject: String, messageId: String?, verified: Bool, original: MailOriginal?)
    /// An answer that went out by e-mail as the channel (posted by the groups key).
    case sentAsChannel(to: String, subject: String, by: String)
}

/// An event a message shows as a card under its text: a known coordinate, or a link (d or slug).
public struct EventRef: Hashable, Sendable {
    public var coord: String?
    public var link: String?
    public init(coord: String? = nil, link: String? = nil) { self.coord = coord; self.link = link }
}

public struct Message: Identifiable, Hashable, Sendable {
    /// The original event (its id is what reactions, threads and links hang off).
    public let ev: NostrEvent
    /// The text as it reads now (after the author's latest edit), media URLs cut out.
    public let text: String
    public let media: [Media]
    public let topics: [String]
    /// When its author last edited it (kind 1010), else nil.
    public var edited: Int?
    public var special: Special = .none
    /// Uploaded through a drop box link: named "Drop box" when the key has no profile.
    public var viaDropBox = false
    /// The events it shows as cards under its text (at most three).
    public var eventRefs: [EventRef] = []

    public init(ev: NostrEvent, text: String, media: [Media], topics: [String], edited: Int? = nil, special: Special = .none,
                viaDropBox: Bool = false, eventRefs: [EventRef] = []) {
        self.ev = ev
        self.text = text
        self.media = media
        self.topics = topics
        self.edited = edited
        self.special = special
        self.viaDropBox = viaDropBox
        self.eventRefs = eventRefs
    }

    public var id: String { ev.id }
    public var pubkey: String { ev.pubkey }
    public var at: Int { ev.createdAt }

    /// Text to show: for e-mails, without the leading `**<subject>**` line the bridge adds.
    public var body: String {
        var subject = ""
        switch special {
        case .memberMail(let s, _): subject = s
        case .inboxCard(_, _, let s, _, _, _): subject = s
        default: break
        }
        let head = "**\(subject)**"
        if !subject.isEmpty, text.hasPrefix(head) { return String(text.dropFirst(head.count)).jsTrimStart() }
        return text
    }

    /// "an event" / "a pod" / "a proposal" for the line "Created …" above a card; nil otherwise.
    public var created: String? {
        switch special {
        case .eventCard: return "an event"
        case .podCard: return "a pod"
        case .proposalCard: return "a proposal"
        default: return nil
        }
    }

    public var isCard: Bool { created != nil }
    public var isMail: Bool {
        switch special {
        case .memberMail, .inboxCard, .sentAsChannel: return true
        default: return false
        }
    }
}

public struct Reaction: Hashable, Sendable {
    public let emoji: String
    public var who: [String] // in first-seen order
    public var mine: String? // my reaction event id
}

public struct ThreadInfo: Hashable, Sendable {
    public var count: Int
    public var last: Int
    public var who: [String]
}

/// Who joined a channel as its guest (kind 9000 from the belfry with `invited-by`).
public struct GuestJoin: Hashable, Sendable, Identifiable {
    public let id: String
    public let pubkey: String
    public let by: String?
    public let at: Int
    public var agent = false
    /// No e-mail on the account yet ("guest · not saved").
    public var unsaved = false
    /// A member since (an admin made them one): no longer called a guest.
    public var member = false

    /// The chip next to their name: "agent", "guest · not saved", "guest"; nil once a member.
    public var chip: String? { member ? nil : agent ? "agent" : unsaved ? "guest · not saved" : "guest" }
}

public enum FeedItem: Hashable, Sendable, Identifiable {
    case message(Message)
    case join(GuestJoin)
    /// An older thread back in the feed at its latest reply.
    case activity(root: Message, last: Message)

    public var at: Int {
        switch self {
        case .message(let m): return m.ev.createdAt
        case .join(let j): return j.at
        case .activity(_, let last): return last.ev.createdAt
        }
    }

    public var id: String {
        switch self {
        case .message(let m): return m.id
        case .join(let j): return "join:" + j.id
        case .activity(let root, _): return "act:" + root.id
        }
    }

    public var isMessage: Bool { if case .message = self { return true } else { return false } }
}

/// A feed item with what the list needs to lay it out (SPEC 19.7).
public struct FeedRow: Hashable, Sendable, Identifiable {
    public let item: FeedItem
    /// A day separator goes before it.
    public let newDay: Bool
    /// For a message: starts a block (avatar + name + time).
    public let first: Bool
    public var announcement = false
    public var id: String { item.id }
}

public struct ActiveMember: Hashable, Sendable { public let pubkey: String; public let at: Int }

public struct DropLink: Hashable, Sendable, Identifiable {
    public let token: String
    public let groupId: String
    public let expires: Int
    public let login: Bool
    public let author: String
    public let ev: NostrEvent
    public var id: String { token }
}

public enum CardStatus: String, Sendable {
    case open, waiting, closed
    public var label: String { self == .open ? "Open" : self == .waiting ? "Answered" : "Closed" }
}

public struct CardState: Hashable, Sendable {
    public var status: CardStatus = .open
    public var assignee: String?
    public var answered = 0
    public init(status: CardStatus = .open, assignee: String? = nil, answered: Int = 0) {
        self.status = status
        self.assignee = assignee
        self.answered = answered
    }
}

public struct TaskComment: Hashable, Sendable { public let author: String; public let text: String; public let at: Int }

public struct TodoTask: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let author: String
    public var assignee: String?
    public var done = false
    public let pending: Bool
    public var comments: [TaskComment] = []
    /// The message it was made from ("Turn into a to-do"): its `q` tag.
    public let source: String?
}

public struct MemberRow: Hashable, Sendable, Identifiable {
    public let pubkey: String
    public let name: String
    public let place: Place?
    public let guest: GuestJoin?
    public let labels: [String]
    public let isAdmin: Bool
    public var id: String { pubkey }
}

public struct SearchHit: Hashable, Sendable { public let m: Message; public let groupId: String }

public final class Derive {
    public let events: [NostrEvent]
    public let ctx: WorldContext
    public var me: String { ctx.me }
    public var communityAdmins: Set<String> { ctx.communityAdmins }

    public init(events: [NostrEvent], context: WorldContext) {
        self.events = events
        self.ctx = context
    }

    public convenience init(events: [NostrEvent], me: String, communityAdmins: Set<String> = []) {
        self.init(events: events, context: WorldContext(me: me, communityAdmins: communityAdmins))
    }

    public static let editKind = 1010
    public static let inboxNS = "belfry/inbox"
    public static let proposalNS = "belfry/proposal-status"
    public static let guestNS = "belfry/guest"
    public static let pinNS = "belfry/pin"
    public static let profileD = "belfry:profile"
    /// Member labels keep the web chat's namespace so both clients read each other's.
    public static let labelNS = "osv/member-label"

    public static func byTime(_ a: NostrEvent, _ b: NostrEvent) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
    }

    public func isPending(_ id: String) -> Bool { ctx.pending.contains(id) }

    /// Every calendar event, by start time (Events.swift).
    public private(set) lazy var calendar: [CalEvent] = computeCalendar()
    /// Every proposal (Proposals.swift).
    public private(set) lazy var proposals: [Proposal] = computeProposals()

    // ---- indexes -------------------------------------------------------------------------------

    public private(set) lazy var sortedEvents: [NostrEvent] = events.sorted(by: Derive.byTime)

    private lazy var byH: [String: [NostrEvent]] = {
        var out = [String: [NostrEvent]]()
        for e in events { if let h = e.tag("h") { out[h, default: []].append(e) } }
        return out
    }()

    private lazy var byKind: [Int: [NostrEvent]] = Dictionary(grouping: events, by: \.kind)
    private var sortedByH = [String: [NostrEvent]]()
    private lazy var authors: [String: String] = {
        var out = [String: String]()
        for e in events { out[e.id] = e.pubkey }
        return out
    }()

    /// Events carrying this `h`, in arrival order.
    func inGroup(_ id: String) -> [NostrEvent] { byH[id] ?? [] }
    func inGroupSorted(_ id: String) -> [NostrEvent] {
        if let s = sortedByH[id] { return s }
        let s = inGroup(id).sorted(by: Derive.byTime)
        sortedByH[id] = s
        return s
    }
    func ofKind(_ k: Int) -> [NostrEvent] { byKind[k] ?? [] }

    // ---- deletion ----------------------------------------------------------------------------

    private lazy var deletedSet: Set<String> = {
        var out = Set<String>()
        for e in ofKind(9005) { for t in e.tags where t.first == "e" && t.count > 1 && !t[1].isEmpty { out.insert(t[1]) } }
        for e in ofKind(5) {
            for t in e.tags where t.count > 1 {
                if t[0] == "e", authors[t[1]] == e.pubkey { out.insert(t[1]) }
                if t[0] == "a" {
                    let parts = t[1].split(separator: ":", omittingEmptySubsequences: false)
                    if parts.count > 1, String(parts[1]) == e.pubkey { out.insert(t[1]) }
                }
            }
        }
        return out
    }()

    /// Deleted event ids and addresses: kind 5 by the same author, kind 9005 by a moderator.
    public func deleted() -> Set<String> { deletedSet }

    // ---- profiles ------------------------------------------------------------------------------

    private lazy var profileMap: [String: Profile] = {
        var out = [String: Profile]()
        var guests = [(String, String)]()
        for e in events {
            if e.kind == 9000, let name = e.tag("name"), !name.isEmpty, let p = e.tag("p"), !p.isEmpty { guests.append((p, name.sliceUnits(100))) }
            guard e.kind == 0 else { continue }
            if let prev = out[e.pubkey], prev.at >= e.createdAt { continue }
            guard let obj = JSON.parse(e.content) as? [String: Any] else { continue }
            func str(_ k: String) -> String? { obj[k] as? String }
            let dn = str("display_name").flatMap { $0.isEmpty ? nil : $0 }
            out[e.pubkey] = Profile(name: dn ?? str("name"), picture: str("picture"), nip05: str("nip05"), about: str("about") ?? "", at: e.createdAt)
        }
        for (pk, name) in guests where (out[pk]?.name ?? "").isEmpty {
            var p = out[pk] ?? Profile()
            p.name = name
            out[pk] = p
        }
        return out
    }()

    public func profiles() -> [String: Profile] { profileMap }

    /// The name others know someone by (never "You").
    public static func realName(_ pubkey: String, _ ps: [String: Profile]) -> String {
        let p = ps[pubkey]
        if let n = p?.name, !n.isEmpty { return n }
        if let n5 = p?.nip05, let local = n5.split(separator: "@", omittingEmptySubsequences: false).first, !local.isEmpty { return String(local) }
        return ""
    }

    public func realName(_ pubkey: String) -> String { Derive.realName(pubkey, profileMap) }

    public static func shortKey(_ pubkey: String) -> String { String((Bech32.npub(pubkey) ?? pubkey).prefix(12)) + "…" }

    public func displayName(_ pubkey: String, _ ps: [String: Profile]) -> String {
        if pubkey == me { return "You" }
        let r = Derive.realName(pubkey, ps)
        return r.isEmpty ? Derive.shortKey(pubkey) : r
    }

    public func displayName(_ pubkey: String) -> String { displayName(pubkey, profileMap) }

    /// The name over a message: "Drop box" for an upload through a drop link by a key without a profile.
    public func nameOver(_ m: Message) -> String {
        if m.viaDropBox, (profileMap[m.pubkey]?.name ?? "").isEmpty { return "Drop box" }
        return displayName(m.pubkey)
    }

    public func aboutOf(_ pubkey: String) -> String { profileMap[pubkey]?.about ?? "" }

    /// My address here (`<username>@<domain>`), from my profile's nip05.
    public var myAddress: String? {
        guard let n = profileMap[me]?.nip05?.lowercased(), n.contains("@") else { return nil }
        return n
    }

    /// My latest kind 0 content (to keep its other fields when saving), or an empty object.
    public lazy var myProfileJSON: [String: Any] = {
        let mine = ofKind(0).filter { $0.pubkey == me }.max { $0.createdAt < $1.createdAt }
        return mine.flatMap { JSON.parse($0.content) as? [String: Any] } ?? [:]
    }()

    /// People who can be mentioned or messaged: (pubkey, name) of everyone with a name, me left out.
    public lazy var people: [(pubkey: String, name: String)] = profileMap
        .filter { $0.key != me && !($0.value.name ?? "").isEmpty && !onlyReading.contains($0.key) }
        .map { (pubkey: $0.key, name: $0.value.name!) }
        .sorted { $0.name.lowercased() != $1.name.lowercased() ? $0.name.lowercased() < $1.name.lowercased() : $0.pubkey < $1.pubkey }

    // ---- groups --------------------------------------------------------------------------------

    private lazy var groupList: [Group] = computeGroups()
    private lazy var groupById: [String: Group] = Dictionary(groupList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// `general` first, then by latest activity.
    public func groups() -> [Group] { groupList }
    public func group(_ id: String) -> Group? { groupById[id] }

    private func computeGroups() -> [Group] {
        var map = [String: Group]()
        var order = [String]()
        var metaAt = [String: [String: Int]]()
        var applied = [String: NostrEvent]() // group + pubkey
        var appliedOrder = [String]()
        var decided = [String: Int]()
        var gone = Set<String>()
        for e in sortedEvents {
            let gid = (39000...39003).contains(e.kind) ? e.tag("d") : e.tag("h")
            guard let id = gid, !id.isEmpty else { continue }
            if map[id] == nil {
                map[id] = Group(id: id, name: id, about: "", createdAt: e.createdAt, lastActivity: e.createdAt)
                order.append(id)
            }
            var g = map[id]!
            var m = metaAt[id] ?? [:]
            if e.kind == 9008 { gone.insert(id) }
            if e.kind == 9007 {
                g.createdAt = min(g.createdAt, e.createdAt)
                if isPending(e.id) { g.pending = true }
            }
            if e.kind == 9007 || e.kind == 9002 || e.kind == 39000 {
                for k in ["name", "about", "picture"] {
                    guard let v = e.tag(k), (m[k] ?? 0) <= e.createdAt else { continue }
                    switch k {
                    case "name": g.name = v
                    case "about": g.about = v
                    default: g.picture = v
                    }
                    m[k] = e.createdAt
                }
                let access: Bool? = e.hasTag("closed") ? true : e.hasTag("open") ? false : nil
                if let a = access, (m["closed"] ?? 0) <= e.createdAt { g.closed = a; m["closed"] = e.createdAt }
                if let p = e.tag("prompt"), (m["prompt"] ?? 0) <= e.createdAt { g.prompt = p; m["prompt"] = e.createdAt }
            }
            if e.kind == 9007 { g.admins.insert(e.pubkey) }
            if e.kind == 39001 { for t in e.tags where t.first == "p" && t.count > 1 { g.admins.insert(t[1]) } }
            if e.kind == 39002 { g.members = Set(e.tags.filter { $0.first == "p" && $0.count > 1 }.map { $0[1] }) }
            if e.kind == 9000 || e.kind == 9001, let p = e.tag("p"), !p.isEmpty {
                if e.kind == 9000 { g.members.insert(p) } else { g.members.remove(p) }
                decided[id + p] = e.createdAt
                // guest mode: a 9000 tagged `reading` is someone who opened a guest link; a later
                // 9000 without it (they joined), a `saved` / `member` label or a 9001 ends that
                if e.kind == 9000 && e.tag("reading") == "1" { g.reading.insert(p) } else { g.reading.remove(p) }
                // a co-host (events): put in with the admin role; the relay's 39001 says the same
                if e.kind == 9000, e.tags.contains(where: { $0.count >= 3 && $0[0] == "p" && $0[1] == p && $0[2] == "admin" }) { g.admins.insert(p) }
            }
            if e.kind == 1985, e.tag("L") == Derive.guestNS, let p = e.tag("p"), !p.isEmpty,
               e.tags.contains(where: { $0.count >= 2 && $0[0] == "l" && ($0[1] == "saved" || $0[1] == "member") }) {
                g.reading.remove(p)
            }
            if e.kind == 9 {
                g.lastActivity = max(g.lastActivity, e.createdAt)
                g.members.insert(e.pubkey)
            }
            if e.kind == 9021 {
                // an event's application or waitlist place is not a join
                if !g.closed && !e.hasTag("waitlist") && !e.hasTag("ticket") {
                    g.members.insert(e.pubkey)
                } else {
                    let k = id + e.pubkey
                    if applied[k] == nil { appliedOrder.append(k) }
                    applied[k] = e
                }
            }
            if e.kind == 9022 {
                g.members.remove(e.pubkey)
                applied[id + e.pubkey] = nil
            }
            map[id] = g
            metaAt[id] = m
        }
        // a pod or proposal lives where it was announced: the first post carrying its tag
        for e in sortedEvents where e.kind == 9 {
            guard let sub = Derive.podOf(e) ?? Derive.proposalOf(e), let h = e.tag("h"), !h.isEmpty, h != sub, var g = map[sub], g.parent == nil else { continue }
            g.parent = h
            map[sub] = g
        }
        for id in order where (map[id]!.isPod || map[id]!.isProposal) && map[id]!.parent == nil { map[id]!.parent = generalId }
        // reading guests are in no member list or count until they join (the relay's 39002 has them)
        for id in order {
            guard var g = map[id], !g.reading.isEmpty else { continue }
            g.members.subtract(g.reading.subtracting([me]))
            map[id] = g
        }
        for k in appliedOrder {
            guard let e = applied[k] else { continue }
            let gid = String(k.dropLast(e.pubkey.count))
            guard var g = map[gid], !g.members.contains(e.pubkey), (decided[k] ?? 0) < e.createdAt else { continue }
            g.applications.append(Application(pubkey: e.pubkey, answer: e.content, at: e.createdAt, id: e.id))
            map[gid] = g
        }
        return order.compactMap { map[$0] }.filter { !gone.contains($0.id) }.enumerated().sorted { x, y in
            let a = x.element, b = y.element
            if a.id == generalId || b.id == generalId { return a.id == generalId && b.id != generalId }
            return a.lastActivity != b.lastActivity ? a.lastActivity > b.lastActivity : x.offset < y.offset
        }.map(\.element)
    }

    /// Who signed each channel's metadata (kind 39000, the relay's key): the author of a channel reference.
    public lazy var metaAuthors: [String: String] = {
        var out = [String: String]()
        for e in ofKind(39000) { if let d = e.tag("d"), !d.isEmpty { out[d] = e.pubkey } }
        return out
    }()

    public static func podOf(_ e: NostrEvent) -> String? { e.tag("pod").flatMap { $0.hasPrefix("pod-") ? $0 : nil } }
    public static func proposalOf(_ e: NostrEvent) -> String? { e.tag("proposal").flatMap { $0.hasPrefix("prop-") ? $0 : nil } }
    /// The calendar event a chat post links to (its first `a` tag), if any.
    public static func eventCoordOf(_ e: NostrEvent) -> String? {
        guard let a = e.tag("a") else { return nil }
        let k = a.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return k == "31922" || k == "31923" ? a : nil
    }
    public func podOf(_ e: NostrEvent) -> String? { Derive.podOf(e) }
    public func proposalOf(_ e: NostrEvent) -> String? { Derive.proposalOf(e) }

    /// Sub-groups announced in this channel or pod.
    public func pods(_ parent: String) -> [Group] { groupList.filter { $0.isPod && $0.parent == parent } }

    // ---- admin rights ---------------------------------------------------------------------------

    public var isCommunityAdmin: Bool { communityAdmins.contains(me) }
    /// "Admin of the belfry" on someone's profile.
    public func isBelfryAdmin(_ pubkey: String) -> Bool { communityAdmins.contains(pubkey) }

    public func canAdmin(_ g: Group?) -> Bool {
        guard let g else { return false }
        return g.admins.contains(me) || isCommunityAdmin
    }

    public func canAdmin(_ groupId: String) -> Bool { canAdmin(group(groupId)) }

    // ---- messages -----------------------------------------------------------------------------

    /// The author's latest edit (kind 1010) per message id. Edits by anyone else are ignored (19.1).
    private lazy var edits: [String: NostrEvent] = {
        var out = [String: NostrEvent]()
        for e in ofKind(Derive.editKind) {
            if deletedSet.contains(e.id) { continue }
            guard let id = e.tag("e"), authors[id] == e.pubkey else { continue }
            if let had = out[id], !(had.createdAt < e.createdAt || (had.createdAt == e.createdAt && had.id < e.id)) { continue }
            out[id] = e
        }
        return out
    }()

    static func mediaOf(_ e: NostrEvent) -> [Media] {
        var media = [Media]()
        for t in e.tags where t.first == "imeta" {
            var f = [String: String]()
            for p in t.dropFirst() {
                guard let sp = p.firstIndex(of: " ") else { continue }
                f[String(p[..<sp])] = String(p[p.index(after: sp)...])
            }
            guard let url = f["url"], url.hasPrefix("http:") || url.hasPrefix("https:") || url.hasPrefix("idb:") || url.hasPrefix("file:") else { continue }
            let dim = (f["dim"] ?? "").split(separator: "x").map { Int($0) ?? 0 }
            let w = dim.count > 0 && dim[0] > 0 ? dim[0] : nil
            let h = dim.count > 1 && dim[1] > 0 ? dim[1] : nil
            media.append(Media(url: url, mime: f["m"] ?? "", name: f["alt"], w: w, h: h))
        }
        return media
    }

    static func topicsOf(_ e: NostrEvent) -> [String] {
        var topics = [String]()
        for t in e.tags where t.first == "t" && t.count > 1 && !t[1].isEmpty {
            let n = Topics.norm(t[1])
            if !topics.contains(n) { topics.append(n) }
        }
        return topics
    }

    /// A message as its event says (no edits, no specials): previews, search in DMs.
    public static func parseMedia(_ e: NostrEvent) -> Message {
        let media = mediaOf(e)
        var text = e.content
        for m in media { text = text.components(separatedBy: m.url).joined() }
        return Message(ev: e, text: text.jsTrim(), media: media, topics: topicsOf(e))
    }

    /// A message as its author last edited it, with what kind of post it is.
    public func parse(_ e: NostrEvent) -> Message {
        let x = edits[e.id]
        let src = x ?? e
        let media = Derive.mediaOf(src)
        var text = src.content
        for m in media { text = text.components(separatedBy: m.url).joined() }
        let shown = text.jsTrim()
        let links = EventLinks.linksIn(shown, domain: ctx.domain)
        let legacy = links.isEmpty && shown.hasPrefix("📅") && Derive.eventCoordOf(e) != nil
        var refs = [EventRef]()
        if !legacy {
            var seen = Set<String>()
            for c in EventLinks.coordsOf(e) {
                let parts = c.split(separator: ":", omittingEmptySubsequences: false)
                let d = parts.count > 2 ? parts[2...].joined(separator: ":") : ""
                if !seen.insert(d).inserted { continue }
                refs.append(knownCoord(c) ? EventRef(coord: c) : EventRef(link: d))
            }
            for l in links {
                let d = eventD(forLink: l) ?? l
                if !seen.insert(d).inserted { continue }
                refs.append(EventRef(link: l))
            }
        }
        return Message(ev: e, text: shown, media: media, topics: Derive.topicsOf(src), edited: x?.createdAt,
                       special: specialOf(e, legacy: legacy), viaDropBox: e.hasTag("client", "belfry-drop"), eventRefs: Array(refs.prefix(3)))
    }

    /// Calendar hooks (filled in by the calendar views; plain lookups here).
    func knownCoord(_ c: String) -> Bool { calendarCoords.contains(c) }
    func eventD(forLink l: String) -> String? { calendarLinks[l] }

    private lazy var calendarCoords: Set<String> = Set(calendar.map(\.coord))
    private lazy var calendarLinks: [String: String] = {
        var out = [String: String]()
        for c in calendar { out[c.d] = c.d; if let s = c.slug { out[s] = c.d } }
        return out
    }()

    private func specialOf(_ e: NostrEvent, legacy: Bool) -> Special {
        var mail: Special?
        var mailSubject = ""
        var original: MailOriginal?
        if e.hasTag("client", "belfry-mail") {
            if let o = e.tags.first(where: { $0.count >= 4 && $0[0] == "mail-original" && $0[1].hasPrefix("https://") && !$0[2].isEmpty && !$0[3].isEmpty }) {
                original = MailOriginal(url: o[1], key: o[2], nonce: o[3])
            }
            mailSubject = e.tag("subject") ?? ""
            mail = .memberMail(subject: mailSubject, original: original)
        }
        if let key = ctx.groupsKey, e.pubkey == key {
            if let from = e.tag("mail-from"), !from.isEmpty, mail != nil {
                return .inboxCard(from: from, name: e.tag("mail-name") ?? "", subject: mailSubject, messageId: e.tag("message-id"),
                                  verified: e.tag("belfry-auth") == "pass", original: original)
            }
            if e.hasTag("client", "belfry-mail-out") {
                return .sentAsChannel(to: e.tag("mail-to") ?? "", subject: e.tag("subject") ?? "", by: e.tag("sent-by") ?? "")
            }
        }
        if legacy, let c = Derive.eventCoordOf(e) { return .eventCard(coord: c) }
        if let p = Derive.podOf(e) { return .podCard(podId: p) }
        if let p = Derive.proposalOf(e) { return .proposalCard(groupId: p) }
        return mail ?? .none
    }

    private var messagesCache = [String: [Message]]()

    /// A channel's messages: kind 9, not deleted, oldest first, each as its author last edited it.
    public func messages(_ groupId: String) -> [Message] {
        if let c = messagesCache[groupId] { return c }
        let out = inGroupSorted(groupId).filter { $0.kind == 9 && !deletedSet.contains($0.id) }.map(parse)
        messagesCache[groupId] = out
        return out
    }

    public func message(_ groupId: String, _ id: String) -> Message? {
        messages(groupId).first { $0.id == id } ?? allReplies(groupId).first { $0.id == id }
    }

    /// My own plain message or reply, already sent, with text (SPEC 19.1).
    public func canEdit(_ m: Message) -> Bool { m.pubkey == me && !isPending(m.id) && !m.text.isEmpty && m.special == .none }
    public func canDelete(_ m: Message) -> Bool { m.pubkey == me && !isPending(m.id) }

    /// What the delete confirmation shows of the message (240 units, mentions hidden; SPEC 19.2).
    public func deletePreview(_ m: Message) -> String {
        let t = !m.text.isEmpty ? m.text : m.media.isEmpty ? "" : m.media.count == 1 ? "A photo or file" : "\(m.media.count) photos or files"
        return plainRefs(t).sliceUnits(240)
    }

    /// Every photo and file posted in the channel, newest first.
    public func files(_ groupId: String) -> [Media] { messages(groupId).flatMap(\.media).reversed() }

    // ---- reactions ------------------------------------------------------------------------------

    private var reactionsCache = [String: [String: [Reaction]]]()

    public func reactions(_ groupId: String) -> [String: [Reaction]] {
        if let c = reactionsCache[groupId] { return c }
        var byMsg = [String: [Reaction]]()
        for e in inGroupSorted(groupId) where e.kind == 7 && !deletedSet.contains(e.id) {
            guard let target = e.tags.last(where: { $0.first == "e" && $0.count > 1 })?[1] else { continue }
            let trimmed = (e.content.isEmpty ? "+" : e.content).jsTrim()
            let emoji = trimmed == "+" ? "👍" : trimmed
            guard !emoji.isEmpty, emoji.utf16.count <= 16 else { continue }
            var list = byMsg[target] ?? []
            if let i = list.firstIndex(where: { $0.emoji == emoji }) {
                if !list[i].who.contains(e.pubkey) { list[i].who.append(e.pubkey) }
                if e.pubkey == me { list[i].mine = e.id }
            } else {
                list.append(Reaction(emoji: emoji, who: [e.pubkey], mine: e.pubkey == me ? e.id : nil))
            }
            byMsg[target] = list
        }
        let out = byMsg.mapValues { list in
            list.enumerated().sorted { a, b in
                a.element.who.count != b.element.who.count ? a.element.who.count > b.element.who.count : a.offset < b.offset
            }.map(\.element)
        }
        reactionsCache[groupId] = out
        return out
    }

    // ---- threads (NIP-22) -----------------------------------------------------------------------

    public static func rootOf(_ e: NostrEvent) -> String? { e.tags.first { $0.first == "E" && $0.count > 1 }?[1] }

    private var repliesCache = [String: [Message]]()
    private func allReplies(_ groupId: String) -> [Message] {
        if let c = repliesCache[groupId] { return c }
        let out = inGroupSorted(groupId).filter { $0.kind == 1111 && !deletedSet.contains($0.id) }.map(parse)
        repliesCache[groupId] = out
        return out
    }

    public func threadReplies(_ groupId: String, _ rootId: String) -> [Message] {
        allReplies(groupId).filter { Derive.rootOf($0.ev) == rootId }
    }

    /// The inline thread's window: the latest 3 replies and how many earlier ones are hidden.
    public func inlineThread(_ groupId: String, _ rootId: String, showAll: Bool = false) -> (shown: [Message], hidden: Int) {
        let r = threadReplies(groupId, rootId)
        let shown = showAll ? r : Array(r.suffix(3))
        return (shown, r.count - shown.count)
    }

    public func threadsOf(_ groupId: String) -> [String: ThreadInfo] {
        Dictionary(uniqueKeysWithValues: threadsInOrder(groupId).map { ($0.root, $0.info) })
    }

    private var threadsCache = [String: [(root: String, info: ThreadInfo)]]()

    /// Per root, in the order the roots first got a reply in the log.
    public func threadsInOrder(_ groupId: String) -> [(root: String, info: ThreadInfo)] {
        if let c = threadsCache[groupId] { return c }
        var out = [String: ThreadInfo]()
        var order = [String]()
        for e in inGroup(groupId) where e.kind == 1111 && !deletedSet.contains(e.id) {
            guard let root = Derive.rootOf(e) else { continue }
            if out[root] == nil { order.append(root) }
            var t = out[root] ?? ThreadInfo(count: 0, last: 0, who: [])
            t.count += 1
            t.last = max(t.last, e.createdAt)
            if !t.who.contains(e.pubkey) { t.who.append(e.pubkey) }
            out[root] = t
        }
        let list = order.map { (root: $0, info: out[$0]!) }
        threadsCache[groupId] = list
        return list
    }

    // ---- guests (SPEC 13, 19.3) -----------------------------------------------------------------

    private var joinsCache = [String: [GuestJoin]]()

    public func guestJoins(_ groupId: String) -> [GuestJoin] {
        if let c = joinsCache[groupId] { return c }
        let list = inGroup(groupId)
        var saved = Set<String>(), member = Set<String>()
        for e in list where e.kind == 1985 && e.tag("L") == Derive.guestNS {
            let p = e.tag("p") ?? ""
            if e.tags.contains(where: { $0.count >= 2 && $0[0] == "l" && $0[1] == "saved" }) { saved.insert(p) }
            if e.tags.contains(where: { $0.count >= 2 && $0[0] == "l" && $0[1] == "member" }) { member.insert(p) }
        }
        var out = [GuestJoin]()
        var gone = [String: Int]()
        var wrote = Set<String>()
        for e in list {
            if e.kind == 9001, let p = e.tag("p"), !p.isEmpty { gone[p] = max(gone[p] ?? 0, e.createdAt) }
            else if e.kind == 9 || e.kind == 1111 { wrote.insert(e.pubkey) }
            guard e.kind == 9000, let by = e.tag("invited-by"), !by.isEmpty, let p = e.tag("p"), !p.isEmpty else { continue }
            // guest mode: opened the link, not joined: no join line, no guest chip (SPEC 19.26)
            if e.tag("reading") == "1" { continue }
            let isMember: Bool
            switch ctx.kinds[p] ?? "" {
            case "member", "agent": isMember = true
            case "guest": isMember = false
            default: isMember = member.contains(p)
            }
            out.append(GuestJoin(id: e.id, pubkey: p, by: by, at: e.createdAt, agent: e.tag("agent") == "1",
                                 unsaved: e.tag("unsaved") == "1" && !saved.contains(p) && !isMember, member: isMember))
        }
        // taken out again without ever writing here (a cleaned-up double sign-up): no line
        let result = out.filter { wrote.contains($0.pubkey) || (gone[$0.pubkey] ?? 0) < $0.at }
            .enumerated().sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }.map(\.element)
        joinsCache[groupId] = result
        return result
    }

    /// How many guests are reading CHANNEL (guest mode, me left out): "N guests are reading".
    public func readingCount(_ groupId: String) -> Int { group(groupId)?.reading.subtracting([me]).count ?? 0 }

    /// Keys that are reading somewhere and in no channel otherwise (not mentionable, not people).
    public lazy var onlyReading: Set<String> = {
        var reading = Set<String>(), inSome = Set<String>()
        for g in groupList { reading.formUnion(g.reading); inSome.formUnion(g.members); inSome.formUnion(g.admins) }
        return reading.subtracting(inSome).subtracting([me])
    }()

    /// Am I reading CHANNEL in guest mode, as the events say (the app's own flag comes first).
    public func amReading(_ groupId: String) -> Bool { group(groupId)?.reading.contains(me) ?? false }

    /// Everyone brought in by a link or as a member's agent: the keys to ask the register about.
    public lazy var guestJoinKeys: [String] = {
        var out = [String](), seen = Set<String>()
        for e in ofKind(9000) where !(e.tag("invited-by") ?? "").isEmpty {
            if let p = e.tag("p"), !p.isEmpty, seen.insert(p).inserted { out.append(p) }
        }
        for k in ctx.agents.keys.sorted() where seen.insert(k).inserted { out.append(k) }
        return out
    }()

    private lazy var allGuestJoins: [GuestJoin] = groupList.flatMap { guestJoins($0.id) }.filter { !$0.member }

    /// Someone's guest joins across all channels, members-since left out.
    public func guestJoinsOf(_ pubkey: String) -> [GuestJoin] { allGuestJoins.filter { $0.pubkey == pubkey } }

    /// Am I (still) a guest here, and not a member.
    public var amGuest: Bool { allGuestJoins.contains { $0.pubkey == me } || groupList.contains { $0.reading.contains(me) } }

    /// Why this person can't be made an admin of the belfry (fixed text), or nil when they can.
    public func noAdminReason(_ pubkey: String) -> String? {
        let joins = guestJoinsOf(pubkey)
        if joins.contains(where: \.agent) { return "An agent cannot be an admin." }
        if !joins.isEmpty && joins.allSatisfy(\.unsaved) { return "This guest has no e-mail yet. Once they save their account, you can make them an admin." }
        return nil
    }

    /// The channels someone is in (not proposals), for their profile.
    public func sharedGroups(_ pubkey: String) -> [Group] { groupList.filter { $0.members.contains(pubkey) && !$0.isProposal } }

    // ---- the feed ------------------------------------------------------------------------------

    /// A channel's feed: messages, guest joins and resurfaced threads (SPEC 8, 19.7).
    public func feed(_ groupId: String, topic: String? = nil) -> [FeedItem] {
        let g = group(groupId)
        let all = messages(groupId)
        let list: [Message]
        if let t = topic {
            list = all.filter { t == Derive.announcement ? isAnnouncement($0, g) : $0.topics.contains(t) }
        } else {
            list = all
        }
        var items: [FeedItem] = list.map { .message($0) }
        if topic == nil {
            items += guestJoins(groupId).map { .join($0) }
            let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (rootId, info) in threadsInOrder(groupId) {
                guard let root = byId[rootId] else { continue }
                let later = list.contains { $0.ev.createdAt > root.ev.createdAt && $0.ev.createdAt < info.last }
                guard later, let last = threadReplies(groupId, rootId).last else { continue }
                items.append(.activity(root: root, last: last))
            }
        }
        // by time; at equal times messages first, otherwise the order they were added in
        return items.enumerated().sorted { a, b in
            if a.element.at != b.element.at { return a.element.at < b.element.at }
            if a.element.isMessage != b.element.isMessage { return a.element.isMessage }
            return a.offset < b.offset
        }.map(\.element)
    }

    public lazy var calendarForDays: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = ctx.timeZone
        return c
    }()

    /// The local day of a time as yyyymmdd, in the context's zone.
    public func dayKey(_ at: Int) -> Int {
        let c = calendarForDays.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(at)))
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// The feed with layout hints (SPEC 19.7): day separators, blocks.
    public func feedRows(_ groupId: String, topic: String? = nil, openThreads: Set<String> = []) -> [FeedRow] {
        let g = group(groupId)
        var out = [FeedRow]()
        var prev: FeedItem?
        for item in feed(groupId, topic: topic) {
            let newDay = prev == nil || dayKey(prev!.at) != dayKey(item.at)
            if case .message(let m) = item {
                var p: Message?
                if case .message(let pm)? = prev, !openThreads.contains(pm.id) { p = pm }
                let announce = isAnnouncement(m, g)
                let first = newDay || p == nil || p!.pubkey != m.pubkey || m.at - p!.at > 300 || announce || m.special != .none
                out.append(FeedRow(item: item, newDay: newDay, first: first, announcement: announce))
            } else {
                out.append(FeedRow(item: item, newDay: newDay, first: false))
            }
            prev = item
        }
        return out
    }

    /// A resurfaced thread's first line: the root's text (80 units), mentions hidden.
    public func activitySnippet(_ root: Message) -> String {
        let base = !root.text.isEmpty ? root.text : root.media.isEmpty ? "" : "a photo"
        return plainRefs(base).sliceUnits(80) + (root.text.utf16.count > 80 ? "…" : "")
    }

    public func activityReply(_ last: Message) -> String { plainRefs(last.text.isEmpty ? "a photo" : last.text).sliceUnits(140) }

    /// Topics a message carries that its text doesn't show, except the open one and `announcement`.
    public func extraTopics(_ m: Message, openTopic: String? = nil) -> [String] {
        let inText = Set(Topics.hashtags(m.text))
        return m.topics.filter { !inText.contains($0) && $0 != openTopic && $0 != Derive.announcement }
    }

    // ---- seen and active ------------------------------------------------------------------------

    public static func seenD(_ groupId: String) -> String { "seen:" + groupId }

    public func recentlyActive(_ groupId: String, now: Int = .now) -> [ActiveMember] {
        let since = now - activeDays * 86400
        let g = group(groupId)
        var last = [String: Int]()
        var order = [String]()
        for e in inGroup(groupId) where e.createdAt >= since {
            let seen = e.kind == 30078 && e.tag("d") == Derive.seenD(groupId)
            guard seen || e.kind == 9 || e.kind == 1111 || e.kind == 7 else { continue }
            if last[e.pubkey] == nil { order.append(e.pubkey) }
            if (last[e.pubkey] ?? 0) < e.createdAt { last[e.pubkey] = e.createdAt }
        }
        var known: Set<String>?
        if let g, !g.members.isEmpty { known = g.members.union(g.admins) }
        let reading = g?.reading ?? []
        return order.filter { (known == nil || known!.contains($0)) && !reading.contains($0) }
            .map { ActiveMember(pubkey: $0, at: last[$0]!) }
            .enumerated().sorted { a, b in a.element.at != b.element.at ? a.element.at > b.element.at : a.offset < b.offset }
            .map(\.element)
    }

    public func mySeen(_ groupId: String) -> Int {
        inGroup(groupId).filter { $0.kind == 30078 && $0.pubkey == me && $0.tag("d") == Derive.seenD(groupId) }
            .map(\.createdAt).max() ?? 0
    }

    /// A closed pod I'm not in is not marked as seen.
    public func maySee(_ groupId: String) -> Bool {
        guard let g = group(groupId) else { return false }
        return !(g.isPod && g.closed && !g.members.contains(me))
    }

    // ---- shared inbox setting, announcements ----------------------------------------------------

    public static let inboxD = "belfry:inbox"

    public func isInbox(_ g: Group?) -> Bool {
        guard let g else { return false }
        guard let last = inGroupSorted(g.id).last(where: { $0.kind == 30078 && $0.tag("d") == Derive.inboxD && g.admins.contains($0.pubkey) }) else { return false }
        let obj = JSON.parse(last.content.isEmpty ? "{}" : last.content) as? [String: Any]
        return jsTruthy(obj?["on"])
    }

    /// The channel's e-mail address.
    public func mailAddress(_ groupId: String) -> String { groupId + "@" + ctx.domain }

    /// Per e-mail card id: open / answered / closed, who has it, how many answers went out.
    public func inboxStates(_ groupId: String) -> [String: CardState] {
        var out = [String: CardState]()
        for e in inGroupSorted(groupId) where !deletedSet.contains(e.id) {
            guard let card = e.tag("e"), !card.isEmpty else { continue }
            var c = out[card] ?? CardState()
            if e.kind == 1985, e.tags.contains(where: { $0.count >= 2 && $0[0] == "L" && $0[1] == Derive.inboxNS }) {
                switch e.tags.first(where: { $0.count >= 3 && $0[0] == "l" && $0[2] == Derive.inboxNS })?[1] ?? "" {
                case "open": c.status = .open
                case "closed": c.status = .closed
                case "assigned": c.assignee = e.tag("p").flatMap { $0.isEmpty ? nil : $0 }
                default: break
                }
                out[card] = c
            } else if e.kind == 9, let sender = ctx.groupsKey, e.pubkey == sender, e.hasTag("client", "belfry-mail-out") {
                c.answered += 1
                if c.status == .open { c.status = .waiting }
                out[card] = c
            }
        }
        return out
    }

    public static let announcement = "announcement"

    public func isAnnouncement(_ m: Message, _ g: Group?) -> Bool {
        m.topics.contains(Derive.announcement) && (g?.admins.contains(m.ev.pubkey) ?? false)
    }

    public func hasAnnouncements(_ groupId: String) -> Bool {
        let g = group(groupId)
        return messages(groupId).contains { isAnnouncement($0, g) }
    }

    // ---- topics ---------------------------------------------------------------------------------

    /// A channel's pinned topics: the latest kind 1985 with L = #t.
    public func pinnedTopics(_ groupId: String) -> [String] {
        let latest = inGroupSorted(groupId).last { $0.kind == 1985 && $0.tag("L") == "#t" }
        return latest?.tags.filter { $0.first == "l" && $0.count > 2 && $0[2] == "#t" }.map { Topics.norm($0[1]) } ?? []
    }

    /// The topics a channel's messages carry, most used first (ties: alphabetical).
    public func topicCounts(_ groupId: String) -> [(topic: String, count: Int)] {
        var n = [String: Int]()
        for m in messages(groupId) { for t in m.topics where t != Derive.announcement { n[t, default: 0] += 1 } }
        return n.map { (topic: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.topic < $1.topic }
    }

    // ---- pinned messages (SPEC 19.10) -----------------------------------------------------------

    /// Who may pin in a channel: its admins and the community's.
    public func mayPin(_ g: Group?, _ pubkey: String) -> Bool {
        guard let g else { return false }
        return g.admins.contains(pubkey) || isBelfryAdmin(pubkey)
    }

    public func canPin(_ groupId: String) -> Bool { mayPin(group(groupId), me) }

    private var pinnedCache = [String: [Message]]()

    /// A channel's pinned messages, most recently pinned first.
    public func pinned(_ groupId: String) -> [Message] {
        if let c = pinnedCache[groupId] { return c }
        let g = group(groupId)
        var state = [String: (on: Bool, at: Int)]()
        for e in inGroupSorted(groupId) where e.kind == 1985 && e.tag("L") == Derive.pinNS && mayPin(g, e.pubkey) {
            guard let id = e.tag("e") else { continue }
            let l = e.tag("l")
            guard l == "pinned" || l == "unpinned" else { continue }
            if let had = state[id], had.at > e.createdAt { continue }
            state[id] = (l == "pinned", e.createdAt)
        }
        var out = [Message]()
        if !state.isEmpty {
            out = messages(groupId).filter { state[$0.id]?.on == true }
                .enumerated().sorted { a, b in
                    let x = state[a.element.id]!.at, y = state[b.element.id]!.at
                    return x != y ? x > y : a.offset < b.offset
                }.map(\.element)
        }
        pinnedCache[groupId] = out
        return out
    }

    public func isPinned(_ groupId: String, _ messageId: String) -> Bool { pinned(groupId).contains { $0.id == messageId } }

    /// A pinned message as one plain line.
    public func pinLine(_ m: Message) -> String {
        var s = plainRefs(!m.text.isEmpty ? m.text : m.media.isEmpty ? "" : "A photo or file")
        s = Rx("[*_`>]").replace(s, with: "")
        s = Rx("(^|\\s)#(?=\\s|$)").replace(s, with: "$1")
        return s.components(separatedBy: "\n").first ?? ""
    }

    // ---- task list (kinds 2100-2103) and to-dos (SPEC 19.8, 19.11) ------------------------------

    public static func listIdFor(_ groupId: String) -> String { String(Crypto.sha256("osv-village:" + groupId).hex.prefix(16)) }

    private var tasksCache = [String: [TodoTask]]()

    public func tasks(_ groupId: String) -> [TodoTask] {
        if let c = tasksCache[groupId] { return c }
        let listId = Derive.listIdFor(groupId)
        var tasks = [String: TodoTask]()
        var order = [String]()
        for e in sortedEvents where (2100...2103).contains(e.kind) && e.tag("t") == listId {
            if e.kind == 2100 {
                let title = e.content.jsTrim().sliceUnits(300)
                guard !title.isEmpty else { continue }
                if tasks[e.id] == nil { order.append(e.id) }
                tasks[e.id] = TodoTask(id: e.id, title: title, author: e.pubkey, pending: isPending(e.id), source: e.tag("q"))
            } else if e.kind != 2102 {
                guard let tid = e.tag("e"), var t = tasks[tid] else { continue }
                if e.kind == 2103 { t.comments.append(TaskComment(author: e.pubkey, text: e.content.sliceUnits(2000), at: e.createdAt)) }
                switch e.tag("action") ?? "" {
                case "claim": t.assignee = e.pubkey
                case "unclaim": if t.assignee == e.pubkey { t.assignee = nil }
                case "done": t.done = true
                case "undone": t.done = false
                case "delete":
                    if e.pubkey == t.author { tasks[tid] = nil; order.removeAll { $0 == tid }; continue }
                default: break
                }
                tasks[tid] = t
            }
        }
        let out = order.compactMap { tasks[$0] }
        tasksCache[groupId] = out
        return out
    }

    /// The to-dos made from messages, by the message's id.
    public func todosBySource(_ groupId: String) -> [String: TodoTask] {
        var out = [String: TodoTask]()
        for t in tasks(groupId) { if let s = t.source, out[s] == nil { out[s] = t } }
        return out
    }

    /// The title a message gives its to-do: its text without mentions, channels as "#name", one line, 300 units.
    public func todoTitle(_ m: Message) -> String {
        Rx("\\s+").replace(plainRefs(m.text, npub: ""), with: " ").jsTrim().sliceUnits(300)
    }

    /// "Turn into a to-do" is offered: sent, with a title, and no to-do made from it yet.
    public func canMakeTodo(_ groupId: String, _ m: Message) -> Bool {
        !isPending(m.id) && !todoTitle(m).isEmpty && todosBySource(groupId)[m.id] == nil
    }

    /// What a to-do's mark on its message reads.
    public func todoChip(_ t: TodoTask) -> String {
        if t.done { return "Done" }
        if let a = t.assignee { return "To do · " + displayName(a) }
        return "To do"
    }

    /// Who is on a to-do, as the pull-down says it.
    public func todoWho(_ t: TodoTask) -> String {
        guard let a = t.assignee else { return "Nobody on it yet" }
        return a == me ? "You are on it" : displayName(a) + " is on it"
    }

    // ---- drop box links -------------------------------------------------------------------------

    /// Live drop box links of a channel, newest first.
    public func dropLinks(_ groupId: String, now: Int) -> [DropLink] {
        var out = [DropLink]()
        for e in inGroup(groupId) {
            let d = e.tag("d") ?? ""
            guard e.kind == 30078, d.hasPrefix("drop:") else { continue }
            if deletedSet.contains(e.id) || deletedSet.contains("30078:\(e.pubkey):\(d)") { continue }
            let expires = Int(Double(e.tag("expiration") ?? "") ?? 0)
            guard expires > now else { continue }
            out.append(DropLink(token: String(d.dropFirst(5)), groupId: groupId, expires: expires, login: e.hasTag("login"), author: e.pubkey, ev: e))
        }
        return out.sorted { $0.ev.createdAt > $1.ev.createdAt }
    }

    public func dropURL(_ token: String) -> String { "https://\(ctx.domain)/drop/\(token)" }

    // ---- member labels and the Members tab -----------------------------------------------------

    /// NIP-32 labels per member in a channel (one kind 1985 per member, latest wins).
    public func memberLabels(_ groupId: String) -> [String: [String]] {
        var latest = [String: NostrEvent]()
        for e in inGroupSorted(groupId) where e.kind == 1985 && e.tag("L") == Derive.labelNS {
            if let p = e.tag("p"), !p.isEmpty { latest[p] = e }
        }
        return latest.mapValues { e in e.tags.filter { $0.count >= 3 && $0[0] == "l" && $0[2] == Derive.labelNS }.map { $0[1] } }
    }

    /// Everyone to list in a channel's Members tab.
    public func memberRows(_ groupId: String) -> [MemberRow] {
        let g = group(groupId)
        let labels = memberLabels(groupId)
        var keys = Array(g?.members ?? []).sorted()
        for k in labels.keys.sorted() where !keys.contains(k) && !(g?.reading.contains(k) ?? false) { keys.append(k) }
        if g?.isPod != true, !keys.contains(me) { keys.append(me) }
        var invited = [String: GuestJoin]()
        for j in guestJoins(groupId) where !j.member { invited[j.pubkey] = j }
        return keys.filter { !$0.isEmpty }.map {
            MemberRow(pubkey: $0, name: displayName($0), place: extras[$0]?.place, guest: invited[$0], labels: labels[$0] ?? [], isAdmin: g?.admins.contains($0) ?? false)
        }.sorted { a, b in
            if a.isAdmin != b.isAdmin { return a.isAdmin }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    // ---- people: tags and places (SPEC 19.5) ----------------------------------------------------

    public lazy var extras: [String: Extras] = {
        var out = [String: Extras]()
        for e in ofKind(30078) where e.hasTag("d", Derive.profileD) {
            if let prev = out[e.pubkey], prev.at >= e.createdAt { continue }
            if let x = People.parseExtras(e.content, at: e.createdAt) { out[e.pubkey] = x }
        }
        return out
    }()

    /// Tags any member uses, most used first (ties alphabetical): the suggestions when you add yours.
    public lazy var allTags: [(tag: String, count: Int)] = {
        var n = [String: Int]()
        for x in extras.values { for t in x.tags { n[t, default: 0] += 1 } }
        return n.map { (tag: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }()

    // ---- search (SPEC 14) -----------------------------------------------------------------------

    /// Every word must appear (accents and case folded) in the text, the author's name or a file name.
    public func search(_ query: String, channel: String? = nil, limit: Int = 200) -> [SearchHit] {
        let words = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.isEmpty { return [] }
        let scope = channel.map { [$0] } ?? groupList.map(\.id)
        var out = [SearchHit]()
        for gid in scope {
            for m in messages(gid) {
                let hay = fold("\(m.text) \(displayName(m.pubkey)) \(m.media.map { $0.name ?? "" }.joined(separator: " "))")
                if words.allSatisfy({ hay.contains($0) }) { out.append(SearchHit(m: m, groupId: gid)) }
            }
        }
        return Array(out.sorted { $0.m.at > $1.m.at }.prefix(limit))
    }
}

// ---- small JS-like helpers ----------------------------------------------------------------------

public extension String {
    /// The first N UTF-16 units (JavaScript's slice(0, n)).
    func sliceUnits(_ n: Int) -> String {
        if utf16.count <= n { return self }
        return String(decoding: Array(utf16.prefix(n)), as: UTF16.self)
    }

    /// JavaScript's trim().
    func jsTrim() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func jsTrimStart() -> String {
        var s = Substring(self)
        while let c = s.first, c.isWhitespace { s = s.dropFirst() }
        return String(s)
    }
}

/// JavaScript truthiness of a JSON value.
public func jsTruthy(_ v: Any?) -> Bool {
    switch v {
    case nil: return false
    case is NSNull: return false
    case let b as Bool: return b
    case let n as NSNumber: return n.doubleValue != 0
    case let s as String: return !s.isEmpty
    default: return true
    }
}
