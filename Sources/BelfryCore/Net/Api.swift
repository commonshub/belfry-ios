import Foundation

// The belfry's HTTP API (`<api base>`, default https://belfry.<domain>/api/v1): guest links,
// whois, agents, places, admins, follows, username, sessions, website. Calls made as the member
// carry a NIP-98 Authorization signed by the member's signer (the bunker). Every failure is an
// ApiError whose message is a fixed text of this app chosen by the server's `error` key: the
// server's own free text is never shown. Port of the Android app's net/Api.kt.

public struct ApiError: Error, Equatable, LocalizedError {
    /// The server's `error` key, or ours: `network`, `http`, `signer`.
    public let code: String
    public let status: Int
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: String, _ status: Int, _ message: String) { self.code = code; self.status = status; self.message = message }
}

public struct GuestLink: Hashable, Sendable {
    public let url: String
    public let agentURL: String?
    public let days: Int
    public let people: Int
    public let linkDays: Int
    public let expiresAt: String?
    public let ownAgent: Bool
    public init(url: String, agentURL: String?, days: Int, people: Int, linkDays: Int, expiresAt: String?, ownAgent: Bool) {
        self.url = url; self.agentURL = agentURL; self.days = days; self.people = people
        self.linkDays = linkDays; self.expiresAt = expiresAt; self.ownAgent = ownAgent
    }
}

public struct ChannelGuest: Hashable, Sendable { public let added: Bool; public let already: Bool; public let member: Bool }

public struct MyAgent: Hashable, Sendable, Identifiable { public let pubkey: String; public let name: String; public let since: String; public var id: String { pubkey } }

public struct MyAgents: Hashable, Sendable {
    public let agents: [MyAgent]
    public let limit: Int
    public init(agents: [MyAgent], limit: Int) { self.agents = agents; self.limit = limit }
    public var room: Int { limit - agents.count }
}

/// What the join screen shows before anyone signs anything: all of it from the belfry's answer.
public struct InviteInfo: Hashable, Sendable {
    public let community: String
    public let channel: String
    public let channelName: String
    public let about: String
    public let inviter: String
    /// open | used | expired | revoked
    public let state: String
    public let days: Int
    public init(community: String, channel: String, channelName: String, about: String, inviter: String, state: String, days: Int) {
        self.community = community; self.channel = channel; self.channelName = channelName; self.about = about
        self.inviter = inviter; self.state = state; self.days = days
    }
    public var isOpen: Bool { state == "open" }
    public var closedMessage: String? {
        switch state {
        case "open": return nil
        case "expired": return "This invite has expired. Ask for a new one."
        case "revoked": return "This invite was withdrawn. Ask for a new one."
        default: return "This invite was used already. Ask for a new one."
        }
    }
}

public struct JoinedNew: Hashable, Sendable {
    public let bunkerURL: String
    public let channel: String
    public let pubkey: String?
    public let emailNeeded: Bool
    /// Guest mode (SPEC 19.26): a nameless guest who reads until they join. False for a guest
    /// who joined by name (older clients) and for an older belfry that does not say.
    public var reading = false
}
public struct JoinedAccount: Hashable, Sendable { public let channel: String; public let already: Bool; public let guest: Bool }
public struct Places: Hashable, Sendable { public let places: [Place]; public let attribution: String? }
/// E-mail follows of channels' announcements: channel id → `asap` | `monthly`.
public struct Follows: Hashable, Sendable { public let email: String; public let byChannel: [String: String] }

public struct SessionInfo: Hashable, Sendable, Identifiable {
    public let applicationName: String
    public let device: String?
    public let redirectOrigin: String
    public let bunkerPubkey: String
    public let createdAt: String
    public let lastActivity: String?
    public var id: String { bunkerPubkey }
    public init(applicationName: String, device: String?, redirectOrigin: String, bunkerPubkey: String, createdAt: String, lastActivity: String?) {
        self.applicationName = applicationName; self.device = device; self.redirectOrigin = redirectOrigin
        self.bunkerPubkey = bunkerPubkey; self.createdAt = createdAt; self.lastActivity = lastActivity
    }
}

