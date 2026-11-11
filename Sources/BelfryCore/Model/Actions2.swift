import Foundation

// The events of the actions added since milestone 1 (SPEC 19): edits, pins, to-dos, pods,
// proposals, drop links, profiles, labels, inbox cards, Belfry events. Pure: random ids and the
// time come in as parameters. Port of the web chat's actions.ts / events.ts (Android Actions.kt).

public struct PodAccess: Hashable, Sendable {
    public var closed = false
    public var prompt = ""
    public init(closed: Bool = false, prompt: String = "") { self.closed = closed; self.prompt = prompt }
}

public struct NewProposal: Hashable, Sendable {
    public var title: String
    public var summary = ""
    public var text = ""
    public var status: ProposalStatus = .draft
    public init(title: String, summary: String = "", text: String = "", status: ProposalStatus = .draft) {
        self.title = title; self.summary = summary; self.text = text; self.status = status
    }
}

/// What the event form says (make or edit).
public struct EventForm: Hashable, Sendable {
    public var title: String
    public var description = ""
    public var allDay = false
    /// Timed: Unix seconds.
    public var start = 0
    public var end: Int?
    /// All day: ISO dates.
    public var startDate = ""
    public var endDate: String?
    /// IANA zone of the times.
    public var tz = "UTC"
    public var location = ""
    public var online = ""
    public var visibility: Visibility = .members
    public var slug = ""
    public var cover: String?
    /// Making an event: coming takes an application with this question (one 30402 ticket).
    public var applicationPrompt: String?
    public init(title: String) { self.title = title }
}

public struct TicketForm: Hashable, Sendable {
    public var id: String?
    public var title: String
    public var summary = ""
    /// Digits, or "" for no limit.
    public var quantity = ""
    public var closed = false
    public var prompt = ""
    public var members = false
    public var position = 0
    public init(id: String? = nil, title: String) { self.id = id; self.title = title }
}

public extension Actions {
    static let defaultPrompt = "Why do you want to join, and what would you bring?"
    static let suggestedLabels = ["organiser", "speaker", "volunteer", "maintainer", "host", "newcomer"]

    // ---- messages ----

    /// A message with the `a` tags of the events its text links to (SPEC 19.18 cards).
    static func postMessage(_ group: String, text: String, topic: String?, announce: Bool, eventTags: [Tag]) -> Draft {
        var d = postMessage(group, text: text, topic: topic, announce: announce)
        d.tags += eventTags
        return d
    }

    /// Edit my own message or thread reply (SPEC 19.1): kind 1010 naming it, with the new text;
    /// its photos, the topic it was sent in and an announcement mark stay.
    static func editMessage(_ group: String, _ m: Message, text: String) -> Draft {
        let typed = Set(Topics.hashtags(m.text))
        let imeta = m.ev.tags.filter { $0.first == "imeta" }
        let urls = imeta.compactMap { t in t.first(where: { $0.hasPrefix("url ") }).map { String($0.dropFirst(4)) } }.filter { !$0.isEmpty }
        var topics = [String]()
        for t in m.ev.tags where t.count >= 2 && t[0] == "t" && !t[1].isEmpty {
            let n = Topics.norm(t[1])
            if !typed.contains(n), !topics.contains(n) { topics.append(n) }
        }
        for h in Topics.hashtags(text) where !topics.contains(h) { topics.append(h) }
        let content = ([text] + urls).filter { !$0.isEmpty }.joined(separator: "\n")
        let tags: [Tag] = [["h", group], ["e", m.ev.id], ["k", String(m.ev.kind)]] + imeta + topics.map { ["t", $0] } + Mentions.tags(text)
        return Draft(kind: Derive.editKind, content: content, tags: tags)
    }

    /// Pin a message as the channel's notice, or unpin it (SPEC 19.10).
    static func pinMessage(_ group: String, messageId: String, pin: Bool) -> Draft {
        Draft(kind: 1985, tags: [["h", group], ["L", Derive.pinNS], ["l", pin ? "pinned" : "unpinned", Derive.pinNS], ["e", messageId]])
    }

