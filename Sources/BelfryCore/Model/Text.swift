import Foundation

// Regex helpers that behave like the web chat's JavaScript (UTF-16 offsets, like JS strings),
// hashtags, mentions and the composer's @ picker.

public struct Rx: @unchecked Sendable {
    public let re: NSRegularExpression
    public init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    public struct Match {
        public let ns: NSString
        public let result: NSTextCheckingResult
        public var range: NSRange { result.range }
        /// Group N's text, nil when it did not take part (JS undefined).
        public subscript(_ i: Int) -> String? {
            guard i < result.numberOfRanges else { return nil }
            let r = result.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        public var whole: String { ns.substring(with: result.range) }
    }

    public func matches(_ s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { Match(ns: ns, result: $0) }
    }

    public func first(_ s: String) -> Match? {
        let ns = s as NSString
        return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)).map { Match(ns: ns, result: $0) }
    }

    public func test(_ s: String) -> Bool { first(s) != nil }

    public func replace(_ s: String, with template: String) -> String {
        let ns = s as NSString
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }
}

public enum Topics {
    public static let hashtag = Rx("(^|[^\\p{L}\\p{N}_&/])#([\\p{L}\\p{N}_][\\p{L}\\p{N}_-]{0,48})")
    public static func norm(_ t: String) -> String {
        let l = t.lowercased()
        return l.hasPrefix("#") ? String(l.dropFirst()) : l
    }

    /// The hashtags of a text, lowercased, deduplicated, in order.
    public static func hashtags(_ text: String) -> [String] {
        var seen = Set<String>(), out = [String]()
        for m in hashtag.matches(text) {
            let t = norm(m[2] ?? "")
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}

public enum Mentions {
    public static let npubInText = Rx("nostr:(npub1[02-9ac-hj-np-z]{58})")
    public static let pickerQuery = Rx("(^|\\s)@([\\p{L}\\p{N}_.-]{0,30})$")

    /// p tags for the people a text mentions (nostr:npub…), deduplicated, first appearance first.
    public static func tags(_ text: String, skip: [String] = []) -> [Tag] {
        var seen = Set<String>(), out = [Tag]()
        for m in npubInText.matches(text) {
            guard let npub = m[1], let hex = Bech32.pubkey(npub: npub), !skip.contains(hex) else { continue }
            if seen.insert(hex).inserted { out.append(["p", hex]) }
        }
        return out
    }

    /// The query of an open @ picker, given the text before the caret; nil when none is open.
    public static func query(beforeCaret: String) -> String? {
        pickerQuery.first(beforeCaret)?[2]
    }

    /// The composer's text as sent: each picked "@Name" (longest names first) → nostr:npub….
    public static func substitute(_ text: String, picked: [(name: String, pubkey: String)]) -> String {
        var out = text
        for p in picked.sorted(by: { $0.name.utf16.count > $1.name.utf16.count }) {
            guard let npub = Bech32.npub(p.pubkey) else { continue }
            out = out.components(separatedBy: "@" + p.name).joined(separator: "nostr:" + npub)
        }
        return out
    }
}

/// Folding for search: accents and case ignored.
public func fold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
}
