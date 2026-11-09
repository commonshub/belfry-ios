import Foundation

// SPEC 1: everything from the domain. belfry.json with fallbacks; NIP-05 lookups.

public struct BelfryConfig: Codable, Hashable, Sendable {
    public var domain: String
    public var name: String
    public var groupsRelay: String
    public var mainRelay: String
    public var signerRelays: [String]
    public var blossom: String
    public var apiBase: String
    public var channelInvites: String
    public var authorize: String
    public var token: String
    public var revoke: String
    public var logout: String
    public var admins: [String]
    public var chatURL: String

    public static func defaults(domain raw: String) -> BelfryConfig {
        let d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let api = "https://belfry.\(d)/api/v1"
        return BelfryConfig(
            domain: d, name: d,
            groupsRelay: "wss://groups-relay.\(d)", mainRelay: "wss://relay.\(d)", signerRelays: ["wss://bunker.\(d)"],
            blossom: "https://blossom.\(d)", apiBase: api, channelInvites: api + "/channel-invites",
            authorize: "https://belfry.\(d)/connect/authorize", token: "https://belfry.\(d)/connect/token",
            revoke: "https://belfry.\(d)/connect/revoke", logout: "https://belfry.\(d)/connect/logout",
            admins: [], chatURL: "https://\(d)/chat/"
        )
    }

    /// The discovery document over the defaults (SPEC 1 table).
    public static func from(domain: String, document doc: [String: Any]) -> BelfryConfig {
        var c = defaults(domain: domain)
        func s(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } }
        if let n = s(doc["name"]) { c.name = n }
        let relays = doc["relays"] as? [String: Any] ?? [:]
        if let g = s(relays["groups"]) { c.groupsRelay = g }
        if let m = s(relays["community"]) { c.mainRelay = m }
        if let sr = relays["signer"] as? [String], !sr.isEmpty { c.signerRelays = sr }
        if let b = s(doc["blossom"]) { c.blossom = b }
        let api = doc["api"] as? [String: Any] ?? [:]
        if let base = s(api["base"]) { c.apiBase = base; c.channelInvites = base + "/channel-invites" }
        if let ci = s(api["channel_invites"]) { c.channelInvites = ci }
        let connect = (doc["sign_in"] as? [String: Any])?["connect"] as? [String: Any] ?? [:]
        if let a = s(connect["authorize"]) { c.authorize = a }
        if let t = s(connect["token"]) { c.token = t }
        if let l = s(connect["logout"]) { c.logout = l }
        if let r = s(connect["revoke"]) { c.revoke = r }
        c.admins = (doc["admins"] as? [String] ?? []).filter(isHex64)
        if let access = doc["access"] as? [String: Any], let more = access["admins"] as? [String] {
            c.admins += more.filter { isHex64($0) && !c.admins.contains($0) }
        }
        if let apps = doc["apps"] as? [[String: Any]], let chat = apps.first(where: { ($0["name"] as? String)?.lowercased() == "chat" }),
           let u = chat["url"] as? String, u.hasPrefix("https://") {
            c.chatURL = u.hasSuffix("/") ? u : u + "/"
        }
        return c
    }

    /// The web chat's link to a channel (the member invite link).
    public func channelLink(_ id: String) -> String {
        chatURL + "#/c/" + MailThreads.encodeURIComponent(id)
    }
}

public enum Discovery {
    /// A plausible domain (letters, digits, dots, hyphens; at least one dot).
    public static func isDomain(_ s: String) -> Bool {
        Rx("^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$").test(s.lowercased())
    }

    public static func fetch(domain: String, session: URLSession = .shared) async throws -> BelfryConfig {
        guard let url = URL(string: "https://\(domain)/.well-known/belfry.json") else { throw BelfryError.invalid("bad domain") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BelfryError.network("no belfry.json")
        }
        return .from(domain: domain, document: doc)
    }