    /// One tap adds, a second removes; nil when my reaction is still in the outbox.
    static func toggleReaction(_ group: String, messageId: String, author: String, emoji: String, mine: String?, minePending: Bool) -> Draft? {
        if let mine { return minePending ? nil : unreact(group, reactionId: mine) }
        return react(group, messageId: messageId, author: author, emoji: emoji)
    }

    // ---- pods ----

    static func newPodId(_ name: String, random: (Int) -> String = { Crypto.random($0).hex }) -> String {
        "pod-" + slug(name, random: { random(3) }).sliceUnits(24) + "-" + random(2)
    }

    static func accessTags(_ a: PodAccess) -> [Tag] {
        if a.closed {
            let p = a.prompt.jsTrim()
            return [["closed"], ["prompt", p.isEmpty ? defaultPrompt : p]]
        }
        return [["open"]]
    }

    /// A pod: its own group `pod-…`, announced in its parent by a post with a `pod` tag.
    static func createPod(id: String, name: String, about: String, parent: String = generalId, access: PodAccess = PodAccess()) -> [Draft] {
        [Draft(kind: 9007, tags: [["h", id]]),
         Draft(kind: 9002, tags: [["h", id], ["name", name], ["about", about]] + accessTags(access)),
         Draft(kind: 9, content: "⬡ New pod: \(name)" + (about.isEmpty ? "" : " · \(about)"), tags: [["h", parent], ["pod", id]])]
    }

    static func editPod(_ id: String, name: String, about: String, access: PodAccess) -> Draft {
        Draft(kind: 9002, tags: [["h", id], ["name", name], ["about", about]] + accessTags(access))
    }

    static func admit(_ id: String, pubkey: String) -> Draft { Draft(kind: 9000, tags: [["h", id], ["p", pubkey, "member"]]) }
    static func decline(_ id: String, pubkey: String) -> Draft { Draft(kind: 9001, tags: [["h", id], ["p", pubkey]]) }

    // ---- channel settings ----

    /// Close or reopen an e-mail card.
    static func setCardStatus(_ group: String, card: String, closed: Bool) -> Draft {
        Draft(kind: 1985, tags: [["h", group], ["L", Derive.inboxNS], ["l", closed ? "closed" : "open", Derive.inboxNS], ["e", card]])
    }

    /// Who has an e-mail card; ASSIGNEE "" = nobody.
    static func assignCard(_ group: String, card: String, assignee: String) -> Draft {
        Draft(kind: 1985, tags: [["h", group], ["L", Derive.inboxNS], ["l", "assigned", Derive.inboxNS], ["e", card]] + (assignee.isEmpty ? [] : [["p", assignee]]))
    }

    /// A channel's pinned topics: one label event with the whole list (latest wins).
    static func setTopics(_ group: String, _ list: [String]) -> Draft {
        var seen = [String]()
        for t in list.map(Topics.norm) where !seen.contains(t) { seen.append(t) }
        return Draft(kind: 1985, tags: [["h", group], ["L", "#t"]] + seen.map { ["l", $0, "#t"] })
    }

    static func pinTopic(_ group: String, pinned: [String], topic: String, pin: Bool) -> Draft {
        let t = Topics.norm(topic)
        return setTopics(group, pin ? pinned + [t] : pinned.filter { $0 != t })
    }

    static func setMemberLabels(_ group: String, pubkey: String, labels: [String]) -> Draft {
        Draft(kind: 1985, tags: [["h", group], ["L", Derive.labelNS]] + labels.map { ["l", $0, Derive.labelNS] } + [["p", pubkey]])
    }

    // ---- to-dos (tasklist.sh) ----

    static func taskTags(_ group: String) -> [Tag] { [["t", Derive.listIdFor(group)], ["h", group]] }

    /// A to-do; FROM = the message it was made from (a `q` tag).
    static func addTask(_ group: String, title: String, from: String? = nil) -> Draft {
        Draft(kind: 2100, content: title.sliceUnits(300), tags: taskTags(group) + (from.map { [["q", $0]] } ?? []))
    }

