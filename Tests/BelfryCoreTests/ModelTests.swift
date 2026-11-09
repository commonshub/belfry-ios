import Foundation
import XCTest
@testable import BelfryCore

final class ModelTests: XCTestCase {
    func testGroups() throws {
        for c in try vector("groups").list("cases") {
            let d = Derive(events: try events(c["events"]), me: c.str("me")!)
            let got = d.groups()
            let want = c.dict("expect").list("groups")
            XCTAssertEqual(got.map(\.id), want.map { $0.str("id")! }, "order")
            for (g, w) in zip(got, want) {
                XCTAssertEqual(g.name, w.str("name"), g.id)
                XCTAssertEqual(g.about, w.str("about"), g.id)
                XCTAssertEqual(g.createdAt, w.int("created_at"), g.id)
                XCTAssertEqual(g.lastActivity, w.int("last_activity"), g.id)
                XCTAssertEqual(g.members.sorted(), w.strs("members"), g.id)
                XCTAssertEqual(g.admins.sorted(), w.strs("admins"), g.id)
                XCTAssertEqual(g.type.rawValue, w.str("type"), g.id)
                XCTAssertEqual(g.parent, w.str("parent"), g.id)
                XCTAssertEqual(g.closed, w["closed"] as? Bool, g.id)
                XCTAssertEqual(g.prompt, w.str("prompt"), g.id)
                XCTAssertEqual(g.applications.map(\.pubkey), w.list("applications").map { $0.str("pubkey")! }, g.id)
                XCTAssertEqual(g.applications.map(\.answer), w.list("applications").map { $0.str("answer")! }, g.id)
            }
        }
    }

    func testMessages() throws {
        for c in try vector("messages").list("cases") {
            let d = Derive(events: try events(c["events"]), me: c.str("me")!)
            let got = d.messages(c.str("group")!)
            let want = c.dict("expect").list("messages")
            XCTAssertEqual(got.map(\.id), want.map { $0.str("id")! })
            for (m, w) in zip(got, want) {
                XCTAssertEqual(m.text, w.str("text"))
                XCTAssertEqual(m.topics, w.strs("topics"))
                let media = w.list("media")
                XCTAssertEqual(m.media.map(\.url), media.map { $0.str("url")! })
                XCTAssertEqual(m.media.map(\.mime), media.map { $0.str("mime")! })
                XCTAssertEqual(m.media.map(\.w), media.map { $0.int("w") })
                XCTAssertEqual(m.media.map(\.name), media.map { $0.str("name") })
            }
        }
    }

    func testReactions() throws {
        for c in try vector("reactions").list("cases") {
            let d = Derive(events: try events(c["events"]), me: c.str("me")!)
            let got = d.reactions(c.str("group")!)
            let want = c.dict("expect").dict("reactions")
            XCTAssertEqual(Set(got.keys), Set(want.keys))
            for (k, list) in want {
                let w = list as? [[String: Any]] ?? []
                let g = got[k] ?? []
                XCTAssertEqual(g.map(\.emoji), w.map { $0.str("emoji")! })
                XCTAssertEqual(g.map { $0.who.sorted() }, w.map { $0.strs("who") })
                XCTAssertEqual(g.map(\.mine), w.map { $0.str("mine") })
            }
        }
    }

    func testThreads() throws {
        for c in try vector("threads").list("cases") {
            let group = c.str("group")!
            let d = Derive(events: try events(c["events"]), me: c.str("me")!)
            let expect = c.dict("expect")
            let th = d.threadsOf(group)
            for (root, info) in expect.dict("threads") {
                let w = info as! [String: Any]
                XCTAssertEqual(th[root]?.count, w.int("count"), c.str("name")!)
                XCTAssertEqual(th[root]?.last, w.int("last"))
                XCTAssertEqual(th[root]?.who, w.strs("who"))
            }
            for (root, ids) in expect.dict("replies") {
                XCTAssertEqual(d.threadReplies(group, root).map(\.id), ids as? [String])
            }
            if let visible = expect["inline_visible"] as? [String] {
                let root = expect.dict("replies").keys.first!
                XCTAssertEqual(Array(d.threadReplies(group, root).suffix(3)).map(\.id), visible)
            }
            let feed = d.feed(group)
            let want = expect.list("feed")
            XCTAssertEqual(feed.count, want.count, c.str("name")!)
            for (item, w) in zip(feed, want) {
                switch item {
                case .message(let m): XCTAssertEqual("msg:" + m.id, "msg:" + (w.str("id") ?? "?"))
                case .join(let j):
                    XCTAssertEqual(w.str("t"), "join")
                    XCTAssertEqual(j.id, w.str("id"))
                    XCTAssertEqual(j.by, w.str("by"))
                case .activity(let root, let last):
                    XCTAssertEqual(w.str("t"), "act")
                    XCTAssertEqual(root.id, w.str("root"))
                    XCTAssertEqual(last.id, w.str("last"))
                }
                XCTAssertEqual(item.at, w.int("at"))
            }
        }
    }

