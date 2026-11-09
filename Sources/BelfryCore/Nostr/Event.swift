import Foundation

// NIP-01 events: id = sha256 of the canonical serialization, BIP-340 signatures.

public typealias Tag = [String]

public struct NostrEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pubkey: String
    public var createdAt: Int
    public var kind: Int
    public var tags: [Tag]
    public var content: String
    public var sig: String

    enum CodingKeys: String, CodingKey {
        case id, pubkey, kind, tags, content, sig
        case createdAt = "created_at"
    }

    public init(id: String = "", pubkey: String, createdAt: Int, kind: Int, tags: [Tag], content: String, sig: String = "") {
        self.id = id
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        pubkey = try c.decode(String.self, forKey: .pubkey)
        createdAt = try c.decode(Int.self, forKey: .createdAt)
        kind = try c.decode(Int.self, forKey: .kind)
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        sig = try c.decodeIfPresent(String.self, forKey: .sig) ?? ""
    }

    /// The first value of the first tag named NAME.
    public func tag(_ name: String) -> String? {
        for t in tags where t.first == name && t.count > 1 { return t[1] }
        return nil
    }

    public func tagValues(_ name: String) -> [String] {
        tags.compactMap { $0.first == name && $0.count > 1 ? $0[1] : nil }
    }

    public func hasTag(_ name: String, _ value: String? = nil) -> Bool {
        tags.contains { $0.first == name && (value == nil || ($0.count > 1 && $0[1] == value)) }
    }

    /// `[0,pubkey,created_at,kind,tags,content]`, compact, NIP-01 escaping.
    public var serialized: String {
        var s = "[0,\(JSON.string(pubkey)),\(createdAt),\(kind),["
        s += tags.map { "[" + $0.map(JSON.string).joined(separator: ",") + "]" }.joined(separator: ",")
        s += "],\(JSON.string(content))]"
        return s
    }

    public var computedId: String { Crypto.sha256(serialized).hex }

    public var isIdValid: Bool { id == computedId }

    /// Id and signature both check out.
    public var isValid: Bool {
        guard isIdValid, let sigData = Data(hex: sig), let idData = Data(hex: id), let pk = Data(hex: pubkey) else { return false }
        return Keys.verify(signature: sigData, message: idData, publicKey: pk)
    }

    /// Signs with a local secret (one-time keys, the demo key). Sets pubkey, id and sig.
    public func signed(with secret: Data) throws -> NostrEvent {
        var e = self
        e.pubkey = try Keys.publicKeyHex(secret: secret)
        e.id = e.computedId
        e.sig = try Keys.sign(message: Data(hex: e.id)!, secret: secret).hex
        return e
    }

    /// Fills the id of an unsigned event (a NIP-59 rumor).
    public func withId() -> NostrEvent {
        var e = self
        e.id = e.computedId
        return e
    }

    public var json: String {
        var s = "{\"id\":\(JSON.string(id)),\"pubkey\":\(JSON.string(pubkey)),\"created_at\":\(createdAt),\"kind\":\(kind),\"tags\":["
        s += tags.map { "[" + $0.map(JSON.string).joined(separator: ",") + "]" }.joined(separator: ",")
        s += "],\"content\":\(JSON.string(content)),\"sig\":\(JSON.string(sig))}"
        return s
    }

    public static func from(json: String) -> NostrEvent? {
        try? JSONDecoder().decode(NostrEvent.self, from: Data(json.utf8))
    }
}

/// What a client asks a signer to sign.
public struct EventTemplate: Sendable, Hashable {
    public var kind: Int
    public var content: String
    public var tags: [Tag]
    public var createdAt: Int

    public init(kind: Int, content: String = "", tags: [Tag] = [], createdAt: Int) {
        self.kind = kind
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
    }

    public func event(pubkey: String) -> NostrEvent {
        NostrEvent(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
    }
}

public enum JSON {
    /// A JSON string literal with NIP-01 escaping: \" \\ \n \r \t \b \f, other control
    /// characters as \u00XX, everything else (/, non-ASCII) as is.
    public static func string(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// A JSON value from text (objects, arrays…), or nil.
    public static func parse(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    public static func encode(_ value: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }
}

public extension Int {
    static var now: Int { Int(Date().timeIntervalSince1970) }
}