    /// ACTION: claim | unclaim | done | undone | delete
    static func taskAction(_ group: String, taskId: String, action: String) -> Draft {
        Draft(kind: 2101, tags: [["e", taskId], ["action", action]] + taskTags(group))
    }

    static func commentTask(_ group: String, taskId: String, text: String) -> Draft {
        Draft(kind: 2103, content: text.sliceUnits(2000), tags: [["e", taskId]] + taskTags(group))
    }

    // ---- proposals ----

    static func proposalTags(d: String, group: String, title: String, summary: String, version: Int, status: ProposalStatus, groupsRelay: String, now: Int) -> [Tag] {
        [["d", d], ["title", title], ["summary", summary], ["t", "proposal"], ["h", group, groupsRelay],
         ["version", String(version)], ["status", status.rawValue], ["published_at", String(now)]]
    }

    static func openVote(_ group: String, coord: String, title: String, version: Int) -> Draft {
        Draft(kind: 1068, content: "\(title) (version \(version)): do you approve?",
              tags: [["h", group], ["a", coord], ["version", String(version)], ["polltype", "singlechoice"]] + Proposal.voteOptions.map { ["option", $0.id, $0.label] })
    }

    /// A proposal: its own chat, its text (version 1) and a card in the parent. Returns the chat's id and the drafts.
    static func createProposal(_ n: NewProposal, parent: String, me: String, groupsRelay: String, mainRelay: String, now: Int, x: String = Crypto.random(3).hex) -> (String, [Draft]) {
        let group = "prop-" + slug(n.title).sliceUnits(24) + "-" + x
        let d = "proposal-" + x
        let coord = "30023:\(me):\(d)"
        var out = createChannel(id: group, name: n.title, about: n.summary.isEmpty ? "Proposal" : n.summary)
        out.append(Draft(.main, kind: 30023, content: n.text, tags: proposalTags(d: d, group: group, title: n.title, summary: n.summary, version: 1, status: n.status, groupsRelay: groupsRelay, now: now)))
        out.append(Draft(kind: 9, content: "📝 Proposal: \(n.title)" + (n.summary.isEmpty ? "" : " · \(n.summary)"), tags: [["h", parent], ["proposal", group], ["a", coord, mainRelay]]))
        if n.status == .voting { out.append(openVote(group, coord: coord, title: n.title, version: 1)) }
        return (group, out)
    }

    /// A new version: the text replaced (same d, version + 1), a note in its chat, a new poll while under vote.
    static func reviseProposal(_ p: Proposal, title: String, summary: String, text: String, note: String, groupsRelay: String, mainRelay: String, now: Int) -> [Draft] {
        let version = p.version + 1
        var out = [Draft(.main, kind: 30023, content: text, tags: proposalTags(d: p.d, group: p.groupId, title: title, summary: summary, version: version, status: p.status, groupsRelay: groupsRelay, now: now))]
        let nt = note.jsTrim()
        out.append(Draft(kind: 9, content: "📝 Version \(version)" + (nt.isEmpty ? "" : ": \(nt)"), tags: [["h", p.groupId], ["a", p.coord, mainRelay], ["version", String(version)]]))
        if p.status == .voting { out.append(openVote(p.groupId, coord: p.coord, title: title, version: version)) }
        return out
    }

    static func setProposalStatus(_ p: Proposal, _ status: ProposalStatus) -> [Draft] {
        var out = [Draft(kind: 1985, tags: [["h", p.groupId], ["L", Derive.proposalNS], ["l", status.rawValue, Derive.proposalNS], ["a", p.coord]])]
        if status == .voting, p.poll == nil || p.poll!.version != p.version { out.append(openVote(p.groupId, coord: p.coord, title: p.title, version: p.version)) }
        return out
    }

    /// nil when there is no poll to answer.
    static func vote(_ p: Proposal, option: String) -> Draft? {
        guard let poll = p.poll else { return nil }
        return Draft(kind: 1018, tags: [["h", p.groupId], ["e", poll.ev.id], ["response", option]])
    }