    func testRecentlyActive() throws {
        for c in try vector("recently-active").list("cases") {
            let d = Derive(events: try events(c["events"]), me: c.str("me")!)
            let got = d.recentlyActive(c.str("group")!, now: c.int("now")!)
            let want = c.dict("expect").list("recently_active")
            XCTAssertEqual(got.map(\.pubkey), want.map { $0.str("pubkey")! }, c.str("name")!)
            XCTAssertEqual(got.map(\.at), want.map { $0.int("at")! })
            if let seen = c.dict("expect").int("my_seen") { XCTAssertEqual(d.mySeen(c.str("group")!), seen) }
        }
    }

    func testCanAdmin() throws {
        let v = try vector("can-admin")
        let doc = v.dict("belfry_json")
        let admins = Set((doc.strs("admins") + doc.dict("access").strs("admins")).filter(isHex64))
        let evs = try events(v["events"])
        for c in v.list("cases") {
            let d = Derive(events: evs, me: c.str("me")!, communityAdmins: admins)
            let e = c.dict("expect")
            XCTAssertEqual(d.canAdmin(d.group("g1")), e["g1"] as? Bool, c.str("name")!)
            XCTAssertEqual(d.canAdmin(d.group("g2")), e["g2"] as? Bool, c.str("name")!)
            XCTAssertEqual(d.canAdmin(d.group("nope")), e["unknown"] as? Bool, c.str("name")!)
            XCTAssertEqual(d.isCommunityAdmin, e["is_community_admin"] as? Bool, c.str("name")!)
        }
    }

    func testOutbox() async throws {
        let v = try vector("outbox")
        for c in v.list("classify") {
            XCTAssertEqual(Outbox.classify(c.str("message")!).rawValue, c.str("result"), c.str("message")!)
        }
        for s in v.list("sequences") {
            var items = s.list("items").map {
                OutboxItem(localId: $0.str("localId")!, target: Target(rawValue: $0.str("target")!)!, kind: 9, content: "", tags: [],
                           createdAt: $0.int("created_at")!)
            }
            for r in s.list("rounds") {
                for id in r.strs("retry") {
                    items = items.map { var x = $0; if x.localId == id { x.status = .queued; x.error = nil }; return x }
                }
                let outcomes = r["outcomes"] as? [String: String] ?? [:]
                let result = await OutboxPass.run(items) { item in
                    if let msg = outcomes[item.localId] { return .error(msg) }
                    return .ok(nil)
                }
                let e = r.dict("expect")
                XCTAssertEqual(result.attempted, e.strs("attempted"))
                XCTAssertEqual(result.sent.map(\.item.localId), e.strs("sent"))
                let remaining = e.list("remaining")
                XCTAssertEqual(result.items.map(\.localId), remaining.map { $0.str("localId")! })
                XCTAssertEqual(result.items.map(\.status.rawValue), remaining.map { $0.str("status")! })
                XCTAssertEqual(result.items.map(\.tries), remaining.map { $0.int("tries")! })
                XCTAssertEqual(result.items.map(\.error), remaining.map { $0.str("error") })
                items = result.items
            }
        }
    }

    func testCreatedAtGrows() {
        XCTAssertEqual(Outbox.nextCreatedAt(last: 100, now: 50), 101)
        XCTAssertEqual(Outbox.nextCreatedAt(last: 100, now: 200), 200)
    }

    func testSeenThrottle() {
        XCTAssertFalse(Actions.shouldMarkSeen(now: 10_000, mySeen: 9_000, lastSentHere: 0))
        XCTAssertTrue(Actions.shouldMarkSeen(now: 9_000 + 6 * 3600, mySeen: 9_000, lastSentHere: 0))
        XCTAssertFalse(Actions.shouldMarkSeen(now: 30_000, mySeen: 0, lastSentHere: 29_000))
    }
}

