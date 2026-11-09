import Foundation

// The Markdown subset (SPEC 9) as a tree, never as HTML in the chat. Ported line for line from
// the web chat's markdown.tsx (blocks, inline) and Topics.tsx (mentions and #topics in plain
// text); vectors/markdown.json pins the behaviour, quirks included.

public indirect enum MDInline: Hashable, Sendable {
    case text(String)
    case bold([MDInline])
    case italic([MDInline])
    case strike([MDInline])
    case code(String)
    case link(href: String, [MDInline])
    case mention(npub: String)
    case topic(String)
}

public enum MDBlock: Hashable, Sendable {
    case paragraph([[MDInline]]) // lines
    case heading(level: Int, [MDInline])
    case list(ordered: Bool, [[MDInline]])
    case quote([[MDInline]])
    case code(String)
}

public enum Markdown {
    static let safeURL = Rx("^(https?://|mailto:)", [.caseInsensitive])
    static let inlineRx = Rx("(\\*\\*([^*]+)\\*\\*|__([^_]+)__|`([^`]+)`|~~([^~]+)~~|\\[([^\\]]+)\\]\\(([^)\\s]+)\\)|\\*([^*\\s][^*]*)\\*|_([^_\\s][^_]*)_|(https?://[^\\s<>()]+[^\\s<>().,;:!?'\"]))")
    static let richRx = Rx("nostr:(npub1[02-9ac-hj-np-z]{58})|(^|[^\\p{L}\\p{N}_&/])#([\\p{L}\\p{N}_][\\p{L}\\p{N}_-]{0,48})")
    static let fence = Rx("^```")
    static let heading = Rx("^(#{1,3})\\s+(.*)$")
    static let listItem = Rx("^\\s*([-*+]|\\d+[.)])\\s+")
    static let ordered = Rx("^\\s*\\d+[.)]\\s+")
    static let quote = Rx("^>\\s?")
    static let paraStop = Rx("^(#{1,3}\\s|>\\s?|\\s*([-*+]|\\d+[.)])\\s+)")

    public typealias Plain = (String) -> [MDInline]
    public static let asIs: Plain = { [.text($0)] }