    // ---- drop box links ----

    /// A fresh link token: 16 random bytes, base64url without padding.
    static func newDropToken() -> String { Crypto.base64url(Crypto.random(16)) }

    /// DAYS 1, 7 or 30; LOGIN: uploaders must be signed in.
    static func createDropLink(_ group: String, days: Int, login: Bool, now: Int, token: String = newDropToken()) -> (String, Draft) {
        let expires = now + days * 86400
        return (token, Draft(kind: 30078, tags: [["d", "drop:" + token], ["h", group], ["expiration", String(expires)]] + (login ? [["login"]] : []) +
                             [["alt", "Drop box link: upload photos and files to this channel"]]))
    }

    /// End a drop box link (kind 5 by its author: the event and its address).
    static func endDropLink(_ l: DropLink) -> Draft {
        Draft(kind: 5, tags: [["h", l.groupId], ["e", l.ev.id], ["a", "30078:\(l.ev.pubkey):drop:\(l.token)"]])
    }

    // ---- my profile ----

    /// My tags and place (kind 30078, d = belfry:profile, on the community relay).
    static func saveExtras(tags: [String], share: Share, place: Place?) -> Draft {
        Draft(.main, kind: 30078, content: People.extrasContent(tags: tags, share: share, place: place), tags: [["d", Derive.profileD]])
    }

    /// Name and about in my kind 0, the rest of it (CURRENT) kept.
    static func saveProfile(current: [String: Any], name: String, about: String, nip05: String? = nil, picture: String? = nil) -> Draft {
        var o = current
        let n = name.jsTrim().sliceUnits(100)
        o["name"] = n
        o["display_name"] = n
        o["about"] = about.jsTrim().sliceUnits(2000)
        if let nip05, !nip05.isEmpty { o["nip05"] = nip05 }
        if let picture, !picture.isEmpty { o["picture"] = picture }
        return Draft(.main, kind: 0, content: JSON.encode(o), tags: [])
    }

    // ---- older events (ws- chats) ----

    /// [eventPending]: the event itself is still in my outbox (no `e` tag then).
    static func rsvpLegacy(_ e: CalEvent, _ status: Rsvp, me: String, eventPending: Bool = false) -> Draft {
        EventActions.rsvp(e, status, me: me, eventPending: eventPending)
    }

    static func deleteEvent(_ e: CalEvent) -> Draft { Draft(.main, kind: 5, tags: [["a", e.coord], ["e", e.ev.id]]) }

    static func meetingLabel(_ url: String) -> String {
        let h = URL(string: url.jsTrim())?.host ?? ""
        if h.hasSuffix("meet.google.com") { return "Google Meet" }
        if h == "zoom.us" || h.hasSuffix(".zoom.us") { return "Zoom" }
        if h.hasSuffix("jit.si") || h.contains("jitsi") { return "Jitsi" }
        if h.hasSuffix("teams.microsoft.com") || h.hasSuffix("teams.live.com") { return "Teams" }
        return h.isEmpty ? "Online" : h
    }

    /// A video call link anyone can open straight away: Jitsi Meet.
    static func jitsiLink(_ title: String, random: (Int) -> String = { Crypto.random($0).hex }) -> String {
        let s = slug(title, random: { random(3) })
        return "https://meet.jit.si/" + (s.hasPrefix("channel-") ? "meeting" : s) + "-" + random(5)
    }
}