final class TextTests: XCTestCase {
    func testMentions() throws {
        let v = try vector("mentions")
        for c in v.list("mention_tags") {
            XCTAssertEqual(Mentions.tags(c.str("text")!), tags(c["p_tags"]), c.str("text")!)
        }
        let s = v.dict("mention_tags_with_skip")
        XCTAssertEqual(Mentions.tags(s.str("text")!, skip: s.strs("skip")), tags(s["p_tags"]))
        for c in v.list("picker_queries") {
            XCTAssertEqual(Mentions.query(beforeCaret: c.str("before_caret")!), c.str("query"), c.str("before_caret")!)
        }
        for c in v.list("substitutions") {
            let picked = (c["picked"] as? [[String]] ?? []).map { (name: $0[0], pubkey: $0[1]) }
            XCTAssertEqual(Mentions.substitute(c.str("text")!, picked: picked), c.str("sent"))
        }
        for c in v.list("hashtags") {
            XCTAssertEqual(Topics.hashtags(c.str("text")!), c.strs("topics"), c.str("text")!)
        }
    }

    func testActions() throws {
        let v = try vector("actions")
        for c in v.list("slug_examples") where !(c.str("slug") ?? "").hasPrefix("channel-") {
            XCTAssertEqual(Actions.slug(c.str("name")!), c.str("slug"))
        }
        for c in v.list("cases") {
            let a = c.dict("args")
            let want = c.list("events")
            var got = [Draft]()
            switch c.str("action")! {
            case "postMessage":
                got = [Actions.postMessage(a.str("group")!, text: a.str("text")!, topic: a.str("topic"), announce: a["announce"] as? Bool ?? false)]
            case "postThreadReply":
                let r = a.dict("root")
                got = [Actions.postThreadReply(a.str("group")!, rootId: r.str("id")!, rootPubkey: r.str("pubkey")!, rootKind: r.int("kind")!, text: a.str("text")!)]
            case "react":
                let m = a.dict("message")
                got = [Actions.react(a.str("group")!, messageId: m.str("id")!, author: m.str("pubkey")!, emoji: a.str("emoji")!)]
            case "unreact": got = [Actions.unreact(a.str("group")!, reactionId: a.str("reaction")!)]
            case "deleteMessage": got = [Actions.deleteMessage(a.str("group")!, id: a.str("message")!)]
            case "editChannel": got = [Actions.editChannel(a.str("group")!, name: a.str("name")!, about: a.str("about")!)]
            case "setInbox": got = [Actions.setInbox(a.str("group")!, on: a["on"] as? Bool ?? false)]
            case "joinGroup": got = [Actions.join(a.str("group")!)]
            case "leaveGroup": got = [Actions.leave(a.str("group")!)]
            case "createChannel": got = Actions.createChannel(id: a.str("id")!, name: a.str("name")!, about: a.str("about")!)
            case "markSeen": got = [Actions.seen(a.str("group")!)]
            default: XCTFail("unknown action \(c.str("action")!)")
            }
            XCTAssertEqual(got.count, want.count, c.str("action")!)
            for (g, w) in zip(got, want) {
                XCTAssertEqual(g.target.rawValue, w.str("target"), c.str("action")!)
                XCTAssertEqual(g.kind, w.int("kind"), c.str("action")!)
                XCTAssertEqual(g.content, w.str("content"), c.str("action")!)
                XCTAssertEqual(g.tags, tags(w["tags"]), c.str("action")!)
            }
        }
    }

    func testMailThreads() throws {
        let v = try vector("mail-threads")
        for s in v.list("subjects") {
            XCTAssertEqual(MailThreads.baseSubject(s.str("subject")), s.str("base"), s.str("subject")!)
            XCTAssertEqual(MailThreads.thread(address: "Ana@Example.ORG", subject: s.str("subject")), s.str("thread_key_for_ana"), s.str("subject")!)
        }
        for c in v.list("conversations") {
            let conv = c.str("conv")!
            XCTAssertEqual(MailThreads.isNewMail(conv), c["is_new_mail"] as? Bool)
            XCTAssertEqual(MailThreads.isMail(conv), c["is_mail"] as? Bool)
            if let a = c.str("address") { XCTAssertEqual(MailThreads.address(conv), a) }
        }
        for seq in v.list("sequences") {
            var known = [(messageId: String?, conv: String)]()
            for m in seq.list("messages") {
                let conv = MailThreads.place(address: m.str("address")!, subject: m.str("subject"), inReplyTo: m.str("in_reply_to"),
                                             references: m.str("references"), known: known)
                XCTAssertEqual(conv, m.str("expect_conv"), m.str("label")!)
                known.append((m.str("message_id"), conv))
            }
        }
    }

