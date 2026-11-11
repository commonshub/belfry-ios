import Foundation

// Who someone is here and what they can read (SPEC 19.15, 19.16; the web chat's core/invite.ts
// isGuest / isAgent / inChannel and access.ts agentOwner, village-app 1834584 + 453684b).

extension Derive {
    /// Whose agent PUBKEY is, when it is a member's own agent (belfry.json `agents`).
    public func agentOwner(_ pubkey: String) -> String? { ctx.agents[pubkey] }

    /// Someone who is here only as a channel's guest (a person or an agent), not a member's own agent.
    /// The register's answer (`/whois`) overrules the events.
    public func isGuest(_ pubkey: String) -> Bool {
        switch ctx.kinds[pubkey] ?? "" {
        case "guest": return true
        case "member", "agent": return false
        default: return agentOwner(pubkey) == nil && !guestJoinsOf(pubkey).isEmpty
        }
    }

    /// An agent (a channel's guest, or a member's own), not a person.
    public func isAgent(_ pubkey: String) -> Bool {
        if agentOwner(pubkey) != nil || ctx.kinds[pubkey] == "agent" { return true }
        return groups().contains { g in guestJoins(g.id).contains { $0.pubkey == pubkey && $0.agent } }
    }

    /// Whether PUBKEY can read channel G: an open channel is every member's (and its own guests');
    /// a closed one only its members' and admins'. Unknown channel → true.
    public func inChannel(_ g: Group?, _ pubkey: String) -> Bool {
        guard let g else { return true }
        if g.members.contains(pubkey) || g.admins.contains(pubkey) { return true }
        if g.closed { return false }
        return !isGuest(pubkey)
    }

    /// What someone is, when not a plain member: "Kofi's agent", "Agent, a guest", "Guest"; nil for a member.
    public func kindLabel(_ pubkey: String) -> String? {
        if let owner = agentOwner(pubkey) { return (owner == me ? "Your" : realNameOr(owner) + "'s") + " agent" }
        if isGuest(pubkey) { return isAgent(pubkey) ? "Agent, a guest" : "Guest" }
        return nil
    }

    /// "Kofi" or "a member" (never "You").
    func realNameOr(_ pubkey: String) -> String {
        let n = realName(pubkey)
        return n.isEmpty ? Derive.shortKey(pubkey) : n
    }

    /// The people the invite search finds: everyone with a name, me left out; a word of the name
    /// starts with the query; at most 5.
    public func inviteCandidates(_ query: String, limit: Int = 5) -> [String] {
        let q = query.jsTrim().lowercased()
        if q.isEmpty { return [] }
        return Array(people.filter { p in p.name.lowercased().split(whereSeparator: { $0.isWhitespace }).contains { $0.hasPrefix(q) } }.prefix(limit).map(\.pubkey))
    }

    /// Where an invited person stands with a channel: "Already in", "Can already open it", "Not in this channel".
    public func inviteState(_ g: Group?, _ pubkey: String) -> String {
        guard let g else { return "Not in this channel" }
        if g.members.contains(pubkey) || g.admins.contains(pubkey) { return "Already in" }
        return inChannel(g, pubkey) ? "Can already open it" : "Not in this channel"
    }

    /// The web chat's link to a channel, as a member invite carries it: https://chat.<domain>/#/c/<id>.
    public func channelURL(_ id: String) -> String { "https://chat.\(ctx.domain)/#/c/" + MailThreads.encodeURIComponent(id) }

    /// The direct message a member invite sends (my name as others know it, never "You"). ASKED: a
    /// closed group I do not administer, they still have to apply.
    public func inviteText(_ groupId: String, asked: Bool) -> String {
        let g = group(groupId)
        let name = g == nil ? groupId : (g!.isPod || g!.isEvent || g!.isProposal) ? g!.name : "# " + g!.name
        let mine = profiles()[me]?.name ?? ""
        let from = mine.isEmpty ? "A member" : mine
        let url = channelURL(groupId)
        return asked ? "\(from) thinks you should join \(name). It takes an application: \(url)" : "\(from) invited you to \(name): \(url)"
    }

    /// A member's agents as belfry.json lists them.
    public func agentsOf(_ member: String) -> [String] { ctx.agents.filter { $0.value == member }.map(\.key).sorted() }
}
