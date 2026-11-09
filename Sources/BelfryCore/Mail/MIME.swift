import Foundation

// Just enough MIME (RFC 2045-2047) for Nostr Mail (kind 1301): read the text, subject, sender and
// attachments; write a plain-text + HTML answer. From src/core/mime.ts; vectors/mime.json.

public struct MailPart: Hashable, Sendable { public let name: String; public let type: String; public let data: Data }

public struct ParsedMail: Sendable {
    public var headers: [String: String]
    public var subject: String
    public var from: String
    /// The new text: quoted history removed.
    public var text: String
    /// The whole text, history included.
    public var full: String
    public var attachments: [MailPart]
}

public enum MIME {
    static func decode(_ bytes: Data, charset: String = "utf-8") -> String {
        let cs = charset.lowercased()
        if cs == "utf-8" || cs == "utf8" || cs.isEmpty { return String(decoding: bytes, as: UTF8.self) }
        let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
        if cf != kCFStringEncodingInvalidId {
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let s = String(data: bytes, encoding: enc) { return s }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func b64(_ s: String) -> Data {
        var clean = Rx("[^A-Za-z0-9+/=]").replace(s, with: "")
        clean = clean.replacingOccurrences(of: "=", with: "")
        while clean.count % 4 != 0 { clean += "=" }
        return Data(base64Encoded: clean) ?? Data()
    }

    static func qp(_ input: String, header: Bool = false) -> Data {
        var s = input
        if header { s = s.replacingOccurrences(of: "_", with: " ") }
        s = Rx("=\\r?\\n").replace(s, with: "")
        var out = [UInt8]()
        let u = Array(s.unicodeScalars)
        var i = 0
        func hexv(_ c: Unicode.Scalar) -> UInt8? {
            switch c.value {
            case 48...57: return UInt8(c.value - 48)
            case 65...70: return UInt8(c.value - 55)
            case 97...102: return UInt8(c.value - 87)
            default: return nil
            }
        }
        while i < u.count {
            if u[i] == "=", i + 2 < u.count, let h = hexv(u[i + 1]), let l = hexv(u[i + 2]) {
                out.append(h << 4 | l)
                i += 3
                continue
            }
            out += Array(String(u[i]).utf8)
            i += 1
        }
        return Data(out)
    }

    /// RFC 2047 encoded words.
    public static func decodeWords(_ v: String) -> String {
        let joined = Rx("\\?=\\s+=\\?").replace(v, with: "?==?")
        let re = Rx("=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=")
        var out = ""
        var last = 0
        let ns = joined as NSString
        for m in re.matches(joined) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let cs = Rx("\\*.*$").replace(m[1] ?? "utf-8", with: "")
            let enc = (m[2] ?? "B").uppercased()
            let bytes = enc == "B" ? b64(m[3] ?? "") : qp(m[3] ?? "", header: true)
            out += decode(bytes, charset: cs)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func split(_ raw: String) -> (String, String) {
        if let m = Rx("\\r?\\n\\r?\\n").first(raw) {
            let ns = raw as NSString
            return (ns.substring(to: m.range.location), ns.substring(from: m.range.location + m.range.length))
        }
        return (raw, "")
    }

    static func headers(_ block: String) -> [String: String] {
        var h = [String: String]()
        let unfolded = Rx("\\r?\\n[ \\t]+").replace(block, with: " ")
        for line in unfolded.components(separatedBy: "\n") {
            let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard let i = l.firstIndex(of: ":"), i != l.startIndex else { continue }
            let k = l[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            if h[k] == nil { h[k] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        return h
    }

    static func escapeRx(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

    static func param(_ header: String?, _ name: String) -> String {
        guard let header else { return "" }
        if let star = Rx(";\\s*\(name)\\*=([^';]*)'[^']*'([^;]*)", [.caseInsensitive]).first(header) {
            let v = star[2] ?? ""
            return v.removingPercentEncoding ?? v
        }
        if let m = Rx(";\\s*\(name)=(\"([^\"]*)\"|[^;]*)", [.caseInsensitive]).first(header) {
            return decodeWords((m[2] ?? m[1] ?? "").trimmingCharacters(in: .whitespaces))
        }
        return ""
    }

    static func body(_ h: [String: String], _ b: String) -> Data {
        switch (h["content-transfer-encoding"] ?? "").lowercased() {
        case "base64": return b64(b)
        case "quoted-printable": return qp(b)
        default: return Data(b.utf8)
        }
    }

    struct Walk { var text = ""; var html = ""; var attachments = [MailPart]() }

    static func walk(_ raw: String, _ out: inout Walk, depth: Int = 0) {
        let (hb, b) = split(raw)
        let h = headers(hb)
        let ct = h["content-type"] ?? "text/plain"
        let type = ct.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        if type.hasPrefix("multipart/"), depth < 8 {
            let boundary = param(ct, "boundary")
            guard !boundary.isEmpty else { return }
            let sep = Rx("\\r?\\n?--\(escapeRx(boundary))(?:--)?[ \\t]*\\r?\\n?")
            var parts = [String]()
            var last = 0
            let ns = b as NSString
            for m in sep.matches(b) {
                parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
                last = m.range.location + m.range.length
            }
            parts.append(ns.substring(from: last))
            for p in parts.dropFirst() where !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { walk(p, &out, depth: depth + 1) }
            return
        }
        let disposition = h["content-disposition"] ?? ""
        let fname = param(disposition, "filename")
        let name = fname.isEmpty ? param(ct, "name") : fname
        let attached = disposition.lowercased().hasPrefix("attachment") || (!name.isEmpty && !type.hasPrefix("text/"))
        if attached || !type.hasPrefix("text/") {
            if type != "message/delivery-status" { out.attachments.append(MailPart(name: name.isEmpty ? "attachment" : name, type: type, data: body(h, b))) }
            return
        }
        let cs = param(ct, "charset")
        let text = decode(body(h, b), charset: cs.isEmpty ? "utf-8" : cs)
        if type == "text/html" { if out.html.isEmpty { out.html = text } } else if out.text.isEmpty { out.text = text }
    }

    /// HTML as plain text (no DOM on the device: tags stripped, blocks become lines).
    public static func htmlText(_ html: String) -> String {
        var s = Rx("<(script|style|blockquote)[^>]*>[\\s\\S]*?</\\1>", [.caseInsensitive]).replace(html, with: "")
        s = Rx("<br\\s*/?>", [.caseInsensitive]).replace(s, with: "\n")
        s = Rx("</(p|div|li|tr|h\\d)>", [.caseInsensitive]).replace(s, with: "$0\n")
        s = Rx("<[^>]+>").replace(s, with: "")
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s
    }

    static let quoteHeader = Rx("^\\s*(On .{4,200} wrote:|Le .{4,200} a écrit\\s?:|-----\\s*Original Message\\s*-----)\\s*$")

    /// The new text of a reply: no quoted lines, nothing after "On … wrote:".
    public static func withoutQuote(_ text: String) -> String {
        var out = [String]()
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if quoteHeader.test(line) { break }
            if line.hasPrefix(">") { continue }
            out.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        let joined = Rx("\\n{3,}").replace(out.joined(separator: "\n"), with: "\n\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parse(_ raw: String) -> ParsedMail {
        let (hb, _) = split(raw)
        let h = headers(hb)
        var w = Walk()
        walk(raw, &w)
        let body = w.text.isEmpty ? htmlText(w.html) : w.text
        return ParsedMail(
            headers: h,
            subject: decodeWords(h["subject"] ?? ""),
            from: decodeWords(h["from"] ?? ""),
            text: withoutQuote(body),
            full: body.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: w.attachments
        )
    }

    /// "Ana <ana@x.org>" → ("Ana", "ana@x.org")
    public static func address(_ v: String) -> (name: String, address: String) {
        if let m = Rx("^\\s*\"?([^\"<]*?)\"?\\s*<([^>]+)>\\s*$").first(v) {
            return ((m[1] ?? "").trimmingCharacters(in: .whitespaces), (m[2] ?? "").trimmingCharacters(in: .whitespaces).lowercased())
        }
        return ("", v.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func isASCII(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7e } }
    static func word(_ s: String) -> String { isASCII(s) ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?=" }
    static func wrap76(_ s: String) -> String {
        var out = [String](), cur = Substring(s)
        while cur.count > 76 { out.append(String(cur.prefix(76))); cur = cur.dropFirst(76) }
        out.append(String(cur))
        return out.joined(separator: "\r\n")
    }

    /// An e-mail (UTF-8) ready for the bridge: the text as written and as Markdown rendered.
    public static func build(fromName: String, from: String, to: String, subject: String, text: String,
                             inReplyTo: String? = nil, references: String? = nil, domain: String,
                             date: Date = Date()) -> (raw: String, messageId: String) {
        let messageId = "<\(UUID().uuidString.lowercased())@\(domain)>"
        let name = fromName.replacingOccurrences(of: "[\"\\\\\\r\\n]", with: "", options: .regularExpression)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"
        var h = [
            "From: \(name.isEmpty ? "" : (isASCII(name) ? "\"\(name)\"" : word(name)) + " ")<\(from)>",
            "To: <\(to)>",
            "Subject: \(word(subject.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)))",
            "Date: \(df.string(from: date))",
            "Message-ID: \(messageId)",
        ]
        if let irt = inReplyTo {
            h.append("In-Reply-To: \(irt)")
            h.append("References: \([references, irt].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))")
        }
        h.append("MIME-Version: 1.0")
        let boundary = "b" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        func part(_ type: String, _ body: String) -> String {
            "--\(boundary)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(wrap76(Data(body.utf8).base64EncodedString()))\r\n"
        }
        h.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
        let html = "<!doctype html><html><body>\(Markdown.html(text))</body></html>"
        let body = part("text/plain", text) + part("text/html", html) + "--\(boundary)--\r\n"
        return (h.joined(separator: "\r\n") + "\r\n\r\n" + body, messageId)
    }
}