    /// Plain text with @mentions (nostr:npub…) and #topics, as chat messages show it.
    public static let rich: Plain = { t in
        var out = [MDInline]()
        let ns = t as NSString
        var last = 0
        for m in richRx.matches(t) {
            if let npub = m[1] {
                if m.range.location > last { out.append(.text(ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
                out.append(.mention(npub: npub))
                last = m.range.location + m.range.length
            } else {
                let pre = (m[2] ?? "") as NSString
                let at = m.range.location + pre.length
                if at > last { out.append(.text(ns.substring(with: NSRange(location: last, length: at - last)))) }
                let name = m[3] ?? ""
                out.append(.topic(name))
                last = at + 1 + (name as NSString).length
            }
        }
        if last < ns.length { out.append(.text(ns.substring(from: last))) }
        return out
    }

    public static func inline(_ text: String, _ plain: Plain) -> [MDInline] {
        var out = [MDInline]()
        let ns = text as NSString
        var last = 0
        for m in inlineRx.matches(text) {
            if m.range.location > last { out += plain(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            if let b = m[2] ?? m[3] { out.append(.bold(inline(b, plain))) }
            else if let c = m[4] { out.append(.code(c)) }
            else if let s = m[5] { out.append(.strike(inline(s, plain))) }
            else if let label = m[6], let href = m[7] {
                out.append(safeURL.test(href) ? .link(href: href, inline(label, asIs)) : .text(m.whole))
            } else if let i = m[8] ?? m[9] { out.append(.italic(inline(i, plain))) }
            else if let url = m[10] { out.append(.link(href: url, [.text(url)])) }
            last = m.range.location + m.range.length
        }
        if last < ns.length { out += plain(ns.substring(from: last)) }
        return out
    }

    public static func parse(_ text: String, plain: Plain = rich) -> [MDBlock] {
        var blocks = [MDBlock]()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let src = normalized.components(separatedBy: "\n")
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var i = 0
        while i < src.count {
            let line = src[i]
            if blank(line) { i += 1; continue }
            if fence.test(line) {
                var code = [String]()
                i += 1
                while i < src.count, !fence.test(src[i]) { code.append(src[i]); i += 1 }
                i += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if let h = heading.first(line) {
                blocks.append(.heading(level: (h[1] ?? "#").count, inline(h[2] ?? "", plain)))
                i += 1
                continue
            }
            if listItem.test(line) {
                let isOrdered = ordered.test(line)
                var items = [String]()
                while i < src.count, listItem.test(src[i]) { items.append(listItem.replace(src[i], with: "")); i += 1 }
                blocks.append(.list(ordered: isOrdered, items.map { inline($0, plain) }))
                continue
            }
            if quote.test(line) {
                var q = [String]()
                while i < src.count, quote.test(src[i]) { q.append(quote.replace(src[i], with: "")); i += 1 }
                blocks.append(.quote(q.map { inline($0, plain) }))
                continue
            }
            var p = [String]()
            while i < src.count, !blank(src[i]), !paraStop.test(src[i]) { p.append(src[i]); i += 1 }
            blocks.append(.paragraph(p.map { inline($0, plain) }))
        }
        return blocks
    }

    // ---- e-mail HTML (markdownHtml in mime.ts): escaped first, links only http(s) and mailto -----

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func htmlInline(_ t: String) -> String {
        var s = esc(t)
        s = Rx("`([^`]+)`").replace(s, with: "<code style=\"background:#f4f4f5;padding:1px 4px;border-radius:4px\">$1</code>")
        s = Rx("\\*\\*([^*]+)\\*\\*").replace(s, with: "<strong>$1</strong>")
        s = Rx("__([^_]+)__").replace(s, with: "<strong>$1</strong>")
        s = Rx("~~([^~]+)~~").replace(s, with: "<s>$1</s>")
        s = Rx("\\[([^\\]]+)\\]\\(((?:https?://|mailto:)[^)\\s]+)\\)").replace(s, with: "<a href=\"$2\">$1</a>")
        s = Rx("(^|[^\"=>])(https?://[^\\s<>()]+[^\\s<>().,;:!?'\"])").replace(s, with: "$1<a href=\"$2\">$2</a>")
        s = Rx("(^|[\\s(])\\*([^*\\s][^*]*)\\*").replace(s, with: "$1<em>$2</em>")
        s = Rx("(^|[\\s(])_([^_\\s][^_]*)_").replace(s, with: "$1<em>$2</em>")
        return s
    }

    public static func html(_ md: String) -> String {
        var out = [String]()
        for b in parse(md, plain: asIs) {
            switch b {
            case .code(let c): out.append("<pre style=\"background:#f4f4f5;padding:8px;border-radius:6px\">\(esc(c))</pre>")
            case .heading(_, let c): out.append("<p><strong>\(htmlInline(plainText(c)))</strong></p>")
            case .list(let o, let items):
                let lis = items.map { "<li>\(htmlInline(plainText($0)))</li>" }.joined()
                out.append(o ? "<ol>\(lis)</ol>" : "<ul>\(lis)</ul>")
            case .quote(let lines):
                out.append("<blockquote style=\"border-left:3px solid #d4d4d8;margin:0;padding-left:10px;color:#52525b\">\(lines.map { htmlInline(plainText($0)) }.joined(separator: "<br>"))</blockquote>")
            case .paragraph(let lines): out.append("<p>\(lines.map { htmlInline(plainText($0)) }.joined(separator: "<br>"))</p>")
            }
        }
        return "<div style=\"font-family:-apple-system,Segoe UI,Roboto,sans-serif;font-size:15px;line-height:1.5\">\(out.joined(separator: "\n"))</div>"
    }

    /// The source text back from inline nodes (for HTML rendering and previews).
    public static func plainText(_ nodes: [MDInline]) -> String {
        nodes.map { n -> String in
            switch n {
            case .text(let s): return s
            case .bold(let c): return "**" + plainText(c) + "**"
            case .italic(let c): return "*" + plainText(c) + "*"
            case .strike(let c): return "~~" + plainText(c) + "~~"
            case .code(let s): return "`" + s + "`"
            case .link(let href, let c):
                let label = plainText(c)
                return label == href ? href : "[\(label)](\(href))"
            case .mention(let npub): return "nostr:" + npub
            case .topic(let t): return "#" + t
            }
        }.joined()
    }

    /// Merges adjacent text nodes (vectors are compared this way).
    public static func merged(_ nodes: [MDInline]) -> [MDInline] {
        var out = [MDInline]()
        for n in nodes {
            let m: MDInline
            switch n {
            case .bold(let c): m = .bold(merged(c))
            case .italic(let c): m = .italic(merged(c))
            case .strike(let c): m = .strike(merged(c))
            case .link(let h, let c): m = .link(href: h, merged(c))
            default: m = n
            }
            if case .text(let b) = m, case .text(let a)? = out.last {
                out[out.count - 1] = .text(a + b)
            } else if case .text(let s) = m, s.isEmpty {
                continue
            } else {
                out.append(m)
            }
        }
        return out
    }
}