/// Belfry events (SPEC 19.18).
public enum EventActions {
    static func versionTags(_ d: String, _ n: EventForm, groupsRelay: String, extra: [Tag] = []) -> (Int, [Tag]) {
        var tags: [Tag] = [["d", d], ["title", n.title.jsTrim()], ["h", "ev-" + d, groupsRelay], ["visibility", n.visibility.rawValue]]
        if n.allDay {
            tags.append(["start", String(n.startDate.prefix(10))])
            if let e = n.endDate, !e.isEmpty { tags.append(["end", String(e.prefix(10))]) }
        } else {
            tags.append(["start", String(n.start)]); tags.append(["start_tzid", n.tz])
            if let e = n.end { tags.append(["end", String(e)]); tags.append(["end_tzid", n.tz]) }
        }
        let place = n.location.jsTrim()
        if !place.isEmpty { tags.append(["location", place]) }
        let online = n.online.jsTrim()
        if online.hasPrefix("https://") { tags.append(["r", online]) }
        if let c = n.cover, !c.isEmpty { tags.append(["image", c]) }
        if !n.slug.isEmpty { tags.append(["slug", n.slug]) }
        return (n.allDay ? 31922 : 31923, tags + extra)
    }

    static func about(_ description: String) -> String {
        let a = (description.components(separatedBy: "\n").first ?? "").sliceUnits(200)
        return a.isEmpty ? "The event’s chat" : a
    }

    /// A new event: its group (ev-<d>, me as creator), then the NIP-52 event; with an application
    /// question, one ticket that takes applications (and the group closed). No post in any channel.
    public static func create(_ n: EventForm, d: String, me: String, groupsRelay: String, mainRelay: String, ticketId: String = Crypto.random(3).hex) -> [Draft] {
        let group = "ev-" + d
        let closed = n.applicationPrompt != nil
        var out = [Draft(kind: 9007, tags: [["h", group]])]
        out.append(Draft(kind: 9002, tags: [["h", group], ["name", n.title.jsTrim()], ["about", about(n.description)]] +
                         ((n.cover ?? "").isEmpty ? [] : [["picture", n.cover!]]) + [[closed ? "closed" : "open"]]))
        let (kind, tags) = versionTags(d, n, groupsRelay: groupsRelay)
        out.append(Draft(.main, kind: kind, content: n.description, tags: tags))
        if closed {
            var t = TicketForm(id: ticketId, title: "Application")
            t.closed = true
            t.prompt = n.applicationPrompt ?? ""
            t.position = 1
            out.append(ticketDraft(d, coord: "\(kind):\(me):\(d)", group: group, t, mainRelay: mainRelay))
        }
        return out
    }

    /// A host's new version (rule B), and the group's name / picture when they changed.
    public static func edit(_ e: CalEvent, _ n: EventForm, group g: Group?, groupsRelay: String) -> [Draft] {
        let (kind, tags) = versionTags(e.d, n, groupsRelay: groupsRelay, extra: e.status == .cancelled ? [["status", "cancelled"]] : [])
        var out = [Draft(.main, kind: kind, content: n.description, tags: tags)]
        if let g, g.name != n.title.jsTrim() || (!(n.cover ?? "").isEmpty && g.picture != n.cover) {
            out.append(Draft(kind: 9002, tags: [["h", e.groupId], ["name", n.title.jsTrim()], ["about", g.about]] + ((n.cover ?? "").isEmpty ? [] : [["picture", n.cover!]])))
        }
        return out
    }

    /// Cancel (with a line to the guests) or reopen: a label in the group and a new version.
    public static func setStatus(_ e: CalEvent, _ status: EventStatus, reason: String = "") -> [Draft] {
        let tags = e.ev.tags.filter { $0.first != "status" && $0.first != "client" }
        return [Draft(kind: 1985, content: reason.sliceUnits(500), tags: [["h", e.groupId], ["L", EventLinks.statusNS], ["l", status.rawValue, EventLinks.statusNS], ["a", e.coord]]),
                Draft(.main, kind: e.ev.kind, content: e.ev.content, tags: status == .cancelled ? tags + [["status", "cancelled"]] : tags)]
    }

