import Foundation

// Derived views over the event log (SPEC sections 6-13): pure functions of the events and who I
// am, ported from the web chat's src/core/model.ts and checked against vectors/.

public let generalId = "general"
public let activeDays = 30

public struct Profile: Hashable, Sendable {
    public var name: String?
    public var picture: String?
    public var nip05: String?
    public var at: Int = 0
}

public enum ChannelType: String, Sendable { case channel, event, pod, proposal }

public struct Application: Hashable, Sendable { public let pubkey: String; public let answer: String; public let at: Int }

public struct Group: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var about: String
    public var picture: String?
    public var createdAt: Int
    public var lastActivity: Int
    public var members: Set<String> = []
    public var admins: Set<String> = []
    public var closed = false
    public var prompt: String?
    public var parent: String?
    public var applications: [Application] = []
    public var pending = false

    public var type: ChannelType {
        if id.hasPrefix("ws-") || id.hasPrefix("ev-") { return .event }
        if id.hasPrefix("pod-") { return .pod }
        if id.hasPrefix("prop-") { return .proposal }
        return .channel
    }

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
}

public struct Message: Identifiable, Hashable, Sendable {
    public let ev: NostrEvent
    public let text: String
    public let media: [Media]
    public let topics: [String]
    public var id: String { ev.id }
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

public struct GuestJoin: Hashable, Sendable, Identifiable {
    public let id: String
    public let pubkey: String
    public let by: String?
    public let at: Int
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
}

public struct ActiveMember: Hashable, Sendable { public let pubkey: String; public let at: Int }

public struct Derive {
    public let events: [NostrEvent]
    public let me: String
    public let communityAdmins: Set<String>

    public init(events: [NostrEvent], me: String, communityAdmins: Set<String> = []) {
        self.events = events
        self.me = me
        self.communityAdmins = communityAdmins
    }

    public static func byTime(_ a: NostrEvent, _ b: NostrEvent) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
    }

    var sortedEvents: [NostrEvent] { events.sorted(by: Derive.byTime) }

    // ---- deletion ----------------------------------------------------------------------------

    public func deleted() -> Set<String> {
        var out = Set<String>()
        var authors = [String: String]()
        for e in events { authors[e.id] = e.pubkey }
        for e in events {
            if e.kind == 9005 { for t in e.tags where t.first == "e" && t.count > 1 && !t[1].isEmpty { out.insert(t[1]) } }
            guard e.kind == 5 else { continue }
            for t in e.tags where t.count > 1 {
                if t[0] == "e", authors[t[1]] == e.pubkey { out.insert(t[1]) }
                if t[0] == "a" {
                    let parts = t[1].split(separator: ":", omittingEmptySubsequences: false)
                    if parts.count > 1, String(parts[1]) == e.pubkey { out.insert(t[1]) }
                }
            }
        }
        return out
    }

    // ---- profiles ------------------------------------------------------------------------------

