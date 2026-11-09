import Foundation

// Every user action as the event(s) it queues (SPEC 7-13), before the client tag is appended and
// before signing. Mirrors the web chat's src/core/actions.ts; checked against vectors/actions.json.

public enum Target: String, Codable, Sendable { case groups, main }

public struct Draft: Hashable, Sendable {
    public var target: Target
    public var kind: Int
    public var content: String
    public var tags: [Tag]

    public init(_ target: Target = .groups, kind: Int, content: String = "", tags: [Tag]) {
        self.target = target
        self.kind = kind
        self.content = content
        self.tags = tags
    }
}

public enum Actions {
    public static let defaultEmojis = ["👍", "❤️", "😂", "🎉", "🙏", "👀"]

    public static func slug(_ name: String, random: () -> String = { Crypto.random(3).hex }) -> String {
        let folded = name.lowercased().decomposedStringWithCompatibilityMapping
        var s = Rx("[^a-z0-9]+").replace(folded, with: "-")
        s = Rx("^-|-$").replace(s, with: "")
        s = String(s.prefix(32))
        return s.isEmpty ? "channel-" + random() : s
    }

    public static func createChannel(id: String, name: String, about: String) -> [Draft] {
        [Draft(kind: 9007, tags: [["h", id]]),
         Draft(kind: 9002, tags: [["h", id], ["name", name], ["about", about]])]
    }

    public static func newChannelId(_ name: String) -> String { slug(name) + "-" + Crypto.random(2).hex }

    public static func editChannel(_ id: String, name: String, about: String) -> Draft {
        Draft(kind: 9002, tags: [["h", id], ["name", name], ["about", about]])
    }

    public static func join(_ id: String, answer: String = "") -> Draft {
        Draft(kind: 9021, content: String(answer.prefix(2000)), tags: [["h", id]])
    }

    public static func leave(_ id: String) -> Draft { Draft(kind: 9022, tags: [["h", id]]) }

    public static func postMessage(_ group: String, text: String, topic: String? = nil, announce: Bool = false) -> Draft {
        var topics = [String]()
        for t in (topic.map { [Topics.norm($0)] } ?? []) + (announce ? [Derive.announcement] : []) + Topics.hashtags(text) where !topics.contains(t) {
            topics.append(t)
        }
        return Draft(kind: 9, content: text, tags: [["h", group]] + topics.map { ["t", $0] } + Mentions.tags(text))
    }

    public static func postThreadReply(_ group: String, rootId: String, rootPubkey: String, rootKind: Int = 9, text: String) -> Draft {
        let k = String(rootKind)
        var tags: [Tag] = [["h", group], ["E", rootId, "", rootPubkey], ["K", k], ["P", rootPubkey],
                           ["e", rootId, "", rootPubkey], ["k", k], ["p", rootPubkey]]
        tags += Topics.hashtags(text).map { ["t", $0] }
        tags += Mentions.tags(text, skip: [rootPubkey])
        return Draft(kind: 1111, content: text, tags: tags)
    }

    public static func react(_ group: String, messageId: String, author: String, emoji: String) -> Draft {
        Draft(kind: 7, content: emoji, tags: [["h", group], ["e", messageId], ["p", author], ["k", "9"]])
    }

    public static func unreact(_ group: String, reactionId: String) -> Draft {
        Draft(kind: 5, tags: [["h", group], ["e", reactionId], ["k", "7"]])
    }

    public static func deleteMessage(_ group: String, id: String) -> Draft {
        Draft(kind: 5, tags: [["h", group], ["e", id]])
    }

    public static func setInbox(_ group: String, on: Bool) -> Draft {
        Draft(kind: 30078, content: on ? "{\"on\":true}" : "{\"on\":false}", tags: [["d", Derive.inboxD], ["h", group]])
    }

    public static func seen(_ group: String) -> Draft {
        Draft(kind: 30078, tags: [["d", Derive.seenD(group)], ["h", group]])
    }

    /// Whether to send a seen event now: at most every 6 hours per channel.
    public static func shouldMarkSeen(now: Int, mySeen: Int, lastSentHere: Int) -> Bool {
        now - max(mySeen, lastSentHere) >= 6 * 3600
    }

    /// NIP-98 HTTP auth event for URL / METHOD / BODY.
    public static func httpAuth(url: String, method: String, body: Data?, now: Int = .now) -> EventTemplate {
        var tags: [Tag] = [["u", url], ["method", method]]
        if let body, !body.isEmpty { tags.append(["payload", Crypto.sha256(body).hex]) }
        return EventTemplate(kind: 27235, content: "", tags: tags, createdAt: now)
    }

    /// Blossom BUD-02 upload authorization.
    public static func blossomAuth(sha256: String, name: String, now: Int = .now) -> EventTemplate {
        EventTemplate(kind: 24242, content: "Upload " + name, tags: [["t", "upload"], ["x", sha256], ["expiration", String(now + 600)]], createdAt: now)
    }

    /// NIP-42 relay authentication.
    public static func relayAuth(relay: String, challenge: String, now: Int = .now) -> EventTemplate {
        EventTemplate(kind: 22242, content: "", tags: [["relay", relay], ["challenge", challenge]], createdAt: now)
    }
}
