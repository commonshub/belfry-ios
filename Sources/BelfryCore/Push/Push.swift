import Foundation
import Security

// Push notifications (collective-belfry docs/push.md; SPEC 19.19). The device makes a random
// 32-byte key K and registers it with the belfry; the belfry encrypts each notification with
// NIP-44 v2 using K directly as the conversation key and sends it through the push gateway. APNs
// delivers `aps.alert` = a placeholder and `b` = the ciphertext; the Notification Service
// Extension decrypts it here and replaces title and body. Nothing here trusts the payload's
// `url`: `route` only accepts chat.<domain> of the belfry this device is signed in to.

/// What a notification says once decrypted (the plaintext of push.md §4).
public struct PushContent: Hashable, Sendable {
    public let domain: String
    public let type: String
    public let title: String
    public let body: String
    public let channel: String?
    public let event: String?
    public let from: String?
    public let url: String?

    /// The notification's thread: `dm` for direct messages, else the channel (push.md `collapse`).
    public var threadId: String { type == "dm" ? "dm" : (channel ?? "belfry") }

    /// Which setting it falls under (vectors/push.json `channel`): dms, mentions (mentions and
    /// replies), announcements, pins, messages.
    public var category: String {
        switch type {
        case "dm": return "dms"
        case "mention", "reply": return "mentions"
        case "announcement": return "announcements"
        case "pin": return "pins"
        default: return "messages"
        }
    }

    /// What a tap opens for someone signed in to SIGNEDIN: only this belfry's own addresses.
    public func route(signedIn: String) -> PushRoute {
        domain.lowercased() == signedIn.lowercased() ? Push.route(url, domain: signedIn) : .home
    }
}

/// Where a tap on a notification leads.
public enum PushRoute: Hashable, Sendable {
    case channel(String, message: String?)
    /// A thread reply: the channel with the thread of ROOT open.
    case thread(String, root: String)
    case messages
    case home
}

public enum Push {
    /// A new device key K: 32 random bytes, base64 as the belfry stores it.
    public static func newKey() -> Data { Crypto.random(32) }

    /// Decrypts `b` with K; nil when it doesn't open or isn't a version-1 notification.
    public static func open(_ b: String, key: Data) -> PushContent? {
        guard key.count == 32, let text = try? NIP44.decrypt(b, conversationKey: key),
              let o = JSON.parse(text) as? [String: Any], (o["v"] as? NSNumber)?.intValue == 1,
              let domain = o["domain"] as? String, !domain.isEmpty else { return nil }
        func s(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let type = s("type") ?? "message"
        let title = (s("title") ?? domain).sliceUnits(120)
        let body = (s("body") ?? "New notification").sliceUnits(180)
        return PushContent(domain: domain, type: type, title: title, body: body, channel: s("channel"),
                           event: s("event").flatMap { isHex64($0) ? $0 : nil }, from: s("from").flatMap { isHex64($0) ? $0 : nil }, url: s("url"))
    }

    /// Where URL leads, if it is https://chat.<DOMAIN>/#/c/<id>[/m/<event>] or …/#/dm; else home.
    public static func route(_ url: String?, domain: String) -> PushRoute {
        guard let url, let u = URL(string: url), u.scheme == "https", u.host?.lowercased() == "chat." + domain.lowercased() else { return .home }
        let parts = (u.fragment ?? "").split(separator: "/").map(String.init)
        if parts.first == "dm" { return .messages }
        guard parts.count >= 2, parts[0] == "c", let id = parts[1].removingPercentEncoding, !id.isEmpty else { return .home }
        if parts.count >= 4, parts[2] == "m", isHex64(parts[3]) { return .channel(id, message: parts[3]) }
        if parts.count >= 4, parts[2] == "thread", isHex64(parts[3]) { return .thread(id, root: parts[3]) }
        return .channel(id, message: nil)
    }

    /// Stay quiet for a "dm" notification that comes within 30 s of this phone sending a direct
    /// message or an e-mail: NIP-17 self-copies look like any other DM to the belfry (push.md §4).
    public static let quietAfterSend = 30

    public static func isOwnEcho(type: String, lastSent: Int, now: Int) -> Bool {
        type == "dm" && lastSent > 0 && now - lastSent >= 0 && now - lastSent <= quietAfterSend
    }

    /// App Group defaults shared by the app and its extension (when the group is available).
    public static let appGroup = "group.sh.belfry.app"
    public static let lastSentKey = "belfry-last-dm-sent"

    public static var shared: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    /// The app sent a DM or an e-mail now.
    public static func markSent(now: Int = .now) { shared.set(now, forKey: lastSentKey) }
    public static var lastSent: Int { shared.integer(forKey: lastSentKey) }

    /// The body of `POST /api/v1/push/devices` that registers this device.
    public static func addBody(token: Data, sandbox: Bool, key: Data, name: String) -> [String: Any] {
        ["add": ["platform": "apns", "token": token.hex, "env": sandbox ? "sandbox" : "production",
                 "key": key.base64EncodedString(), "app": "belfry-ios", "name": String(name.prefix(60))]]
    }
}

/// Where K is kept: the keychain, in an access group the app and its extension share (falls back
/// to the app's own group when the shared one isn't available, e.g. an unsigned simulator build).
public enum PushKeyStore {
    static let service = "sh.belfry.app.push"
    static let account = "device-key"

