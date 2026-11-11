import Foundation

// Calendar events (SPEC 19.8 older `ws-` sessions, 19.18 Belfry events). Port of the web chat's
// src/core/events.ts (belfry-chat ef9e1cc) through the Android app's model/Events.kt.
//
//   event         NIP-52 31922 / 31923 on the community relay. Belfry events: `d` =
//                 <year>-<6 of a-z0-9>, chat = NIP-29 group ev-<d> (the hosts are its admins).
//                 Rule B: among the versions with that d signed by a host, the newest counts;
//                 the coordinate stays the creator's.
//   ticket type   NIP-99 kind 30402, `d` = <event d>:<id>; none: the implicit open <d>:free.
//   holding one   kind 9000 in ev-<d> with `ticket` (a later 9001 takes it back)
//   application   kind 9021 in ev-<d>, `ticket`, content = the answer; `waitlist` when full
//   RSVP          NIP-52 31925 (`ticket` when one is held); a guest's on the groups relay with `h`
//   status        NIP-32 label belfry/event-status (cancelled | scheduled) by a host

public enum Rsvp: String, Sendable, CaseIterable {
    case accepted, tentative, declined
    public var label: String { self == .accepted ? "Going" : self == .tentative ? "Maybe" : "Can't go" }
}

public enum Visibility: String, Sendable, CaseIterable {
    case members, link, `public`
    public static func of(_ s: String?) -> Visibility { Visibility(rawValue: s ?? "") ?? .members }
    public var label: String { self == .members ? "Members" : self == .link ? "Link" : "Public" }
    public var hint: String { self == .members ? "Only members see it" : self == .link ? "Anyone with the URL" : "Listed on the website" }
}

public enum EventStatus: String, Sendable { case scheduled, cancelled }

public struct CalEvent: Hashable, Sendable, Identifiable {
    /// kind:creator:d
    public var coord: String
    public var d: String
    /// The version that counts.
    public var ev: NostrEvent
    public var title: String
    public var description: String
    public var location: String?
    public var allDay: Bool
    /// Unix seconds (all-day: midnight in the context's zone).
    public var start: Int
    public var end: Int?
    /// Its own chat (`ev-<d>` or `ws-…`).
    public var groupId: String
    /// Online meeting links (`r` tags, https only).
    public var links: [String]
    /// The channels its card was sent in (not its own chat).
    public var channels: [String] = []
    public var rsvps: [String: Rsvp] = [:]
    public var rsvpEvents: [String: NostrEvent] = [:]
    public var tz: String?
    /// A Belfry event, not an older session.
    public var isNew = false
    public var creator: String
    /// The creator and the admins of its group.
    public var hosts: Set<String>
    public var cover: String?
    public var visibility: Visibility = .members
    public var slug: String?
    public var status: EventStatus = .scheduled
    public var statusReason: String?
    /// Every host's version seen, oldest first.
    public var versions: [NostrEvent]
    public var goingKeys: [String] = []
    /// Read from the belfry's API (a guest can't read the community relay).
    public var remote = false
    public var goingCount = 0

    public var id: String { coord }
    public var going: Int { goingCount }
    public var author: String { ev.pubkey }
    /// The last part of its URL: its custom name, else its id.
    public var link: String { slug ?? d }
    /// The first channel its card is in ("general" when none).
    public var channel: String { channels.first ?? generalId }
}

public struct Ticket: Hashable, Sendable, Identifiable {
    /// `<event d>:<id>`
    public var d: String
    public var id: String
    public var title: String
    public var summary = ""
    public var quantity: Int?
    /// Needs an application.
    public var closed = false
    public var prompt = ""
    public var members = false
    public var position = 0
    public var implicit = false
    public var ev: NostrEvent?
    /// Places left as the belfry counted them (remote events).
    public var apiLeft: Int?
}

public struct EventApplication: Hashable, Sendable {
    public let pubkey: String
    public let answer: String
    public let ticket: String?
    public let waitlist: Bool
    public let at: Int
    public let ev: NostrEvent
}

public struct EventPeople: Hashable, Sendable {
    /// pubkey → ticket d
    public var holders: [String: String]
    public var applications: [EventApplication]
    public var declined: Set<String>
    public static let empty = EventPeople(holders: [:], applications: [], declined: [])

