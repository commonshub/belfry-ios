import BelfryCore
import Foundation

// Belfry events (SPEC 19.18): make / edit, the URL, status, tickets, take / apply / withdraw,
// decide, co-hosts, and events read through the belfry's API (guests; cached a minute).

extension AppModel {
    /// A new event: its group and NIP-52 event (and an application ticket); then its URL. Returns its d.
    func createEvent(_ form: EventForm) async -> (String?, String?) {
        let d = EventLinks.newD(now: .now)
        for dr in EventActions.create(form, d: d, me: me, groupsRelay: config.groupsRelay, mainRelay: config.mainRelay) { engine?.enqueue(dr) }
        if !form.slug.isEmpty, engine?.localOnly == false {
            do { try await api.claimSlug(d: d, slug: form.slug) } catch let e as ApiError { return (d, e.message) } catch {}
        }
        return (d, nil)
    }

    /// A host's new version, its group's name / picture when they changed, and its URL.
    func editEvent(_ e: CalEvent, _ form: EventForm) async -> String? {
        for dr in EventActions.edit(e, form, group: group(e.groupId), groupsRelay: config.groupsRelay) { engine?.enqueue(dr) }
        if form.slug != (e.slug ?? ""), !form.slug.isEmpty, engine?.localOnly == false {
            do { try await api.claimSlug(d: e.d, slug: form.slug) } catch let x as ApiError { return x.message } catch {}
        }
        return nil
    }

    /// A picture on the file server (resized before); nil in the demo or when it fails.
    func uploadImage(_ data: Data, name: String) async -> String? {
        guard let engine, !engine.localOnly else { return nil }
        return try? await engine.upload(data, name: name, mime: "image/jpeg", sha: Crypto.sha256(data).hex)
    }

    func setEventStatus(_ e: CalEvent, _ s: EventStatus, reason: String = "") {
        for dr in EventActions.setStatus(e, s, reason: reason) { engine?.enqueue(dr) }
    }

    func deleteEvent(_ e: CalEvent) { engine?.enqueue(Actions.deleteEvent(e)) }

    func saveTicket(_ e: CalEvent, _ t: TicketForm) {
        for dr in EventActions.saveTicket(e, t, existing: derive.tickets(e), group: group(e.groupId), mainRelay: config.mainRelay) { engine?.enqueue(dr) }
    }

    func deleteTicket(_ t: Ticket) { if let dr = EventActions.deleteTicket(t) { engine?.enqueue(dr) } }

    /// Take an open ticket: a member's implicit ticket is an RSVP; others go through the belfry.
    func takeTicket(_ e: CalEvent, _ t: Ticket) async -> String? {
        let d = derive
        if t.implicit && !d.amGuest && !e.remote { rsvp(e, .accepted); return nil }
        if engine?.localOnly != false {
            // demo: the groups key issues it, as POST /events/<d>/join does
            let k = Demo.signer("groups")
            if let ev = try? k.signNow(EventTemplate(kind: 9000, tags: [["h", e.groupId], ["p", me, "member"], ["ticket", t.d], ["paid", "free"], ["a", e.coord]], createdAt: .now)) {
                engine?.add([ev], verify: false)
            }
            return nil
        }
        do { try await api.joinEvent(d: e.d, ticket: t.d); await refresh(); return nil }
        catch let x as ApiError { return x.message } catch { return BelfryAPI.generic }
    }

    /// Apply (or join the waitlist): a member sends the 9021; a guest signs it and hands it in.
    func applyTicket(_ e: CalEvent, _ t: Ticket, answer: String, waitlist: Bool) async -> String? {
        let draft = EventActions.apply(e, t, answer: answer, waitlist: waitlist)
        if !derive.amGuest && !e.remote { engine?.enqueue(draft); return nil }
        guard let engine else { return "Not signed in." }
        do {
            let ev = try await engine.signer.sign(EventTemplate(kind: draft.kind, content: draft.content, tags: draft.tags + [SyncEngine.clientTag], createdAt: .now))
            try await api.applyEvent(d: e.d, ticket: t.d, request: ev)
            remoteEvents[e.link] = nil
            return nil
        } catch let x as ApiError { return x.message } catch { return "Your application did not go through. Try again." }
    }

    func withdraw(_ e: CalEvent) { engine?.enqueue(EventActions.withdraw(e)) }

    /// A host approves or declines: on the relay as a member host, through the belfry as a guest host.
    func decide(_ e: CalEvent, _ pk: String, approve: Bool, ticket: String?, application: NostrEvent?) async -> String? {
        if !derive.amGuest || engine?.localOnly != false {
            engine?.enqueue(EventActions.decide(e, pubkey: pk, approve: approve, ticketD: ticket, application: application))
            return nil
        }
        do { try await api.decideEvent(d: e.d, pubkey: pk, approve: approve, ticket: ticket); return nil }
        catch let x as ApiError { return x.message } catch { return BelfryAPI.generic }
    }

    func addCoHost(_ e: CalEvent, _ pk: String) { engine?.enqueue(EventActions.addCoHost(e, pubkey: pk)) }

    func coHostLink(_ e: CalEvent) async -> Result<String, ApiError> {
        if engine?.localOnly != false { return .success("https://chat.\(config.domain)/join/democohostlink0123456789") }
        do { return .success(try await api.coHostLink(group: e.groupId)) }
        catch let x as ApiError { return .failure(x) } catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    func slugCheck(_ name: String, event: String) async -> SlugCheck? {
        if let p = EventLinks.slugProblem(name) { return SlugCheck(free: false, suggestion: name, problem: p) }
        if engine?.localOnly != false {
            let taken = derive.calendar.contains { $0.slug == name && $0.d != event }
            return SlugCheck(free: !taken, suggestion: name, problem: taken ? "Another event has that URL." : nil)
        }
        return try? await api.slugCheck(name, event: event)
    }

    /// An event read through the belfry (a guest can't read the community relay), cached a minute.
    func remoteEvent(_ link: String) async -> Result<ApiEvent, ApiError> {
        if let c = remoteEvents[link], Date().timeIntervalSince(c.at) < 60 { return .success(c.event) }
        if engine?.localOnly != false { return .failure(ApiError("not_found", 404, "There is no such event here.")) }
        do {
            let e = try await api.event(link)
            remoteEvents[link] = (Date(), e)
            return .success(e)
        } catch let x as ApiError { return .failure(x) } catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    /// An event address opened from outside (https://chat.<domain>/events/<link>): only domain + link.
    func handleEventURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), host.hasPrefix("chat.") else { return false }
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.isEmpty, let f = url.fragment { parts = f.split(separator: "/").map(String.init) }
        guard parts.count == 2, parts[0] == "events", EventLinks.slugRx.test(parts[1]) || EventLinks.isD(parts[1]) else { return false }
        let domain = String(host.dropFirst(5))
        if phase == .ready && domain == config.domain { openEvent = parts[1] } else if phase == .ready { website = "This event is in another community." }
        return true
    }
}
