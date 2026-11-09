import Foundation

// Conversation keys for direct messages and e-mail threads (SPEC 10), from src/core/dm.ts.
//   n:<pubkey>[,<pubkey>…]   a Nostr conversation (sorted keys, me excluded)
//   m:<address>|<subject key> an e-mail thread
//   m:<address>              a new e-mail, a thread once sent

public enum MailThreads {
    static let prefix = Rx("^\\s*((re|fwd?|aw|sv|tr|wg|antw|rif|r)\\s*(\\[\\d+\\])?\\s*:\\s*)+", [.caseInsensitive])
    static let spaces = Rx("\\s+")
    static let messageIds = Rx("<[^<>\\s]+>")

    public static func baseSubject(_ s: String?) -> String {
        prefix.replace(s ?? "", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// encodeURIComponent, as JavaScript does it.
    public static func encodeURIComponent(_ s: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
        var out = ""
        for b in s.utf8 {
            if allowed.contains(b) { out.unicodeScalars.append(Unicode.Scalar(b)) } else { out += String(format: "%%%02X", b) }
        }
        return out
    }

    public static func subjectKey(_ s: String?) -> String {
        let k = encodeURIComponent(spaces.replace(baseSubject(s).lowercased(), with: " "))
        return k.isEmpty ? "-" : k
    }

    public static func thread(address: String, subject: String?) -> String {
        "m:" + address.lowercased() + "|" + subjectKey(subject)
    }

    public static func isMail(_ conv: String) -> Bool { conv.hasPrefix("m:") }
    public static func isNewMail(_ conv: String) -> Bool { conv.hasPrefix("m:") && !conv.contains("|") }

    public static func address(_ conv: String) -> String {
        String(conv.dropFirst(2).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    public static func peers(_ conv: String) -> [String] {
        conv.hasPrefix("n:") ? conv.dropFirst(2).split(separator: ",").map(String.init) : []
    }

    public static func nostrConv(author: String, pTags: [String], me: String) -> String {
        var people = Set([author] + pTags)
        people.remove(me)
        let list = people.sorted()
        return "n:" + (list.isEmpty ? me : list.joined(separator: ","))
    }

    public static func ids(_ header: String?) -> [String] {
        messageIds.matches(header ?? "").map(\.whole)
    }

    /// The thread a mail joins: the one its In-Reply-To (first) or References (last to first)
    /// name among KNOWN mails with the same address, else the thread of its subject.
    public static func place(address: String, subject: String?, inReplyTo: String?, references: String?,
                             known: [(messageId: String?, conv: String)]) -> String {
        let a = address.lowercased()
        let refs = (ids(references) + ids(inReplyTo)).reversed()
        for id in refs {
            for k in known where k.messageId == id && isMail(k.conv) && MailThreads.address(k.conv) == a { return k.conv }
        }
        return thread(address: a, subject: subject)
    }
}