/// A guest link's token, from https://chat.<domain>/join/<token> (or …/#/join/<token>).
public enum InviteLink {
    public static let tokenRx = Rx("^[A-Za-z0-9_-]{20,}$")
    public static func isToken(_ s: String) -> Bool { tokenRx.test(s) }

    /// Only the domain and the token are read from the address; nothing else of it is ever shown.
    public static func parse(_ url: URL) -> (domain: String, token: String)? {
        guard url.scheme == "https", let host = url.host?.lowercased(), host.hasPrefix("chat.") else { return nil }
        let domain = String(host.dropFirst(5))
        guard Discovery.isDomain(domain) else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.isEmpty, let f = url.fragment { parts = f.split(separator: "/").map(String.init) }
        guard parts.count == 2, parts[0] == "join", isToken(parts[1]) else { return nil }
        return (domain, parts[1])
    }
}

public struct BelfryAPI: Sendable {
    public let config: BelfryConfig
    public let signer: Signer?
    public let session: URLSession
    /// Guest mode: signed calls that write are refused on the device (SPEC 19.26).
    public let guestMode: GuestModeGate?

    public init(config: BelfryConfig, signer: Signer?, session: URLSession = .shared, guestMode: GuestModeGate? = nil) {
        self.config = config
        self.signer = signer
        self.session = session
        self.guestMode = guestMode
    }

    var base: String { config.apiBase }

    public struct Answer {
        public let status: Int
        public let body: [String: Any]?
        public var ok: Bool { (200...299).contains(status) }
        public var error: String { body?["error"] as? String ?? "" }
    }

    // ---- plumbing -------------------------------------------------------------------------------

    func send(_ url: String, method: String, body: Data?, authorization: String?) async throws -> Answer {
        guard let u = URL(string: url) else { throw ApiError("http", 0, BelfryAPI.generic) }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization { req.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw ApiError("network", 0, BelfryAPI.network) }
        return Answer(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    static func header(_ signer: Signer, url: String, method: String, body: Data?) async throws -> String {
        let auth = try await signer.sign(Actions.httpAuth(url: url, method: method, body: body))
        return "Nostr " + Data(auth.json.utf8).base64EncodedString()
    }

    /// A request signed by the member (NIP-98). BODY nil = no body (GET).
    public func signed(_ url: String, method: String = "GET", json: [String: Any]? = nil) async throws -> Answer {
        guard let signer else { throw ApiError("signer", 0, BelfryAPI.generic) }
        if let guestMode {
            do { try guestMode.check(url: url, method: method) } catch { throw ApiError("guest_mode", 0, GuestModeRefused.message) }
        }
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let auth: String
        do { auth = try await BelfryAPI.header(signer, url: url, method: method, body: body) } catch {
            throw ApiError("signer", 0, "Your signer did not answer. Check your connection and try again.")
        }
        return try await send(url, method: method, body: body, authorization: auth)
    }

    func plain(_ url: String) async throws -> Answer { try await send(url, method: "GET", body: nil, authorization: nil) }

    static func fail(_ a: Answer, _ messages: [String: String], _ fallback: String) -> ApiError {
        let code = a.error.isEmpty ? "http" : a.error
        return ApiError(code, a.status, messages[code] ?? common[code] ?? fallback)
    }

    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    static func bool(_ v: Any?) -> Bool? { v as? Bool }

    // ---- guest links (guests.py) ----------------------------------------------------------------

    /// PEOPLE: 1 or 50. LINK_DAYS: 1, 7 or 30. AGENT: a link for one agent that joins as my own.
    /// ROLE "host": a co-host link (an event's group).
    public func createGuestLink(channel: String, people: Int = 1, linkDays: Int = 1, agent: Bool = false, role: String? = nil) async throws -> GuestLink {
        var body: [String: Any] = ["channel": channel, "people": people == 50 && !agent ? 50 : 1, "link_days": linkDays == 7 || linkDays == 30 ? linkDays : 1]
        if agent { body["agent"] = true }
        if let role { body["role"] = role }
        let a = try await signed(config.channelInvites, method: "POST", json: body)
        guard a.ok, let b = a.body, let url = b["url"] as? String, url.hasPrefix("https://") else {
            throw BelfryAPI.fail(a, BelfryAPI.inviteErrors, "The guest link could not be made.")
        }
        return GuestLink(url: url, agentURL: (b["agent_url"] as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil },
                         days: BelfryAPI.int(b["days"]) ?? 30, people: BelfryAPI.int(b["people"]) ?? people,
                         linkDays: BelfryAPI.int(b["link_days"]) ?? linkDays, expiresAt: b["expires_at"] as? String,
                         ownAgent: BelfryAPI.bool(b["own_agent"]) ?? agent)
    }

    /// Someone here as another channel's guest becomes a guest of CHANNEL too.
    public func addChannelGuest(channel: String, pubkey: String) async throws -> ChannelGuest {
        let a = try await signed(base + "/channel-guests", method: "POST", json: ["channel": channel, "pubkey": pubkey])
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.channelGuestErrors, "Could not add them. Try again.") }
        return ChannelGuest(added: b["added"] as? Bool == true, already: b["already"] as? Bool == true, member: b["member"] as? Bool == true)
    }