    public func taken(_ ticketD: String) -> Int { holders.values.filter { $0 == ticketD }.count }
    /// nil: no limit.
    public func placesLeft(_ t: Ticket) -> Int? { t.apiLeft ?? t.quantity.map { max(0, $0 - taken(t.d)) } }
}

/// Where I stand with an event, first match.
public enum MyState: String, Sendable {
    case host, ticket, maybe, cant, applied, waitlist, declined, none
    /// On rows and cards; nil = nothing to say.
    public var label: String? {
        switch self {
        case .host: return "Hosting"
        case .ticket: return "Going"
        case .maybe: return "Maybe"
        case .cant: return "Can't go"
        case .applied: return "Applied"
        case .waitlist: return "Waitlist"
        case .declined: return "Not this time"
        case .none: return nil
        }
    }
    /// On the event's line.
    public var line: String? {
        switch self {
        case .ticket: return "You’re going"
        case .maybe: return "Maybe"
        case .cant: return "Can’t go"
        case .applied: return "Application sent: the hosts will answer"
        case .waitlist: return "On the waitlist: the hosts will tell you"
        case .declined: return "The hosts could not give you a place"
        default: return nil
        }
    }
}

public enum EventsTab: String, Sendable, CaseIterable {
    case upcoming, mine, hosting, past
    public var label: String { self == .upcoming ? "Upcoming" : self == .mine ? "Mine" : self == .hosting ? "Hosting" : "Past" }
    public var empty: String {
        switch self {
        case .upcoming: return "Nothing planned yet. Make the first event."
        case .mine: return "You’re not going to anything yet."
        case .hosting: return "You’re not hosting anything yet."
        case .past: return "No past events."
        }
    }
}

/// Ids, links and URL names.
public enum EventLinks {
    public static let dRx = Rx("^\\d{4}-[a-z0-9]{6}$")
    public static let slugRx = Rx("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$")
    static let reserved: Set<String> = ["new", "slug", "feed", "past", "mine"]
    public static let statusNS = "belfry/event-status"
    static let alpha = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public static func isD(_ s: String) -> Bool { dRx.test(s) }

