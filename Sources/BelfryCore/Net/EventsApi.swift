import Foundation

// Belfry events through the belfry's API (events.py; SPEC 19.18): `<api base>/events/<link>`
// (read), `/events/slug`, `PUT /events/<d>/slug`, `POST /events/<d>/join`, `/apply`, `/decide`,
// and co-host links (`POST /channel-invites` with `role: host`). Signed by the member (NIP-98).
// Failures are ApiErrors with fixed messages chosen by the server's `error` key.

public struct ApiTicket: Hashable, Sendable {
    public let d, id, title, summary: String
    public let quantity, left: Int?
    public let closed: Bool
    public let prompt: String
    public let members: Bool
    public let position: Int
    public let implicit: Bool
    public var ticket: Ticket {
        Ticket(d: d, id: id, title: title, summary: summary, quantity: quantity, closed: closed, prompt: prompt, members: members,
               position: position, implicit: implicit, ev: nil, apiLeft: left)
    }
}

public struct ApiMe: Hashable, Sendable {
    public let host: Bool
    public let ticket: String?
    public let applied, waitlist, declined: Bool
    public let rsvp: Rsvp?
    public let member: Bool
}

public struct ApiEvent: Hashable, Sendable {
    public let d, coord: String
    public let kind: Int
    public let group, link, url, title, description: String
    public let allDay: Bool
    public let start, end: String?
    public let tz, location: String
    public let online: Bool
    public let links: [String]
    public let cover: String?
    public let visibility: Visibility
    public let status: EventStatus
    public let statusReason: String
    /// (pubkey, name)
    public let hosts: [[String]]
    public let tickets: [ApiTicket]
    public let going: Int
    public let community: String
    public let me: ApiMe?

    /// The event in the app's own shape (for guests, and cards they get).
    public func calEvent(timeZone: TimeZone, me mine: String) -> CalEvent {
        let parts = coord.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let k = parts.first.flatMap { Int($0) } ?? kind
        let creator = parts.count > 1 ? parts[1] : ""
        let isAllDay = k == 31922
        func parse(_ v: String?) -> Int? {
            guard let v, !v.isEmpty else { return nil }
            if isAllDay {
                var c = Calendar(identifier: .gregorian)
                c.timeZone = timeZone
                let p = v.prefix(10).split(separator: "-").compactMap { Int($0) }
                guard p.count == 3 else { return nil }
                return c.date(from: DateComponents(year: p[0], month: p[1], day: p[2])).map { Int($0.timeIntervalSince1970) }
            }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: v) { return Int(d.timeIntervalSince1970) }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: v).map { Int($0.timeIntervalSince1970) }
        }
        let fake = NostrEvent(id: "api-" + d, pubkey: creator, createdAt: 0, kind: k, tags: [["d", d]], content: description)
        var e = CalEvent(coord: coord, d: d, ev: fake, title: title, description: description, location: location.isEmpty ? nil : location,
                         allDay: isAllDay, start: parse(start) ?? 0, end: parse(end), groupId: group, links: links,
                         rsvps: me?.rsvp.map { [mine: $0] } ?? [:], tz: tz.isEmpty ? nil : tz, isNew: true, creator: creator,
                         hosts: Set(hosts.compactMap(\.first)), cover: cover, visibility: visibility, slug: link != d ? link : nil,
                         status: status, statusReason: statusReason.isEmpty ? nil : statusReason, versions: [fake])
        e.remote = true
        e.goingCount = going
        return e
    }

    /// Where I stand as the belfry says it (guests; the API's `me`).
    public var myState: MyState {
        guard let m = me else { return .none }
        if m.declined { return .declined }
        if m.ticket != nil { return m.rsvp == .tentative ? .maybe : m.rsvp == .declined ? .cant : .ticket }
        if m.applied { return m.waitlist ? .waitlist : .applied }
        switch m.rsvp {
        case .some(.accepted): return .ticket
        case .some(.tentative): return .maybe
        case .some(.declined): return .cant
        case .none: return m.host ? .host : MyState.none
        }
    }
}

public struct SlugCheck: Hashable, Sendable { public let free: Bool; public let suggestion: String; public let problem: String? }

