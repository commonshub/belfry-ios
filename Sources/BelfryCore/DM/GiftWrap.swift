import Foundation

// NIP-59 gift wraps carrying NIP-17 messages (kind 14) and Nostr Mail (kind 1301). SPEC 10.

public enum GiftWrap {
    /// Random up to two days in the past, as NIP-59 asks.
    public static func backdate(now: Int = .now) -> Int { now - Int.random(in: 0..<(2 * 86400)) }

    /// An unsigned rumor with its id.
    public static func rumor(kind: Int, pubkey: String, tags: [Tag], content: String, createdAt: Int = .now) -> NostrEvent {
        NostrEvent(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content).withId()
    }

    /// Seal (signed by SIGNER, the author) and wrap (signed by a one-time key) RUMOR for TO.
    public static func wrap(_ rumor: NostrEvent, to: String, signer: Signer) async throws -> NostrEvent {
        let sealed = try await signer.nip44Encrypt(peer: to, plaintext: rumor.json)
        let seal = try await signer.sign(EventTemplate(kind: 13, content: sealed, tags: [], createdAt: backdate()))
        let one = Keys.generateSecret()
        let content = try NIP44.encrypt(seal.json, conversationKey: NIP44.conversationKey(secret: one, publicKey: Data(hex: to) ?? Data()))
        return try NostrEvent(pubkey: "", createdAt: backdate(), kind: 1059, tags: [["p", to]], content: content).signed(with: one)
    }

    public struct Opened: Sendable { public let rumor: NostrEvent; public let sealPubkey: String }

    /// Wrap → seal (signature checked) → rumor. nil when the rumor claims another author.
    public static func unwrap(_ wrap: NostrEvent, signer: Signer) async throws -> Opened? {
        let sealJSON = try await signer.nip44Decrypt(peer: wrap.pubkey, payload: wrap.content)
        guard let seal = NostrEvent.from(json: sealJSON), seal.kind == 13, seal.isValid else { return nil }
        let rumorJSON = try await signer.nip44Decrypt(peer: seal.pubkey, payload: seal.content)
        guard var rumor = NostrEvent.from(json: rumorJSON) else { return nil }
        guard rumor.pubkey == seal.pubkey else { return nil }
        if rumor.id.isEmpty { rumor = rumor.withId() }
        return Opened(rumor: rumor, sealPubkey: seal.pubkey)
    }
}

/// A direct message or e-mail as the Messages screens show it (kept on the device only).
public struct Dm: Codable, Hashable, Sendable, Identifiable {
    public var rid: String
    public var conv: String
    public var from: String
    public var mine: Bool
    public var at: Int
    public var kind: Int
    public var text: String
    public var subject: String?
    public var fromName: String?
    public var emailId: String?
    public var messageId: String?
    public var references: String?
    public var verified: Bool?
    public var attachments: [AttachmentInfo]?
    public var raw: String?
    public var pending: Bool?
    public var failed: String?

    public var id: String { rid }

    public struct AttachmentInfo: Codable, Hashable, Sendable { public let name: String; public let type: String; public let size: Int }

    public init(rid: String, conv: String, from: String, mine: Bool, at: Int, kind: Int, text: String) {
        self.rid = rid
        self.conv = conv
        self.from = from
        self.mine = mine
        self.at = at
        self.kind = kind
        self.text = text
    }
}

public struct DeliveryReport: Codable, Hashable, Sendable {
    public var status: String // delivered | failed | delayed | queued
    public var details: String
}

public enum DmReader {
    /// A rumor as a Dm (SPEC 10). KNOWN: mails already placed (for thread assignment).
    public static func dm(from rumor: NostrEvent, me: String, bridge: String?, known: [(messageId: String?, conv: String)]) -> Dm? {
        let mine = rumor.pubkey == me
        if rumor.kind == 14 {
            let conv = MailThreads.nostrConv(author: rumor.pubkey, pTags: rumor.tagValues("p"), me: me)
            return Dm(rid: rumor.id, conv: conv, from: rumor.pubkey, mine: mine, at: rumor.createdAt, kind: 14, text: rumor.content)
        }
        guard rumor.kind == 1301 else { return nil }
        var address: String?
        if mine, let to = rumor.tag("rcpt-to") { address = to.lowercased() }
        else if let from = rumor.tag("mail-from"), rumor.pubkey == bridge { address = from.lowercased() }
        let bridged = rumor.pubkey == bridge && rumor.tag("mail-from") != nil
        var d = Dm(rid: rumor.id, conv: address.map { "m:" + $0 } ?? MailThreads.nostrConv(author: rumor.pubkey, pTags: rumor.tagValues("p"), me: me),
                   from: bridged ? rumor.tag("mail-from")!.lowercased() : rumor.pubkey, mine: mine, at: rumor.createdAt, kind: 1301, text: "")
        d.emailId = rumor.tag("email-id")
        d.subject = rumor.tag("subject")
        d.verified = bridged ? rumor.tag("belfry-auth") == "pass" : true
        let raw = rumor.content
        if raw.isEmpty, rumor.tag("x") != nil {
            d.text = "(This e-mail is stored on the file server.)"
        } else {
            d.raw = raw
            let m = MIME.parse(raw)
            if !m.subject.isEmpty { d.subject = m.subject }
            d.text = m.text
            let name = MIME.address(m.from).name
            d.fromName = name.isEmpty ? nil : name
            d.messageId = m.headers["message-id"]
            d.references = m.headers["references"]
            d.attachments = m.attachments.map { Dm.AttachmentInfo(name: $0.name, type: $0.type, size: $0.data.count) }
            if let a = address {
                d.conv = MailThreads.place(address: a, subject: d.subject, inReplyTo: m.headers["in-reply-to"], references: d.references, known: known)
            }
            return d
        }
        if let a = address { d.conv = MailThreads.thread(address: a, subject: d.subject) }
        return d
    }
}