    static func ticketDraft(_ d: String, coord: String, group: String, _ t: TicketForm, mainRelay: String) -> Draft {
        let id = t.id ?? Crypto.random(3).hex
        let title = t.title.jsTrim()
        var tags: [Tag] = [["d", "\(d):\(id)"], ["a", coord, mainRelay], ["h", group], ["title", title.isEmpty ? "Ticket" : title], ["t", "ticket"], ["position", String(t.position)]]
        let summary = t.summary.jsTrim()
        if !summary.isEmpty { tags.append(["summary", summary]) }
        let q = t.quantity.jsTrim()
        if !q.isEmpty, q.allSatisfy(\.isASCII), q.allSatisfy(\.isNumber) { tags.append(["quantity", q]) }
        if t.closed {
            let p = t.prompt.jsTrim()
            tags.append(["closed"]); tags.append(["prompt", p.isEmpty ? "Why would you like to come?" : p])
        }
        if t.members { tags.append(["members"]) }
        return Draft(.main, kind: 30402, content: summary, tags: tags)
    }

    /// Save a ticket type; a ticket that takes applications closes the event's group.
    public static func saveTicket(_ e: CalEvent, _ t: TicketForm, existing: [Ticket], group g: Group?, mainRelay: String, newId: String = Crypto.random(3).hex) -> [Draft] {
        var form = t
        if form.id == nil { form.id = newId }
        var out = [ticketDraft(e.d, coord: e.coord, group: e.groupId, form, mainRelay: mainRelay)]
        let closing = form.closed || existing.contains { $0.closed && !$0.implicit && $0.id != form.id }
        if let g, g.closed != closing {
            out.append(Draft(kind: 9002, tags: [["h", e.groupId], ["name", g.name], ["about", g.about], [closing ? "closed" : "open"]]))
        }
        return out
    }

    public static func deleteTicket(_ t: Ticket) -> Draft? {
        guard let x = t.ev else { return nil }
        return Draft(.main, kind: 5, tags: [["a", "30402:\(x.pubkey):\(t.d)"], ["e", x.id]])
    }

    /// RSVP. A member's goes on the community relay; a guest's (or one for an event read from the
    /// API) on the groups relay in the event's group (ONGROUPS).
    public static func rsvp(_ e: CalEvent, _ status: Rsvp, me: String, ticketD: String? = nil, onGroups: Bool = false, eventPending: Bool = false) -> Draft {
        let parts = e.coord.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let author = parts.count > 1 ? parts[1] : ""
        let d = parts.count > 2 ? parts[2...].joined(separator: ":") : ""
        var tags: [Tag] = [["d", String(Crypto.sha256("\(me):\(author):\(d)").hex.prefix(30))], ["a", e.coord]]
        if !eventPending && !e.remote { tags.append(["e", e.ev.id]) }
        tags.append(["status", status.rawValue]); tags.append(["p", author])
        if let t = ticketD { tags.append(["ticket", t]) }
        if onGroups { tags.append(["h", e.groupId]) }
        return Draft(onGroups ? .groups : .main, kind: 31925, tags: tags)
    }

    /// An application (or a place on the waitlist): kind 9021 in the event's group.
    public static func apply(_ e: CalEvent, _ t: Ticket, answer: String, waitlist: Bool) -> Draft {
        Draft(kind: 9021, content: answer.sliceUnits(2000), tags: [["h", e.groupId], ["ticket", t.d]] + (waitlist ? [["waitlist"]] : []))
    }

    public static func withdraw(_ e: CalEvent) -> Draft { Draft(kind: 9022, tags: [["h", e.groupId]]) }

    /// A host approves (a 9000 with `ticket`) or declines (9001).
    public static func decide(_ e: CalEvent, pubkey: String, approve: Bool, ticketD: String? = nil, application: NostrEvent? = nil) -> Draft {
        if !approve { return Draft(kind: 9001, tags: [["h", e.groupId], ["p", pubkey]]) }
        return Draft(kind: 9000, tags: [["h", e.groupId], ["p", pubkey, "member"], ["ticket", ticketD ?? e.d + ":free"], ["paid", "free"], ["a", e.coord]] +
                     (application.map { [["e", $0.id]] } ?? []))
    }

    /// Make someone a co-host: an admin of the event's group.
    public static func addCoHost(_ e: CalEvent, pubkey: String) -> Draft { Draft(kind: 9000, tags: [["h", e.groupId], ["p", pubkey, "admin"]]) }
}