public extension BelfryAPI {
    internal var eventsBase: String { config.apiBase + "/events" }

    internal static func eventFail(_ a: Answer, _ fallback: String, _ own: [String: String] = [:]) -> ApiError {
        let code = a.error.isEmpty ? (a.status == 0 ? "network" : "http") : a.error
        return ApiError(code, a.status, own[code] ?? eventErrors[code] ?? fallback)
    }

    /// The event as the belfry tells it to me. Codes: `not_found`, `members_only`.
    func event(_ link: String) async throws -> ApiEvent {
        let a = try await signed(eventsBase + "/" + MailThreads.encodeURIComponent(link))
        if a.status == 403 { throw ApiError("members_only", 403, BelfryAPI.eventErrors["members_only"]!) }
        if a.status == 404 { throw ApiError("not_found", 404, BelfryAPI.eventErrors["not_found"]!) }
        guard a.ok, let b = a.body, let e = BelfryAPI.parseEvent(b) else { throw BelfryAPI.eventFail(a, "The event could not be read just now.") }
        return e
    }

    /// Is that custom URL free? EVENT: the event it is for (its own name counts as free).
    func slugCheck(_ name: String, event: String = "") async throws -> SlugCheck {
        let q = "name=" + MailThreads.encodeURIComponent(name) + (event.isEmpty ? "" : "&event=" + MailThreads.encodeURIComponent(event))
        let a = try await signed(eventsBase + "/slug?" + q)
        guard a.ok, let b = a.body else { throw BelfryAPI.eventFail(a, "Could not check the URL.") }
        return SlugCheck(free: b["free"] as? Bool ?? false, suggestion: b["suggestion"] as? String ?? name, problem: b["problem"] as? String)
    }

    /// A host sets the event's URL to /events/<slug>. Codes: `taken`, `invalid`, `not_host`.
    func claimSlug(d: String, slug: String) async throws {
        let a = try await signed(eventsBase + "/" + d + "/slug", method: "PUT", json: ["slug": slug])
        if !a.ok { throw BelfryAPI.eventFail(a, "That URL could not be set.") }
    }

    /// Take an open ticket (the belfry checks the places and issues it).
    func joinEvent(d: String, ticket: String) async throws {
        let a = try await signed(eventsBase + "/" + d + "/join", method: "POST", json: ["ticket": ticket])
        if !a.ok { throw BelfryAPI.eventFail(a, BelfryAPI.generic) }
    }

    /// A guest's application: their own signed 9021, which the belfry hands to the group.
    func applyEvent(d: String, ticket: String, request: NostrEvent) async throws {
        let req = (JSON.parse(request.json) as? [String: Any]) ?? [:]
        let a = try await signed(eventsBase + "/" + d + "/apply", method: "POST", json: ["ticket": ticket, "request": req])
        if !a.ok { throw BelfryAPI.eventFail(a, "Your application did not go through. Try again.") }
    }

    /// A host who can't moderate on the relay (a guest co-host): the belfry decides for them.
    func decideEvent(d: String, pubkey: String, approve: Bool, ticket: String?) async throws {
        var body: [String: Any] = ["pubkey": pubkey, "action": approve ? "approve" : "decline"]
        if let ticket { body["ticket"] = ticket }
        let a = try await signed(eventsBase + "/" + d + "/decide", method: "POST", json: body)
        if !a.ok { throw BelfryAPI.eventFail(a, "That did not work.") }
    }

    /// A co-host invitation link: for one person, for a day. Whoever opens it becomes a host.
    func coHostLink(group: String) async throws -> String {
        let a = try await signed(config.channelInvites, method: "POST", json: ["channel": group, "role": "host", "people": 1, "link_days": 1])
        guard a.ok, let url = a.body?["url"] as? String, url.hasPrefix("https://") else {
            throw BelfryAPI.eventFail(a, "The link could not be made.", ["invalid": "This event can’t have co-host links.", "not_allowed": "You can’t invite here.", "guest": "Guests can’t make co-host links."])
        }
        return url
    }