    // ---- who a key is (whois) -------------------------------------------------------------------

    public static let whoisMax = 500

    /// What the register says each key is: "member", "agent" or "guest"; keys with no active pass
    /// are left out. Split into calls of at most 500 keys. An old belfry answers 404 (code `http`).
    public func whois(_ pubkeys: [String]) async throws -> [String: String] {
        var keys = [String]()
        for k in pubkeys where isHex64(k) && !keys.contains(k) { keys.append(k) }
        var out = [String: String]()
        var i = 0
        while i < keys.count {
            let chunk = Array(keys[i..<min(keys.count, i + BelfryAPI.whoisMax)])
            i += BelfryAPI.whoisMax
            let a = try await signed(base + "/whois", method: "POST", json: ["pubkeys": chunk])
            guard a.ok, let people = a.body?["people"] as? [String: Any] else {
                throw BelfryAPI.fail(a, BelfryAPI.whoisErrors, "Could not ask the belfry who people are.")
            }
            for (k, v) in people {
                if let kind = v as? String, isHex64(k), ["member", "agent", "guest"].contains(kind) { out[k] = kind }
            }
        }
        return out
    }

    // ---- a member's own agents ------------------------------------------------------------------

    func agentsCall(_ body: [String: Any]) async throws -> MyAgents {
        let a = try await signed(base + "/agents", method: "POST", json: body)
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, BelfryAPI.agentErrors, "Could not do that. Try again.") }
        let list = (b["agents"] as? [[String: Any]] ?? []).compactMap { o -> MyAgent? in
            guard let pk = o["pubkey"] as? String, isHex64(pk) else { return nil }
            return MyAgent(pubkey: pk, name: o["name"] as? String ?? "", since: o["since"] as? String ?? "")
        }
        return MyAgents(agents: list, limit: BelfryAPI.int(b["limit"]) ?? 0)
    }

    public func myAgents() async throws -> MyAgents { try await agentsCall([:]) }
    public func setMyAgent(_ pubkey: String, mine: Bool) async throws -> MyAgents { try await agentsCall(["pubkey": pubkey, "mine": mine]) }

    // ---- joining by a guest link ----------------------------------------------------------------

    public func inviteInfo(_ token: String) async throws -> InviteInfo {
        guard InviteLink.isToken(token) else { throw ApiError("not_found", 404, BelfryAPI.inviteUnknown) }
        let a = try await plain(config.channelInvites + "/" + token)
        if a.status == 404 { throw ApiError("not_found", 404, BelfryAPI.inviteUnknown) }
        guard a.ok, let b = a.body, let channel = b["channel"] as? String else {
            throw ApiError(a.error.isEmpty ? "http" : a.error, a.status, "The invite could not be read just now. Try again.")
        }
        return InviteInfo(community: (b["community"] as? String ?? "").sliceUnits(100), channel: channel,
                          channelName: (b["channel_name"] as? String ?? channel).sliceUnits(80), about: (b["about"] as? String ?? "").sliceUnits(300),
                          inviter: (b["inviter"] as? String ?? "").sliceUnits(100), state: b["state"] as? String ?? "used", days: BelfryAPI.int(b["days"]) ?? 30)
    }

    /// A new guest: this device's fresh session key signs the request; the belfry answers with
    /// its session, bound to that key. NAME nil (guest mode, SPEC 19.26): the body is `{}` and the
    /// guest reads until they join; a name: a guest by that name at once (older flow). Keep ONE key
    /// per invite until this succeeds; `session_taken` (409): make a new key and try again.
    public func joinAsNew(token: String, name: String? = nil, sessionSecretHex: String) async throws -> JoinedNew {
        let url = config.channelInvites + "/" + token + "/join"
        let body: Data
        if let name { body = try JSONSerialization.data(withJSONObject: ["name": name.jsTrim().sliceUnits(100)]) } else { body = Data("{}".utf8) }
        let auth: String
        do { auth = try await BelfryAPI.header(LocalSigner(secretHex: sessionSecretHex), url: url, method: "POST", body: body) } catch {
            throw ApiError("signer", 0, BelfryAPI.generic)
        }
        let a = try await send(url, method: "POST", body: body, authorization: auth)
        guard a.ok, let b = a.body, let bunker = b["bunker_url"] as? String, BunkerURL(bunker) != nil else {
            if a.status == 409 && BelfryAPI.joinErrors[a.error] == nil { throw ApiError("session_taken", 409, "Joining did not work just now. Try again.") }
            var m = BelfryAPI.joinErrors
            // asked with `{}`: only a belfry from before guest mode wants a name here
            if name == nil { m["name_needed"] = "This belfry is being updated. Try again in a few minutes." }
            throw BelfryAPI.fail(a, m, "Joining did not work just now. Try again.")
        }
        var j = JoinedNew(bunkerURL: bunker, channel: (b["channel"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? generalId,
                          pubkey: (b["pubkey"] as? String).flatMap { isHex64($0) ? $0 : nil }, emailNeeded: b["email_needed"] as? Bool ?? false)
        j.reading = name == nil && b["reading"] as? Bool != false && b["guest"] as? Bool != false
        return j
    }

    /// Someone signed in uses a guest link: their account gets the channel (no second account).
    public func joinWithAccount(token: String) async throws -> JoinedAccount {
        let a = try await signed(config.channelInvites + "/" + token + "/join", method: "POST", json: [:])
        guard a.ok, let b = a.body, let channel = b["channel"] as? String else {
            var m = BelfryAPI.joinErrors
            m["name_needed"] = "This account can’t use invites."
            throw BelfryAPI.fail(a, m, "The invite could not be used just now.")
        }
        return JoinedAccount(channel: channel, already: b["already"] as? Bool ?? false, guest: b["guest"] as? Bool ?? false)
    }

    /// Join from guest mode, or save a named guest's account (SPEC 19.26): a 6-digit code goes
    /// to EMAIL. NAME is sent when the guest has none yet (guest mode). Refusals: `GuestJoinFailure`.
    public func guestSave(email: String, name: String? = nil) async throws {
        var body: [String: Any] = ["email": email.jsTrim()]
        if let name { body["name"] = GuestJoinForm.cleanName(name) }
        _ = try await guestCall("/guest/save", body)
    }

    /// The code from the e-mail. Returns `joined` (true: they were in guest mode and are now in
    /// the channel with their name).
    @discardableResult
    public func guestVerify(email: String, code: String, name: String? = nil) async throws -> Bool {
        var body: [String: Any] = ["email": email.jsTrim(), "code": code.jsTrim()]
        if let name { body["name"] = GuestJoinForm.cleanName(name) }
        let b = try await guestCall("/guest/save/verify", body)
        return b["joined"] as? Bool ?? false
    }

    func guestCall(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let a: Answer
        do { a = try await signed(base + path, method: "POST", json: body) } catch let e as ApiError {
            throw GuestJoinFailure(e.code == "network" ? .offline : .failed)
        }
        guard a.ok else { throw GuestJoinFailure(GuestJoinError(code: a.error), moved: a.body?["moved"] as? Bool == true) }
        return a.body ?? [:]
    }

    // ---- places ---------------------------------------------------------------------------------

    static func place(_ o: [String: Any]) -> Place {
        Place(country: o["country"] as? String ?? "", id: o["id"] as? String, name: o["name"] as? String, region: o["region"] as? String,
              lat: (o["lat"] as? NSNumber)?.doubleValue, lon: (o["lon"] as? NSNumber)?.doubleValue, near: o["near"] as? String)
    }

    /// Cities matching the start of a name (no sign-in). Fewer than 2 characters: nothing.
    public func searchPlaces(_ query: String, limit: Int = 8) async throws -> Places {
        let q = query.jsTrim()
        if q.count < 2 { return Places(places: [], attribution: nil) }
        let a = try await plain(base + "/places?q=" + MailThreads.encodeURIComponent(q) + "&limit=\(limit)")
        guard a.ok, let b = a.body else { throw ApiError(a.error.isEmpty ? "http" : a.error, a.status, "The list of places is not available right now.") }
        return Places(places: (b["places"] as? [[String: Any]] ?? []).map(BelfryAPI.place), attribution: b["attribution"] as? String)
    }

    /// A place the list doesn't have: its name, its country code, and the nearest listed city.
    public func addPlace(name: String, country: String, nearId: String) async throws -> Place {
        let a = try await signed(base + "/places", method: "POST", json: ["name": name, "country": country, "near": nearId])
        guard a.ok, let p = a.body?["place"] as? [String: Any] else { throw BelfryAPI.fail(a, BelfryAPI.placeErrors, "Could not add the place. Try again.") }
        return BelfryAPI.place(p)
    }

    // ---- admins, follows, username, sessions, website -------------------------------------------

    public func setAdmin(_ pubkey: String, admin: Bool) async throws {
        let a = try await signed(base + "/admins", method: "POST", json: ["pubkey": pubkey, "admin": admin])
        if !a.ok { throw BelfryAPI.fail(a, BelfryAPI.adminErrors, "Could not change it. Try again.") }
    }

    var followsURL: String { base + "/me/follows" }

    public func follows() async throws -> Follows {
        let a = try await signed(followsURL)
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, [:], "Your follows could not be read just now.") }
        var map = [String: String]()
        for o in b["follows"] as? [[String: Any]] ?? [] {
            guard let f = o["frequency"] as? String, let c = o["channel"] as? String else { continue }
            if o["state"] as? String == "active", f == "asap" || f == "monthly" { map[c] = f }
        }
        return Follows(email: b["email"] as? String ?? "", byChannel: map)
    }

    /// CHOICE: `asap`, `monthly` or `stop`. Returns the frequency now in force, nil when not following.
    public func setFollow(channel: String, choice: String) async throws -> String? {
        let a = try await signed(followsURL, method: "POST", json: ["channel": channel, "frequency": choice])
        if !a.ok { throw BelfryAPI.fail(a, [:], "Not saved. Try again.") }
        guard let b = a.body, let f = b["frequency"] as? String else { return nil }
        return b["state"] as? String == "active" && (f == "asap" || f == "monthly") ? f : nil
    }

    /// Change my address here. Returns the full address.
    public func setUsername(_ username: String) async throws -> String {
        let a = try await signed(base + "/username", method: "POST", json: ["username": username])
        guard a.ok, let n = a.body?["nip05"] as? String else { throw BelfryAPI.fail(a, BelfryAPI.usernameErrors, "Could not change the username. Try again.") }
        return n
    }

    public func sessions() async throws -> [SessionInfo] {
        let a = try await signed(base + "/me/sessions")
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, [:], "Your sessions could not be read just now.") }
        return (b["sessions"] as? [[String: Any]] ?? []).compactMap { o in
            guard let pk = o["bunker_pubkey"] as? String else { return nil }
            return SessionInfo(applicationName: (o["application_name"] as? String ?? "").sliceUnits(120), device: (o["device"] as? String)?.sliceUnits(120),
                               redirectOrigin: o["redirect_origin"] as? String ?? "", bunkerPubkey: pk, createdAt: o["created_at"] as? String ?? "",
                               lastActivity: o["last_activity"] as? String)
        }
    }

    public func revokeSession(_ bunkerPubkey: String) async throws {
        let a = try await signed(base + "/me/sessions/revoke", method: "POST", json: ["bunker_pubkey": bunkerPubkey])
        if !a.ok { throw BelfryAPI.fail(a, [:], "Not ended. Try again.") }
    }

    public func publishWebsite(ref: String, messageId: String) async throws {
        let a = try await signed(base + "/website/publish", method: "POST", json: ["ref": ref, "message": messageId])
        if !a.ok { throw BelfryAPI.fail(a, [:], "The website could not be published just now.") }
    }

    // ---- fixed messages -------------------------------------------------------------------------

    public static let generic = "That did not work. Try again."
    public static let network = "No connection to the belfry."
    static let inviteUnknown = "This invite link is not known here. Ask for a new one."

    static let common = [
        "unauthorized": "Your session was not accepted. Sign in again.",
        "no_pass": "Only members can do this.",
        "invalid_json": generic,
    ]
    static let inviteErrors = [
        "invalid": "This channel can’t have guest links.",
        "unsupported": "This belfry does not have guest links.",
        "guest": "Guests can’t invite guests.",
        "no_channel": "This channel is not known to the belfry yet.",
        "not_allowed": "You can’t invite guests here.",
        "refused": "The belfry refused to make a guest link.",
        "agent": "Agents can’t invite.",
    ]
    static let channelGuestErrors = [
        "invalid": "Could not add them. Try again.",
        "unsupported": "This belfry does not have guests.",
        "guest": "Guests can’t invite guests.",
        "agent": "Agents can’t invite.",
        "no_channel": "This channel is not known to the belfry yet.",
        "not_allowed": "You can’t invite guests here.",
        "unknown": "This person is not in the belfry any more.",
    ]
    static let whoisErrors = [
        "not_here": "Only people of this belfry can see who is who.",
        "invalid": generic,
    ]
    static let agentErrors = [
        "not_member": "Only members can bring an agent of their own.",
        "unknown": "Nobody here has that key.",
        "taken": "This agent is a member’s agent already.",
        "not_guest_agent": "Only an agent that joined as a guest can become yours.",
        "not_inviter": "Only the member who invited this agent can make it theirs.",
        "limit": "You have as many agents as you can have: remove one first.",
        "refused": "This agent can’t become yours. Only the member who invited it can make it theirs, within their limit.",
        "not_agent": "This is not a member’s agent.",
        "not_yours": "Only its member or an admin removes an agent.",
        "invalid": "Could not do that. Try again.",
        "unsupported": "This belfry does not have agents.",
    ]
    static let joinErrors = [
        "name_needed": "Tell us your name.",
        "closed": "This invite can’t be used any more. Ask for a new one.",
        "for_agent": "This link is for an AI agent, not a person.",
        "unsupported": "This belfry does not take guests.",
        "relay": "The channel could not be reached just now. Try again.",
        "failed": "Joining did not work just now. Try again.",
    ]
    static let placeErrors = [
        "bad_country": "That country code is not known.",
        "invalid": "Check the name, the country and the nearest city.",
        "not_member": "Only members add places.",
        "unsupported": "This belfry can’t add places.",
    ]
    public static let adminErrors = [
        "not_member": "Only members can be admins.",
        "guest_not_saved": "This guest has no e-mail yet. Once they save their account, you can make them an admin.",
        "agent": "An agent cannot be an admin.",
        "last_admin": "A belfry needs at least one admin.",
        "not_admin": "Only admins of the belfry can do this.",
    ]
    static let usernameErrors = [
        "taken": "That username is taken.",
        "invalid": "A username is 1 to 30 lowercase letters, digits, dots, dashes or underscores.",
        "not_member": "Only members have an address here.",
        "own_key": "You hold your own key: set your address in your own profile.",
    ]
}