    static func query(_ group: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let group, !group.isEmpty { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    /// Saves "<domain> <base64 K>".
    public static func save(domain: String, key: Data, group: String?) {
        let value = Data((domain + " " + key.base64EncodedString()).utf8)
        clear(group: group)
        var q = query(group)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecValueData as String] = value
        if SecItemAdd(q as CFDictionary, nil) != errSecSuccess, group != nil {
            var plain = query(nil)
            plain[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            plain[kSecValueData as String] = value
            SecItemAdd(plain as CFDictionary, nil)
        }
    }

    public static func load(group: String?) -> (domain: String, key: Data)? {
        for g in [group, nil] {
            var q = query(g)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
                  let s = String(data: d, encoding: .utf8) else { continue }
            let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, let k = Data(base64Encoded: parts[1]), k.count == 32 { return (parts[0], k) }
        }
        return nil
    }

    public static func clear(group: String?) {
        SecItemDelete(query(group) as CFDictionary)
        if group != nil { SecItemDelete(query(nil) as CFDictionary) }
    }
}

/// The person's notification settings (`POST /api/v1/notifications`, push.md §3).
public struct NotificationSettings: Hashable, Sendable {
    public var dms = true
    public var mentions = true
    public var announcements = true
    public var pins = true
    /// group id → all | default | mentions | off (absent = default)
    public var channels = [String: String]()
    public init() {}

    public static let levels: [(id: String, label: String)] = [("all", "All messages"), ("default", "Default"), ("mentions", "Mentions only"), ("off", "Off")]

    public func level(_ group: String) -> String { channels[group] ?? "default" }

    public static func parse(_ o: [String: Any]) -> NotificationSettings {
        var s = NotificationSettings()
        s.dms = o["dms"] as? Bool ?? true
        s.mentions = o["mentions"] as? Bool ?? true
        s.announcements = o["announcements"] as? Bool ?? true
        s.pins = o["pins"] as? Bool ?? true
        for (k, v) in o["channels"] as? [String: Any] ?? [:] {
            if let l = v as? String, levels.contains(where: { $0.id == l }) { s.channels[k] = l }
        }
        return s
    }
}

public struct PushDevice: Hashable, Sendable, Identifiable { public let id, app, name, since: String }

public extension BelfryAPI {
    /// Registers (or re-registers) this device; returns its id.
    @discardableResult
    func addPushDevice(token: Data, sandbox: Bool, key: Data, name: String) async throws -> String {
        let a = try await signed(config.apiBase + "/push/devices", method: "POST", json: Push.addBody(token: token, sandbox: sandbox, key: key, name: name))
        guard a.ok, let id = a.body?["id"] as? String else { throw BelfryAPI.fail(a, [:], "Notifications could not be turned on just now.") }
        return id
    }

    func removePushDevice(token: Data) async throws {
        let a = try await signed(config.apiBase + "/push/devices", method: "POST", json: ["remove": token.hex])
        if !a.ok { throw BelfryAPI.fail(a, [:], BelfryAPI.generic) }
    }

    func pushDevices() async throws -> [PushDevice] {
        let a = try await signed(config.apiBase + "/push/devices", method: "POST", json: [:])
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, [:], "Your devices could not be read just now.") }
        return (b["devices"] as? [[String: Any]] ?? []).compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            return PushDevice(id: id, app: o["app"] as? String ?? "", name: (o["name"] as? String ?? "").sliceUnits(60), since: o["since"] as? String ?? "")
        }
    }

    /// SET nil reads the settings; otherwise merges SET and returns the result.
    func notificationSettings(set: [String: Any]? = nil) async throws -> NotificationSettings {
        let a = try await signed(config.apiBase + "/notifications", method: "POST", json: set.map { ["set": $0] } ?? [:])
        guard a.ok, let b = a.body else { throw BelfryAPI.fail(a, [:], "Your notification settings could not be read just now.") }
        return NotificationSettings.parse(b)
    }
}