    /// The API's answer, or nil when it is not an event. Text fields cut to sane lengths.
    static func parseEvent(_ o: [String: Any]) -> ApiEvent? {
        guard let d = o["d"] as? String, let coord = o["coord"] as? String, let group = o["group"] as? String else { return nil }
        func s(_ k: String) -> String? { o[k] as? String }
        var me: ApiMe?
        if let m = o["me"] as? [String: Any] {
            me = ApiMe(host: m["host"] as? Bool ?? false, ticket: m["ticket"] as? String, applied: m["applied"] as? Bool ?? false,
                       waitlist: m["waitlist"] as? Bool ?? false, declined: m["declined"] as? Bool ?? false,
                       rsvp: Rsvp(rawValue: m["rsvp"] as? String ?? ""), member: m["member"] as? Bool ?? false)
        }
        let tickets: [ApiTicket] = (o["tickets"] as? [[String: Any]] ?? []).compactMap { x in
            guard let td = x["d"] as? String else { return nil }
            let id = x["id"] as? String ?? String(td.split(separator: ":", maxSplits: 1).last ?? "")
            return ApiTicket(d: td, id: id, title: (x["title"] as? String ?? "Ticket").sliceUnits(120), summary: (x["summary"] as? String ?? "").sliceUnits(300),
                             quantity: int(x["quantity"]), left: int(x["left"]), closed: x["closed"] as? Bool ?? false,
                             prompt: (x["prompt"] as? String ?? "").sliceUnits(500), members: x["members"] as? Bool ?? false,
                             position: int(x["position"]) ?? 0, implicit: x["implicit"] as? Bool ?? false)
        }
        let hosts: [[String]] = (o["hosts"] as? [[String: Any]] ?? []).compactMap { h in
            guard let pk = h["pubkey"] as? String else { return nil }
            return [pk, (h["name"] as? String ?? "").sliceUnits(100)]
        }
        return ApiEvent(d: d, coord: coord, kind: int(o["kind"]) ?? 31923, group: group, link: s("link") ?? d, url: s("url") ?? "",
                        title: (s("title") ?? "Untitled").sliceUnits(200), description: (s("description") ?? "").sliceUnits(20_000),
                        allDay: o["all_day"] as? Bool ?? false, start: s("start"), end: s("end"), tz: s("tz") ?? "",
                        location: (s("location") ?? "").sliceUnits(300), online: o["online"] as? Bool ?? false,
                        links: (o["links"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil } },
                        cover: s("cover").flatMap { $0.hasPrefix("https://") ? $0 : nil }, visibility: Visibility.of(s("visibility")),
                        status: s("status") == "cancelled" ? .cancelled : .scheduled, statusReason: (s("status_reason") ?? "").sliceUnits(500),
                        hosts: hosts, tickets: tickets, going: int(o["going"]) ?? 0, community: (s("community") ?? "").sliceUnits(100), me: me)
    }

    static let eventErrors = [
        "not_found": "There is no such event here.",
        "members_only": "This event is for members.",
        "too_many": "Too many requests for now. Try again in a minute.",
        "cancelled": "This event is cancelled.",
        "ended": "This event is over.",
        "no_ticket": "Pick one of the event’s tickets.",
        "needs_application": "This ticket takes an application.",
        "full": "This ticket is full: join the waitlist.",
        "use_join": "This ticket is open: take it.",
        "name_needed": "Tell us your name.",
        "email_needed": "An application needs your e-mail address.",
        "member_email": "This address belongs to a member: sign in with it instead.",
        "publish_yourself": "That did not work. Try again.",
        "request_needed": "Your application did not go through. Try again.",
        "bad_request": "Your application did not go through. Try again.",
        "relay": "The event could not be reached. Try again.",
        "failed": "That did not work just now. Try again.",
        "not_host": "Only the event’s hosts can do this.",
        "taken": "Another event has that URL.",
        "invalid": "That URL can’t be used.",
        "unsupported": "This belfry does not have event guests yet.",
        "unauthorized": "Your session was not accepted. Sign in again.",
        "no_pass": "Only members can do this.",
        "network": "No connection to the belfry.",
    ]
}