    public func profiles() -> [String: Profile] {
        var out = [String: Profile]()
        var guests = [(String, String)]()
        for e in events {
            if e.kind == 9000, let name = e.tag("name"), let p = e.tag("p") { guests.append((p, String(name.prefix(100)))) }
            guard e.kind == 0 else { continue }
            if let prev = out[e.pubkey], prev.at >= e.createdAt { continue }
            guard let obj = JSON.parse(e.content) as? [String: Any] else { continue }
            func str(_ k: String) -> String? { (obj[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            out[e.pubkey] = Profile(name: str("display_name") ?? str("name"), picture: str("picture"), nip05: str("nip05"), at: e.createdAt)
        }
        for (pk, name) in guests where out[pk]?.name == nil {
            var p = out[pk] ?? Profile()
            p.name = name
            out[pk] = p
        }
        return out
    }

    /// The name others know someone by (never "You").
    public static func realName(_ pubkey: String, _ ps: [String: Profile]) -> String {
        let p = ps[pubkey]
        if let n = p?.name, !n.isEmpty { return n }
        if let n5 = p?.nip05, let local = n5.split(separator: "@").first { return String(local) }
        return ""
    }

    public func displayName(_ pubkey: String, _ ps: [String: Profile]) -> String {
        if pubkey == me { return "You" }
        let r = Derive.realName(pubkey, ps)
        if !r.isEmpty { return r }
        return String((Bech32.npub(pubkey) ?? pubkey).prefix(12)) + "…"
    }

    // ---- groups --------------------------------------------------------------------------------

    public func groups() -> [Group] {
        var map = [String: Group]()
        var order = [String]()
        var metaAt = [String: [String: Int]]()
        var applied = [String: NostrEvent]() // group + pubkey
        var appliedOrder = [String]()
        var decided = [String: Int]()
        let list = sortedEvents
        func get(_ id: String, _ at: Int) -> Group {
            if let g = map[id] { return g }
            let g = Group(id: id, name: id, about: "", createdAt: at, lastActivity: at)
            map[id] = g
            order.append(id)
            return g
        }
        for e in list {
            let gid = (39000...39003).contains(e.kind) ? e.tag("d") : e.tag("h")
            guard let id = gid else { continue }
            var g = get(id, e.createdAt)
            var m = metaAt[id] ?? [:]
            if e.kind == 9007 {
                g.createdAt = min(g.createdAt, e.createdAt)
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
            if e.kind == 9000 || e.kind == 9001, let p = e.tag("p") {
                if e.kind == 9000 { g.members.insert(p) } else { g.members.remove(p) }
                decided[id + p] = e.createdAt
            }
            if e.kind == 9 {
                g.lastActivity = max(g.lastActivity, e.createdAt)
                g.members.insert(e.pubkey)
            }
            if e.kind == 9021 {
                if !g.closed { g.members.insert(e.pubkey) } else {
                    let k = id + e.pubkey
                    if applied[k] == nil { appliedOrder.append(k) }
                    applied[k] = e
                }
            }
            if e.kind == 9022 { g.members.remove(e.pubkey) }
            map[id] = g
            metaAt[id] = m
        }
        // a pod or proposal lives where it was announced
        for e in list where e.kind == 9 {
            guard let sub = podOf(e) ?? proposalOf(e), let h = e.tag("h"), h != sub, var g = map[sub], g.parent == nil else { continue }
            g.parent = h
            map[sub] = g
        }
        for id in order where (map[id]!.type == .pod || map[id]!.type == .proposal) && map[id]!.parent == nil { map[id]!.parent = generalId }
        for k in appliedOrder {
            let e = applied[k]!
            let gid = String(k.dropLast(64))
            guard var g = map[gid], !g.members.contains(e.pubkey), (decided[k] ?? 0) < e.createdAt else { continue }
            g.applications.append(Application(pubkey: e.pubkey, answer: e.content, at: e.createdAt))
            map[gid] = g
        }
        let gone = Set(events.filter { $0.kind == 9008 }.compactMap { $0.tag("h") })
        return order.compactMap { map[$0] }.filter { !gone.contains($0.id) }.enumerated().sorted { x, y in
            let a = x.element, b = y.element
            if a.id == generalId || b.id == generalId { return a.id == generalId && b.id != generalId }
            return a.lastActivity != b.lastActivity ? a.lastActivity > b.lastActivity : x.offset < y.offset
        }.map(\.element)
    }

    public func group(_ id: String) -> Group? { groups().first { $0.id == id } }

    public func podOf(_ e: NostrEvent) -> String? { e.tag("pod").flatMap { $0.hasPrefix("pod-") ? $0 : nil } }
    public func proposalOf(_ e: NostrEvent) -> String? { e.tag("proposal").flatMap { $0.hasPrefix("prop-") ? $0 : nil } }

    // ---- admin rights ---------------------------------------------------------------------------

    public var isCommunityAdmin: Bool { communityAdmins.contains(me) }

    public func canAdmin(_ g: Group?) -> Bool {
        guard let g else { return false }
        return g.admins.contains(me) || isCommunityAdmin
    }

    // ---- messages -----------------------------------------------------------------------------

    public static func parseMedia(_ e: NostrEvent) -> Message {
        var media = [Media]()
        for t in e.tags where t.first == "imeta" {
            var f = [String: String]()
            for p in t.dropFirst() {
                guard let sp = p.firstIndex(of: " ") else { continue }
                let k = String(p[..<sp])
                f[k] = String(p[p.index(after: sp)...])
            }
            guard let url = f["url"], url.hasPrefix("http:") || url.hasPrefix("https:") || url.hasPrefix("idb:") || url.hasPrefix("file:") else { continue }
            let dim = (f["dim"] ?? "").split(separator: "x").map { Int($0) ?? 0 }
            let w = dim.count > 0 && dim[0] > 0 ? dim[0] : nil
            let h = dim.count > 1 && dim[1] > 0 ? dim[1] : nil
            media.append(Media(url: url, mime: f["m"] ?? "", name: f["alt"], w: w, h: h))
        }
        var text = e.content
        for m in media { text = text.components(separatedBy: m.url).joined() }
        var topics = [String]()
        for t in e.tags where t.first == "t" && t.count > 1 && !t[1].isEmpty {
            let n = Topics.norm(t[1])
            if !topics.contains(n) { topics.append(n) }
        }
        return Message(ev: e, text: text.trimmingCharacters(in: .whitespacesAndNewlines), media: media, topics: topics)
    }

    public func messages(_ groupId: String) -> [Message] {
        let del = deleted()
        return events.filter { $0.kind == 9 && $0.tag("h") == groupId && !del.contains($0.id) }
            .sorted(by: Derive.byTime).map(Derive.parseMedia)
    }

    // ---- reactions ------------------------------------------------------------------------------

    public func reactions(_ groupId: String) -> [String: [Reaction]] {
        let del = deleted()
        var byMsg = [String: [Reaction]]()
        for e in events.filter({ $0.kind == 7 && $0.tag("h") == groupId && !del.contains($0.id) }).sorted(by: Derive.byTime) {
            guard let target = e.tags.last(where: { $0.first == "e" && $0.count > 1 })?[1] else { continue }
            let trimmed = (e.content.isEmpty ? "+" : e.content).trimmingCharacters(in: .whitespacesAndNewlines)
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
        return byMsg.mapValues { list in
            // stable sort by count, descending
            list.enumerated().sorted { a, b in
                a.element.who.count != b.element.who.count ? a.element.who.count > b.element.who.count : a.offset < b.offset
            }.map(\.element)
        }
    }

    // ---- threads (NIP-22) -----------------------------------------------------------------------

    public static func rootOf(_ e: NostrEvent) -> String? { e.tags.first { $0.first == "E" && $0.count > 1 }?[1] }

    public func threadReplies(_ groupId: String, _ rootId: String) -> [Message] {
        let del = deleted()
        return events.filter { $0.kind == 1111 && $0.tag("h") == groupId && Derive.rootOf($0) == rootId && !del.contains($0.id) }
            .sorted(by: Derive.byTime).map(Derive.parseMedia)
    }

    public func threadsOf(_ groupId: String) -> [String: ThreadInfo] {
        Dictionary(uniqueKeysWithValues: threadsInOrder(groupId).map { ($0.root, $0.info) })
    }

    /// Per root, in the order the roots first got a reply in the log.
    public func threadsInOrder(_ groupId: String) -> [(root: String, info: ThreadInfo)] {
        let del = deleted()
        var out = [String: ThreadInfo]()
        var order = [String]()
        for e in events where e.kind == 1111 && e.tag("h") == groupId && !del.contains(e.id) {
            guard let root = Derive.rootOf(e) else { continue }
            if out[root] == nil { order.append(root) }
            var t = out[root] ?? ThreadInfo(count: 0, last: 0, who: [])
            t.count += 1
            t.last = max(t.last, e.createdAt)
            if !t.who.contains(e.pubkey) { t.who.append(e.pubkey) }
            out[root] = t
        }
        return order.map { ($0, out[$0]!) }
    }

    public func guestJoins(_ groupId: String) -> [GuestJoin] {
        events.compactMap { e -> GuestJoin? in
            guard e.kind == 9000, e.tag("h") == groupId, e.tag("invited-by") != nil, let p = e.tag("p") else { return nil }
            return GuestJoin(id: e.id, pubkey: p, by: e.tag("invited-by"), at: e.createdAt)
        }.sorted { $0.at < $1.at }
    }

    /// The channel's feed: messages, guest joins and resurfaced threads (SPEC 8).
    public func feed(_ groupId: String, topic: String? = nil) -> [FeedItem] {
        let all = messages(groupId)
        let list = topic.map { t in all.filter { $0.topics.contains(t) } } ?? all
        var items: [FeedItem] = list.map { .message($0) }
        if topic == nil {
            items += guestJoins(groupId).map { .join($0) }
            for (rootId, info) in threadsInOrder(groupId) {
                guard let root = list.first(where: { $0.ev.id == rootId }) else { continue }
                let later = list.contains { $0.ev.createdAt > root.ev.createdAt && $0.ev.createdAt < info.last }
                guard later, let last = threadReplies(groupId, rootId).last else { continue }
                items.append(.activity(root: root, last: last))
            }
        }
        // by time; at equal times messages first, otherwise the order they were added in
        return items.enumerated().sorted { a, b in
            if a.element.at != b.element.at { return a.element.at < b.element.at }
            let am = { if case .message = a.element { return true } else { return false } }()
            let bm = { if case .message = b.element { return true } else { return false } }()
            if am != bm { return am }
            return a.offset < b.offset
        }.map(\.element)
    }

    // ---- seen and active ------------------------------------------------------------------------

    public static func seenD(_ groupId: String) -> String { "seen:" + groupId }

    public func recentlyActive(_ groupId: String, now: Int = .now) -> [ActiveMember] {
        let since = now - activeDays * 86400
        let g = group(groupId)
        var last = [String: Int]()
        var order = [String]()
        for e in events where e.createdAt >= since && e.tag("h") == groupId {
            let seen = e.kind == 30078 && e.tag("d") == Derive.seenD(groupId)
            guard seen || e.kind == 9 || e.kind == 1111 || e.kind == 7 else { continue }
            if last[e.pubkey] == nil { order.append(e.pubkey) }
            if (last[e.pubkey] ?? 0) < e.createdAt { last[e.pubkey] = e.createdAt }
        }
        var known: Set<String>?
        if let g, !g.members.isEmpty { known = g.members.union(g.admins) }
        return order.filter { known == nil || known!.contains($0) }
            .map { ActiveMember(pubkey: $0, at: last[$0]!) }
            .enumerated().sorted { a, b in a.element.at != b.element.at ? a.element.at > b.element.at : a.offset < b.offset }
            .map(\.element)
    }

    public func mySeen(_ groupId: String) -> Int {
        events.filter { $0.kind == 30078 && $0.pubkey == me && $0.tag("d") == Derive.seenD(groupId) && $0.tag("h") == groupId }
            .map(\.createdAt).max() ?? 0
    }

    // ---- shared inbox setting, announcements ----------------------------------------------------

    public static let inboxD = "belfry:inbox"

    public func isInbox(_ g: Group?) -> Bool {
        guard let g else { return false }
        let own = events.filter { $0.kind == 30078 && $0.tag("d") == Derive.inboxD && $0.tag("h") == g.id && g.admins.contains($0.pubkey) }
            .sorted(by: Derive.byTime)
        guard let last = own.last else { return false }
        let obj = JSON.parse(last.content.isEmpty ? "{}" : last.content) as? [String: Any]
        return (obj?["on"] as? Bool) ?? false
    }

    public static let announcement = "announcement"

    public func isAnnouncement(_ m: Message, _ g: Group?) -> Bool {
        m.topics.contains(Derive.announcement) && (g?.admins.contains(m.ev.pubkey) ?? false)
    }

    /// A channel's pinned topics: the latest kind 1985 with L = #t.
    public func pinnedTopics(_ groupId: String) -> [String] {
        let latest = events.filter { $0.kind == 1985 && $0.tag("h") == groupId && $0.tag("L") == "#t" }.max { Derive.byTime($0, $1) }
        return latest?.tags.filter { $0.first == "l" && $0.count > 2 && $0[2] == "#t" }.map { Topics.norm($0[1]) } ?? []
    }
}