    /// A new event's id: the year it is made in (UTC) and 6 random characters.
    public static func newD(now: Int, random: Data = Crypto.random(6)) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let year = c.component(.year, from: Date(timeIntervalSince1970: TimeInterval(now)))
        return "\(year)-" + String([UInt8](random).prefix(6).map { alpha[Int($0) % 36] })
    }

    /// Why a custom URL can't be used (fixed text), or nil.
    public static func slugProblem(_ s: String) -> String? {
        if !slugRx.test(s) { return "3 to 40 of a–z, 0–9 and -" }
        if dRx.test(s) { return "That is shaped like an event’s own id" }
        if reserved.contains(s) { return "That word is kept" }
        return nil
    }

    /// The URL name a title suggests.
    public static func slugOf(_ title: String) -> String {
        let folded = title.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        var s = Rx("[^a-z0-9]+").replace(folded, with: "-")
        s = Rx("^-+|-+$").replace(s, with: "")
        s = String(s.prefix(40))
        while s.hasSuffix("-") { s.removeLast() }
        return s
    }

    /// Keeps what a URL name may hold while it is typed.
    public static func cleanSlug(_ s: String) -> String { String(Rx("[^a-z0-9-]").replace(s.lowercased(), with: "").prefix(40)) }

    public static func url(domain: String, link: String) -> String { "https://\(domain)/events/\(link)" }

    /// https://<own domain>/events/<link> in a text: the links, at most three, in order.
    public static func linksIn(_ text: String, domain: String) -> [String] {
        if domain.isEmpty || text.isEmpty { return [] }
        let re = Rx("https://" + NSRegularExpression.escapedPattern(for: domain) + "/events/([a-z0-9][a-z0-9-]{1,38}[a-z0-9])(?![a-z0-9-])")
        var out = [String]()
        for m in re.matches(text) { if let l = m[1], !out.contains(l) { out.append(l) } }
        return Array(out.prefix(3))
    }

    public static func isEventKind(_ k: Int) -> Bool { k == 31922 || k == 31923 }

    /// Every event coordinate a message's `a` tags name (up to three).
    public static func coordsOf(_ e: NostrEvent) -> [String] {
        var out = [String]()
        for t in e.tags where t.count >= 2 && t[0] == "a" {
            let k = Int(t[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") ?? 0
            if isEventKind(k), !out.contains(t[1]) { out.append(t[1]) }
        }
        return Array(out.prefix(3))
    }

    /// Who holds a ticket, who applied, who was declined: from the event group's events (by time).
    public static func people(_ groupEvents: [NostrEvent]) -> EventPeople {
        var put = [String: NostrEvent](), out = [String: Int](), decided = [String: Int](), left = [String: Int]()
        var applied = [String: NostrEvent](), appliedOrder = [String]()
        for x in groupEvents {
            let p = x.tag("p") ?? ""
            switch x.kind {
            case 9000:
                if !p.isEmpty { decided[p] = x.createdAt; if !(x.tag("ticket") ?? "").isEmpty { put[p] = x } }
            case 9001:
                if !p.isEmpty { decided[p] = x.createdAt; out[p] = x.createdAt }
            case 9021:
                if applied[x.pubkey] == nil { appliedOrder.append(x.pubkey) }
                applied[x.pubkey] = x
            case 9022: left[x.pubkey] = x.createdAt
            default: break
            }
        }
        var holders = [String: String]()
        for (p, x) in put where x.createdAt > (out[p] ?? 0) { holders[p] = x.tag("ticket")! }
        var apps = [EventApplication]()
        for p in appliedOrder {
            let x = applied[p]!
            if holders[p] != nil || (decided[p] ?? 0) >= x.createdAt || (left[p] ?? 0) >= x.createdAt { continue }
            apps.append(EventApplication(pubkey: p, answer: x.content, ticket: x.tag("ticket"), waitlist: x.hasTag("waitlist"), at: x.createdAt, ev: x))
        }
        let declined = Set(out.filter { holders[$0.key] == nil && $0.value >= (decided[$0.key] ?? 0) }.keys)
        return EventPeople(holders: holders, applications: apps.sorted { $0.at < $1.at }, declined: declined)
    }

    public static func freeTicket(_ d: String) -> Ticket { Ticket(d: d + ":free", id: "free", title: "RSVP", implicit: true) }
}

/// Going: ticket holders who did not say otherwise, and RSVPs on the free ticket.
public func goingList(_ e: CalEvent, _ p: EventPeople) -> [String] {
    var keys = p.holders.keys.sorted()
    for (k, s) in e.rsvps.sorted(by: { $0.key < $1.key }) where s == .accepted && !keys.contains(k) { keys.append(k) }
    return keys.filter { (e.rsvps[$0] ?? .accepted) == .accepted }
}

extension Derive {
    func calTime(_ v: String?, allDay: Bool) -> Int? {
        guard let v, !v.isEmpty else { return nil }
        if allDay {
            let parts = v.prefix(10).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var dc = DateComponents()
            dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
            return calendarForDays.date(from: dc).map { Int($0.timeIntervalSince1970) }
        }
        guard let d = Double(v.jsTrim()), d.isFinite else { return nil }
        return Int(d)
    }

    /// Midnight today in the context's zone.
    public func startOfDay(_ now: Int) -> Int {
        Int(calendarForDays.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now))).timeIntervalSince1970)
    }

    func computeCalendar() -> [CalEvent] {
        let gs = Dictionary(groups().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let del = deleted()
        var creators = [String: String]()
        for e in ofKind(9007).sorted(by: Derive.byTime) { if let h = e.tag("h"), creators[h] == nil { creators[h] = e.pubkey } }
        var byKey = [String: [NostrEvent]](), keyOrder = [String]()
        for e in events where e.kind == 31922 || e.kind == 31923 {
            guard let d = e.tag("d"), !d.isEmpty else { continue }
            let key = EventLinks.isD(d) ? "d:" + d : "\(e.kind):\(e.pubkey):\(d)"
            if byKey[key] == nil { keyOrder.append(key) }
            byKey[key, default: []].append(e)
        }
        var rsvps = [String: [String: (Rsvp, NostrEvent)]]()
        for e in ofKind(31925) {
            guard let a = e.tag("a"), let s = Rsvp(rawValue: e.tag("status") ?? "") else { continue }
            var m = rsvps[a] ?? [:]
            if let prev = m[e.pubkey], prev.1.createdAt > e.createdAt { continue }
            m[e.pubkey] = (s, e)
            rsvps[a] = m
        }
        var statusLabels = [String: [NostrEvent]]()
        for e in ofKind(1985) where e.tag("L") == EventLinks.statusNS { if let h = e.tag("h") { statusLabels[h, default: []].append(e) } }
        var out = [CalEvent]()
        for key in keyOrder {
            let sorted = byKey[key]!.sorted(by: Derive.byTime)
            var e = sorted.last!
            var creator = e.pubkey
            var hosts: Set<String> = [e.pubkey]
            let d = e.tag("d")!
            let isNew = key.hasPrefix("d:")
            let groupId: String
            if isNew { groupId = "ev-" + d } else {
                let h = e.tag("h") ?? ""
                groupId = h.isEmpty ? "ws-" + (d.hasPrefix("session-") ? String(d.dropFirst(8)) : d) : h
            }
            var hostVersions = sorted
            if isNew {
                creator = creators[groupId] ?? sorted.first!.pubkey
                hosts = Set([creator]).union(gs[groupId]?.admins ?? [])
                hostVersions = sorted.filter { hosts.contains($0.pubkey) }
                guard let last = hostVersions.last else { continue }
                e = last
            }
            let kind = isNew ? (sorted.first { $0.pubkey == creator }?.kind ?? e.kind) : e.kind
            let coord = "\(kind):\(creator):\(d)"
            if del.contains(coord) { continue }
            let allDay = e.kind == 31922
            guard let start = calTime(e.tag("start"), allDay: allDay) else { continue }
            var status: EventStatus = e.tag("status") == "cancelled" ? .cancelled : .scheduled
            let labels = (statusLabels[groupId] ?? []).filter { hosts.contains($0.pubkey) }.sorted(by: Derive.byTime)
            func says(_ l: NostrEvent, _ v: String) -> Bool { l.tags.contains { $0.count >= 2 && $0[0] == "l" && $0[1] == v } }
            if let last = labels.last, last.createdAt >= e.createdAt || status == .scheduled {
                status = says(last, "cancelled") ? .cancelled : .scheduled
            }
            var reason: String?
            if status == .cancelled, let l = labels.last(where: { says($0, "cancelled") }), !l.content.isEmpty { reason = l.content }
            let m = rsvps[coord] ?? [:]
            let title = (e.tag("title") ?? "").isEmpty ? ((e.tag("name") ?? "").isEmpty ? "Untitled" : e.tag("name")!) : e.tag("title")!
            var base = CalEvent(
                coord: coord, d: d, ev: e, title: title, description: e.content, location: e.tag("location"),
                allDay: allDay, start: start, end: calTime(e.tag("end"), allDay: allDay), groupId: groupId,
                links: e.tags.filter { $0.count >= 2 && $0[0] == "r" && $0[1].hasPrefix("https://") }.map { $0[1] },
                rsvps: m.mapValues { $0.0 }, rsvpEvents: m.mapValues { $0.1 }, tz: e.tag("start_tzid"), isNew: isNew,
                creator: creator, hosts: hosts, cover: (e.tag("image") ?? "").isEmpty ? nil : e.tag("image"),
                visibility: Visibility.of(e.tag("visibility")), slug: (e.tag("slug") ?? "").isEmpty ? nil : e.tag("slug"),
                status: status, statusReason: reason, versions: hostVersions)
            if isNew {
                base.goingKeys = goingList(base, EventLinks.people(inGroupSorted(groupId)))
            } else {
                base.goingKeys = m.filter { $0.value.0 == .accepted }.keys.sorted()
            }
            base.goingCount = base.goingKeys.count
            out.append(base)
        }
        // the channels showing each event's card: messages with its `a` tag or its URL, not deleted
        var byLink = [String: Int](), byCoord = [String: Int]()
        for (i, x) in out.enumerated() { byLink[x.d] = i; if let s = x.slug { byLink[s] = i }; byCoord[x.coord] = i }
        var channels = [Int: [String]]()
        for e in sortedEvents where e.kind == 9 && !del.contains(e.id) {
            guard let h = e.tag("h") else { continue }
            var found = [Int]()
            for c in EventLinks.coordsOf(e) { if let i = byCoord[c], !found.contains(i) { found.append(i) } }
            for l in EventLinks.linksIn(e.content, domain: ctx.domain) { if let i = byLink[l], !found.contains(i) { found.append(i) } }
            for i in found where out[i].groupId != h {
                if !(channels[i] ?? []).contains(h) { channels[i, default: []].append(h) }
            }
        }
        for (i, list) in channels { out[i].channels = list }
        return out.enumerated().sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }.map(\.element)
    }

    public func calEvent(_ coord: String) -> CalEvent? { calendar.first { $0.coord == coord } }
    public func eventByLink(_ link: String) -> CalEvent? { calendar.first { $0.d == link || $0.slug == link } }
    /// The event by coordinate or by its URL's last part.
    public func eventByKey(_ key: String) -> CalEvent? { calEvent(key) ?? eventByLink(key) }
    /// The event whose chat this group is.
    public func eventOfGroup(_ groupId: String) -> CalEvent? { calendar.first { $0.groupId == groupId } }
    public func eventURL(_ e: CalEvent) -> String { EventLinks.url(domain: ctx.domain, link: e.link) }

    /// Upcoming events (ending today or later), of one channel or of all.
    public func upcoming(_ channel: String? = nil, now: Int) -> [CalEvent] {
        let today = startOfDay(now)
        return calendar.filter { ($0.end ?? $0.start) >= today && (channel == nil || $0.channels.contains(channel!)) }
    }

    public func eventPeople(_ e: CalEvent) -> EventPeople { e.remote ? .empty : EventLinks.people(inGroupSorted(e.groupId)) }

    /// Its ticket types; the implicit free one when none is defined.
    public func tickets(_ e: CalEvent) -> [Ticket] {
        if e.remote { return [EventLinks.freeTicket(e.d)] }
        var latest = [String: NostrEvent](), order = [String]()
        for x in ofKind(30402) where x.tag("a") == e.coord && e.hosts.contains(x.pubkey) {
            guard let d = x.tag("d"), d.hasPrefix(e.d + ":") else { continue }
            if let had = latest[d], had.createdAt >= x.createdAt { continue }
            if latest[d] == nil { order.append(d) }
            latest[d] = x
        }
        let deletes = ofKind(5).filter { e.hosts.contains($0.pubkey) }
        func gone(_ d: String, _ at: Int) -> Bool {
            deletes.contains { x in x.createdAt >= at && x.tags.contains { $0.count >= 2 && $0[0] == "a" && $0[1].hasSuffix(":" + d) } }
        }
        var out = [Ticket]()
        for d in order {
            let x = latest[d]!
            if gone(d, x.createdAt) { continue }
            let q = Int(x.tag("quantity") ?? "")
            let title = (x.tag("title") ?? "").isEmpty ? "Ticket" : x.tag("title")!
            out.append(Ticket(d: d, id: String(d.dropFirst(e.d.count + 1)), title: title, summary: x.tag("summary") ?? "",
                              quantity: q.flatMap { $0 >= 0 ? $0 : nil }, closed: x.hasTag("closed"), prompt: x.tag("prompt") ?? "",
                              members: x.hasTag("members"), position: Int(x.tag("position") ?? "") ?? 0, ev: x))
        }
        if out.isEmpty { return [EventLinks.freeTicket(e.d)] }
        return out.sorted { $0.position != $1.position ? $0.position < $1.position : $0.title < $1.title }
    }

    public func myRsvp(_ e: CalEvent) -> Rsvp? { e.rsvps[me] }

    public func myState(_ e: CalEvent, _ people: EventPeople? = nil) -> MyState {
        let p = people ?? eventPeople(e)
        let rsvp = e.rsvps[me]
        if p.declined.contains(me) { return .declined }
        if p.holders[me] != nil { return rsvp == .tentative ? .maybe : rsvp == .declined ? .cant : .ticket }
        if let app = p.applications.first(where: { $0.pubkey == me }) { return app.waitlist ? .waitlist : .applied }
        switch rsvp {
        case .some(.accepted): return .ticket
        case .some(.tentative): return .maybe
        case .some(.declined): return .cant
        case .none: return e.hosts.contains(me) ? .host : MyState.none
        }
    }

    /// "Going" / "Hosting" / "Applied"… for rows and cards; nil when I said nothing.
    public func stateLabel(_ e: CalEvent) -> String? { e.isNew ? myState(e).label : e.rsvps[me]?.label }

    /// May I host it: its hosts, and the community's admins for events read from the relay.
    public func isHost(_ e: CalEvent) -> Bool { e.hosts.contains(me) || (isCommunityAdmin && !e.remote) }

    /// "Still going?": my RSVP predates a change of the date or the place.
    public func stillGoing(_ e: CalEvent) -> Bool {
        guard let mine = e.rsvpEvents[me], e.rsvps[me] != .declined else { return false }
        let said = mine.tag("e")
        guard let base = e.versions.first(where: { $0.id == said }) ?? e.versions.last(where: { $0.createdAt <= mine.createdAt }) else { return false }
        func key(_ v: NostrEvent) -> String { [v.tag("start") ?? "", v.tag("end") ?? "", v.tag("location") ?? ""].joined(separator: "|") }
        return key(base) != key(e.ev)
    }

    public func endOf(_ e: CalEvent) -> Int { e.end ?? e.start }
    public func isPast(_ e: CalEvent, now: Int) -> Bool { endOf(e) < startOfDay(now) }
    public func ended(_ e: CalEvent, now: Int) -> Bool { endOf(e) < now }
    /// Taking a place still makes sense: not cancelled, not over.
    public func isOpen(_ e: CalEvent, now: Int) -> Bool { e.status != .cancelled && !ended(e, now: now) }

    /// All events: one tab (of one channel's cards, or of all).
    public func eventsIn(_ tab: EventsTab, now: Int, channel: String? = nil) -> [CalEvent] {
        let list = calendar.filter { channel == nil || $0.channels.contains(channel!) }
        func mine(_ e: CalEvent) -> Bool { let s = myState(e); return s != .none && s != .declined && s != .cant }
        switch tab {
        case .past: return list.filter { isPast($0, now: now) }.reversed()
        case .upcoming: return list.filter { !isPast($0, now: now) }
        case .mine: return list.filter { !isPast($0, now: now) && mine($0) }
        case .hosting: return list.filter { !isPast($0, now: now) && $0.hosts.contains(me) }
        }
    }

    /// In the drawer: the Belfry events I host or have / ask a place at, upcoming and up to 30 days after.
    public func yourEvents(now: Int) -> [CalEvent] {
        let since = now - 30 * 86400
        let keep: Set<MyState> = [.host, .ticket, .maybe, .applied, .waitlist]
        return calendar.filter { $0.isNew && endOf($0) >= since && ($0.hosts.contains(me) || keep.contains(myState($0))) }
    }

    /// The `a` tags of the events a text links to (those this device knows).
    public func eventTagsFor(_ text: String, mainRelay: String) -> [Tag] {
        var out = [Tag]()
        for l in EventLinks.linksIn(text, domain: ctx.domain) {
            if let c = eventByLink(l)?.coord, !out.contains(where: { $0[1] == c }) { out.append(["a", c, mainRelay]) }
        }
        return out
    }

    /// Places already used for events: this channel's first (most recent first), then elsewhere.
    public func eventPlaces(_ channel: String) -> [String] {
        let recent = calendar.sorted { $0.ev.createdAt > $1.ev.createdAt }
        var out = [String]()
        for e in recent where e.channels.contains(channel) { if let l = e.location, !l.isEmpty, !out.contains(l) { out.append(l) } }
        for e in recent { if let l = e.location, !l.isEmpty, !out.contains(l) { out.append(l) } }
        return out
    }
}