    func testMarkdown() throws {
        for c in try vector("markdown").list("cases") {
            let got = Markdown.parse(c.str("text")!)
            let want = (c["blocks"] as? [[String: Any]] ?? []).map(block)
            XCTAssertEqual(got.map(normalize), want.map(normalize), c.str("text")!)
        }
    }

    func testMIME() throws {
        let v = try vector("mime")
        for c in v.list("mails") {
            let m = MIME.parse(c.str("raw")!)
            let e = c.dict("expect")
            XCTAssertEqual(m.subject, e.str("subject"), c.str("name")!)
            XCTAssertEqual(m.from, e.str("from"), c.str("name")!)
            XCTAssertEqual(m.text, e.str("text"), c.str("name")!)
            XCTAssertEqual(m.full, e.str("full"), c.str("name")!)
            XCTAssertEqual(m.headers["message-id"], e.str("message_id"))
            XCTAssertEqual(m.headers["in-reply-to"], e.str("in_reply_to"))
            XCTAssertEqual(m.headers["references"], e.str("references"))
            XCTAssertEqual(m.attachments.map(\.name), e.list("attachments").map { $0.str("name")! })
            XCTAssertEqual(m.attachments.map(\.data.count), e.list("attachments").map { $0.int("size")! })
        }
        for a in v.list("addresses") {
            let r = MIME.address(a.str("value")!)
            XCTAssertEqual(r.name, a.str("name"))
            XCTAssertEqual(r.address, a.str("address"))
        }
    }

    func testBuildMailRoundTrip() {
        let (raw, id) = MIME.build(fromName: "Zoë", from: "zoe@example.org", to: "ana@example.org", subject: "Re: Café",
                                   text: "Yes **please**", inReplyTo: "<a1@x>", references: "<a0@x>", domain: "example.org")
        let m = MIME.parse(raw)
        XCTAssertEqual(m.subject, "Re: Café")
        XCTAssertEqual(m.text, "Yes **please**")
        XCTAssertEqual(m.headers["message-id"], id)
        XCTAssertEqual(m.headers["references"], "<a0@x> <a1@x>")
        XCTAssertEqual(MIME.address(m.from).name, "Zoë")
    }

    // ---- markdown tree from the vectors ----
    func inl(_ n: [String: Any]) -> MDInline {
        let kids = { (n["c"] as? [[String: Any]] ?? []).map(self.inl) }
        switch n["t"] as? String {
        case "bold": return .bold(kids())
        case "italic": return .italic(kids())
        case "strike": return .strike(kids())
        case "code": return .code(n["v"] as? String ?? "")
        case "link": return .link(href: n["href"] as? String ?? "", kids())
        case "mention": return .mention(npub: n["npub"] as? String ?? "")
        case "topic": return .topic(n["name"] as? String ?? "")
        default: return .text(n["v"] as? String ?? "")
        }
    }

    func block(_ b: [String: Any]) -> MDBlock {
        let lines = { (b["lines"] as? [[[String: Any]]] ?? []).map { $0.map(self.inl) } }
        switch b["type"] as? String {
        case "heading": return .heading(level: b["level"] as? Int ?? 1, (b["c"] as? [[String: Any]] ?? []).map(inl))
        case "list": return .list(ordered: false, (b["items"] as? [[[String: Any]]] ?? []).map { $0.map(inl) })
        case "ordered_list": return .list(ordered: true, (b["items"] as? [[[String: Any]]] ?? []).map { $0.map(inl) })
        case "quote": return .quote(lines())
        case "code": return .code(b["text"] as? String ?? "")
        default: return .paragraph(lines())
        }
    }

    func normalize(_ b: MDBlock) -> MDBlock {
        switch b {
        case .paragraph(let l): return .paragraph(l.map(Markdown.merged))
        case .heading(let lv, let c): return .heading(level: lv, Markdown.merged(c))
        case .list(let o, let items): return .list(ordered: o, items.map(Markdown.merged))
        case .quote(let l): return .quote(l.map(Markdown.merged))
        case .code: return b
        }
    }
}