    /// NIP-05: the key behind NAME@DOMAIN, or nil.
    public static func nip05(name: String, domain: String, session: URLSession = .shared) async -> String? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = domain
        comps.path = "/.well-known/nostr.json"
        comps.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = comps.url, let (data, _) = try? await session.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = obj["names"] as? [String: Any], let k = names[name] as? String, isHex64(k) else { return nil }
        return k
    }
}

public enum PKCE {
    public static func verifier() -> String { Crypto.base64url(Crypto.random(48)) }
    public static func state() -> String { Crypto.base64url(Crypto.random(24)) }
    public static func challenge(for verifier: String) -> String { Crypto.base64url(Crypto.sha256(Data(verifier.utf8))) }
}

/// SPEC 2: the OAuth code + PKCE exchange against /connect.
public struct SignIn: Sendable {
    public static let clientId = "belfry-ios"
    public static let scope = "policy:belfry-event"

    public let config: BelfryConfig
    public let redirectURI: String
    public let state: String
    public let verifier: String

    public init(config: BelfryConfig, redirectURI: String) {
        self.config = config
        self.redirectURI = redirectURI
        self.state = PKCE.state()
        self.verifier = PKCE.verifier()
    }

    public var authorizeURL: URL {
        var c = URLComponents(string: config.authorize)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: SignIn.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: SignIn.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return c.url!
    }

    /// Fixed reasons a sign-in can stop for (never text from the URL).
    public enum Failure: Error, Equatable {
        case cancelled, wrongState, refused, notApproved, ownKey, expired, network, unknown
        public var message: String {
            switch self {
            case .cancelled: return "Sign-in was cancelled."
            case .wrongState: return "This sign-in did not start here. Please try again."
            case .refused: return "Not signed in. Please try again."
            case .notApproved: return "This app is not approved on this belfry yet. Ask an admin to approve it."
            case .ownKey: return "Your key is your own: this belfry cannot sign for you in this app."
            case .expired: return "This sign-in expired. Please start again."
            case .network: return "No connection to the belfry. Check your connection and try again."
            case .unknown: return "Not signed in. Please try again."
            }
        }
    }

    /// The code from the callback URL, after checking state.
    public func code(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard q("state") == state else { throw Failure.wrongState }
        if let err = q("error") { throw err == "access_denied" ? Failure.cancelled : Failure.refused }
        guard let code = q("code"), !code.isEmpty else { throw Failure.refused }
        return code
    }

    public struct Token: Sendable { public let bunkerURL: String; public let pubkey: String? }

    public func exchange(code: String, session: URLSession = .shared) async throws -> Token {
        guard let url = URL(string: config.token) else { throw Failure.unknown }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code", "code": code, "client_id": SignIn.clientId,
            "redirect_uri": redirectURI, "code_verifier": verifier,
        ])
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw Failure.network }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let b = obj["bunker_url"] as? String, b.hasPrefix("bunker://"), (resp as? HTTPURLResponse)?.statusCode == 200 {
            return Token(bunkerURL: b, pubkey: (obj["pubkey"] as? String).flatMap { isHex64($0) ? $0 : nil })
        }
        switch obj["error"] as? String {
        case "app_not_approved": throw Failure.notApproved
        case "own_key": throw Failure.ownKey
        case "invalid_grant": throw Failure.expired
        default: throw Failure.unknown
        }
    }
}

/// bunker://<remote signer pubkey>?relay=…&secret=…
public struct BunkerURL: Hashable, Sendable {
    public let remotePubkey: String
    public let relays: [String]
    public let secret: String?

    public init?(_ s: String) {
        guard let c = URLComponents(string: s), c.scheme == "bunker", let host = c.host, isHex64(host.lowercased()) else { return nil }
        remotePubkey = host.lowercased()
        relays = (c.queryItems ?? []).filter { $0.name == "relay" }.compactMap(\.value).filter { $0.hasPrefix("wss://") || $0.hasPrefix("ws://") }
        secret = c.queryItems?.first { $0.name == "secret" }?.value
        if relays.isEmpty { return nil }
    }
}
