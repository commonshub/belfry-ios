import BelfryCore
import Foundation

// Demo mode (-demo or "Try the demo"): a made-up community kept on this device, used by the
// screenshot job in CI. Nothing leaves the device.

typealias Channel = BelfryCore.Group

enum Demo {
    static func secret(_ name: String) -> Data { Crypto.sha256("belfry-ios-demo:" + name) }
    static let meSecret = secret("you")
    static let people: [(String, String)] = [
        ("ana", "Ana Silva"), ("ben", "Ben Okafor"), ("chloe", "Chloé Martin"), ("dev", "Dev Patel"), ("emma", "Emma Lind"),
    ]

    static func signer(_ name: String) -> LocalSigner { try! LocalSigner(secret: secret(name)) }

    static func seed(engine: SyncEngine, dms: DirectMessages) async {
        let me = engine.me
        let now = Int.now
        let day = 86400
        var evs = [NostrEvent]()
        func ev(_ who: LocalSigner, _ kind: Int, _ at: Int, _ tags: [Tag], _ content: String = "") -> NostrEvent {
            try! who.signNow(EventTemplate(kind: kind, content: content, tags: tags, createdAt: at))
        }
        let ps = Dictionary(uniqueKeysWithValues: people.map { ($0.0, signer($0.0)) })
        let relay = signer("relay")
        let groupsKey = signer("groups")
        let you = try! LocalSigner(secret: meSecret)
        evs.append(ev(you, 0, now - 30 * day, [], "{\"name\":\"Sam Rivera\",\"nip05\":\"sam@demo.belfry.sh\"}"))
        for (k, n) in people { evs.append(ev(ps[k]!, 0, now - 30 * day, [], "{\"name\":\"\(n)\",\"nip05\":\"\(k)@demo.belfry.sh\"}")) }
        let all = [me] + people.map { ps[$0.0]!.pubkey }
        func channel(_ id: String, _ name: String, _ about: String, admins: [String], members: [String], at: Int) {
            evs.append(ev(relay, 39000, at, [["d", id], ["name", name], ["about", about]]))
            evs.append(ev(relay, 39001, at, [["d", id]] + admins.map { ["p", $0, "admin"] }))
            evs.append(ev(relay, 39002, at, [["d", id]] + members.map { ["p", $0] }))
        }
        channel("general", "general", "Everything about Riverside Commons. Say hi 👋", admins: [me, ps["ana"]!.pubkey], members: all, at: now - 30 * day)
        channel("garden-3f2a", "Garden", "Beds, seeds and the watering rota", admins: [ps["ben"]!.pubkey], members: all, at: now - 20 * day)
        channel("repair-cafe-91bc", "Repair café", "First Saturday of the month, bring what's broken", admins: [ps["dev"]!.pubkey], members: Array(all.prefix(4)), at: now - 10 * day)
        channel("kitchen-7d10", "Shared kitchen", "Who cooks, who cleans", admins: [ps["emma"]!.pubkey], members: all, at: now - 5 * day)

        func msg(_ who: LocalSigner, _ g: String, _ at: Int, _ text: String) -> NostrEvent {
            let d = Actions.postMessage(g, text: text)
            let e = ev(who, 9, at, d.tags, text)
            evs.append(e)
            return e
        }
        let y = now - day
        let welcome = msg(ps["ana"]!, "general", y - 7200, "Welcome to our belfry! Everything we say here stays on **our own server**.")
        msg(ps["ben"]!, "general", y - 7000, "Finally 🎉 No more group chat in someone else's app.")
        let ladder = msg(ps["chloe"]!, "general", y - 3600, "Does anyone have a long ladder? The gutter above the #garden shed is full of leaves.")
        let mine = msg(you, "general", y - 3000, "I can bring mine on Saturday, it's 4 m.")
        evs.append(ev(you, 1010, y - 2900, Actions.editMessage("general", Derive.parseMedia(mine), text: "I can bring mine on Saturday, it's 5 m.").tags,
                      "I can bring mine on Saturday, it's 5 m."))
        msg(ps["dev"]!, "general", now - 5400, "Reminder: repair café this Saturday from 10:00. Bring lamps, bikes, toasters…\n\n- coffee is on us\n- spare parts welcome")
        let budget = msg(ps["emma"]!, "general", now - 3000, "Draft budget for 2027 is in the shared folder. Comments before Friday please, nostr:\(Bech32.npub(me)!)")
        msg(ps["ana"]!, "general", now - 1200, "Thanks Emma! I'll read it tonight.")
        // a thread on the ladder message, its latest reply after later messages: it resurfaces
        func reply(_ who: LocalSigner, _ root: NostrEvent, _ at: Int, _ text: String) {
            let d = Actions.postThreadReply("general", rootId: root.id, rootPubkey: root.pubkey, text: text)
            evs.append(ev(who, 1111, at, d.tags, text))
        }
        reply(ps["ben"]!, ladder, y - 3300, "Mine is 6 m if Sam's is too short")
        reply(you, ladder, y - 3100, "Let's try mine first")
        reply(ps["chloe"]!, ladder, now - 600, "Done! Gutter is clean, thank you both 🙏")
        reply(ps["dev"]!, budget, now - 2400, "Can we add a line for the repair café tools?")
        func react(_ who: LocalSigner, _ target: NostrEvent, _ emoji: String, _ at: Int) {
            let d = Actions.react("general", messageId: target.id, author: target.pubkey, emoji: emoji)
            evs.append(ev(who, 7, at, d.tags, emoji))
        }
        react(ps["ben"]!, welcome, "🎉", y - 7100)
        react(ps["chloe"]!, welcome, "🎉", y - 7000)
        react(you, welcome, "❤️", y - 6900)
        react(ps["dev"]!, welcome, "❤️", y - 6800)
        react(ps["emma"]!, budget, "👀", now - 2900)
        // a guest joins
        evs.append(ev(groupsKey, 9000, now - 2000, [["h", "general"], ["p", signer("guest").pubkey, "member"], ["guest", "2026-12-09"], ["invited-by", ps["ana"]!.pubkey], ["name", "Lou (neighbour)"]]))
        // seen events: who is active this month
        for (i, k) in ["ana", "ben", "chloe", "dev", "emma"].enumerated() {
            evs.append(ev(ps[k]!, 30078, now - i * 3600, [["d", "seen:general"], ["h", "general"]]))
        }
        // SPEC 19 in the demo: a pin, to-dos, a pod, a proposal under vote, a Belfry event, a channel
        // reference, an announcement, an agent guest, pinned topics
        evs.append(ev(ps["ana"]!, 1985, y - 7000, Actions.pinMessage("general", messageId: welcome.id, pin: true).tags))
        evs.append(ev(you, 2100, now - 2800, Actions.addTask("general", title: "Comment on the 2027 budget", from: budget.id).tags, "Comment on the 2027 budget"))
        let compost = ev(ps["ben"]!, 2100, now - 3 * day, Actions.addTask("general", title: "Order compost for the beds").tags, "Order compost for the beds")
        evs.append(compost)
        evs.append(ev(ps["chloe"]!, 2101, now - 2 * day, Actions.taskAction("general", taskId: compost.id, action: "claim").tags))
        evs.append(ev(ps["dev"]!, 2100, now - day, Actions.addTask("general", title: "Fix the hall's front door lock").tags, "Fix the hall's front door lock"))
        let pod = "pod-seed-swap-5e1d"
        evs.append(ev(ps["ben"]!, 9007, now - 6 * day, [["h", pod]]))
        evs.append(ev(ps["ben"]!, 9002, now - 6 * day, [["h", pod], ["name", "Seed swap"], ["about", "Saving and swapping seeds"], ["closed"], ["prompt", "Which seeds would you bring?"]]))
        channel(pod, "Seed swap", "Saving and swapping seeds", admins: [ps["ben"]!.pubkey], members: [ps["ben"]!.pubkey, ps["chloe"]!.pubkey, ps["emma"]!.pubkey, ps["dev"]!.pubkey], at: now - 6 * day)
        msg(ps["ben"]!, "general", now - 6 * day, "⬡ New pod: Seed swap · Saving and swapping seeds")
        evs[evs.count - 1] = ev(ps["ben"]!, 9, now - 6 * day, [["h", "general"], ["pod", pod]], "⬡ New pod: Seed swap · Saving and swapping seeds")
        msg(ps["chloe"]!, pod, now - 5 * day, "I have three kinds of beans to share 🫘")
        let (pid, pdrafts) = Actions.createProposal(NewProposal(title: "Quiet hours after 22:00", summary: "No loud work in the yard after ten", text: "From Monday to Saturday, no drilling or music in the yard after **22:00**.", status: .voting),
                                                    parent: "general", me: ps["emma"]!.pubkey, groupsRelay: "wss://groups-relay.demo.belfry.sh", mainRelay: "wss://relay.demo.belfry.sh", now: now - 2 * day, x: "7f3a2b")
        let propGroup = pid // prop-quiet-hours-after-22-00-7f3a2b
        var pollId = ""
        for (i, dr) in pdrafts.enumerated() {
            let e = ev(ps["emma"]!, dr.kind, now - 2 * day + i, dr.tags, dr.content)
            evs.append(e)
            if dr.kind == 1068 { pollId = e.id }
        }
        evs.append(ev(ps["ana"]!, 1018, now - day, [["h", propGroup], ["e", pollId], ["response", "yes"]]))
        evs.append(ev(ps["ben"]!, 1018, now - day + 60, [["h", propGroup], ["e", pollId], ["response", "no"]]))
        msg(ps["ana"]!, propGroup, now - day, "Fine by me, but what about the summer party?")
        let dd = "2026-rpcafe"
        let start = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date(timeIntervalSince1970: TimeInterval(now + 2 * day)))!
        var form = EventForm(title: "Repair café")
        form.description = "Bring lamps, bikes, toasters. Coffee is on us."
        form.start = Int(start.timeIntervalSince1970)
        form.end = form.start + 3 * 3600
        form.tz = TimeZone.current.identifier
        form.location = "Community hall"
        form.slug = "repair-cafe"
        for (i, dr) in EventActions.create(form, d: dd, me: ps["dev"]!.pubkey, groupsRelay: "wss://groups-relay.demo.belfry.sh", mainRelay: "wss://relay.demo.belfry.sh").enumerated() {
            evs.append(ev(ps["dev"]!, dr.kind, now - 3 * day + i, dr.tags, dr.content))
        }
        let coord = "31923:\(ps["dev"]!.pubkey):\(dd)"
        evs.append(ev(ps["dev"]!, 9, now - 3 * day + 10, [["h", "general"], ["a", coord, "wss://relay.demo.belfry.sh"]], "Saturday's repair café has its page: https://demo.belfry.sh/events/repair-cafe"))
        evs.append(ev(ps["ana"]!, 31925, now - 2 * day, [["d", "a1"], ["a", coord], ["status", "accepted"], ["p", ps["dev"]!.pubkey]]))
        evs.append(ev(ps["ben"]!, 31925, now - 2 * day, [["d", "b1"], ["a", coord], ["status", "accepted"], ["p", ps["dev"]!.pubkey]]))
        // an event I host, by application, with someone asking
        let dd2 = "2026-gwday1"
        var form2 = EventForm(title: "Garden work day")
        form2.description = "Digging the new beds. Lunch for everyone who helps."
        form2.start = form.start + 5 * day
        form2.end = form2.start + 5 * 3600
        form2.tz = TimeZone.current.identifier
        form2.location = "The garden"
        form2.applicationPrompt = "What can you bring (tools, food)?"
        for (i, dr) in EventActions.create(form2, d: dd2, me: me, groupsRelay: "wss://groups-relay.demo.belfry.sh", mainRelay: "wss://relay.demo.belfry.sh", ticketId: "help").enumerated() {
            evs.append(ev(you, dr.kind, now - 2 * day + i, dr.tags, dr.content))
        }
        evs.append(ev(ps["emma"]!, 9021, now - day, [["h", "ev-" + dd2], ["ticket", dd2 + ":help"]], "Two spades and a quiche"))
        evs.append(ev(you, 9, now - 2 * day + 20, [["h", "garden-3f2a"], ["a", "31923:\(me):\(dd2)", "wss://relay.demo.belfry.sh"]], "Work day next week, by application: https://demo.belfry.sh/events/\(dd2)"))
        let gardenRef = Nip19.naddr(Nip19.Addr(kind: 39000, pubkey: relay.pubkey, identifier: "garden-3f2a", relays: ["wss://groups-relay.demo.belfry.sh"])) ?? ""
        msg(ps["ben"]!, "general", now - 4000, "Seed talk carries on in nostr:\(gardenRef) 🌱")
        let ann = Actions.postMessage("general", text: "The hall is closed on Sunday for cleaning.", announce: true)
        evs.append(ev(ps["ana"]!, 9, now - 5000, ann.tags, ann.content))
        evs.append(ev(groupsKey, 1985, now - 1900, [["h", "general"], ["L", "belfry/guest"], ["l", "saved", "belfry/guest"], ["p", signer("guest").pubkey]]))
        evs.append(ev(groupsKey, 9000, now - 1500, [["h", "general"], ["p", signer("helper").pubkey, "member"], ["invited-by", me], ["agent", "1"], ["name", "Minutes helper"]]))
        evs.append(ev(ps["ana"]!, 1985, now - 10 * day, Actions.setTopics("general", ["garden"]).tags))
        msg(ps["ben"]!, "garden-3f2a", now - 4 * day, "Tomatoes are in. Watering rota: Mon Ana, Wed me, Fri Chloé.")
        msg(ps["chloe"]!, "garden-3f2a", now - 2 * day, "The basil did not survive the cold night 🥲")
        msg(ps["dev"]!, "repair-cafe-91bc", now - 3 * day, "Who can fix a **sewing machine**? Asking for Mrs. Dupont.")
        msg(ps["emma"]!, "kitchen-7d10", now - 6 * 3600, "Soup on Thursday, I need two helpers to chop.")
        engine.add(evs, verify: false)
        engine.add([ev(you, 30078, now - 3 * day, [["d", "seen:general"], ["h", "general"]])], verify: false)

        dms.myAddress = "sam@demo.belfry.sh"
        try? await dms.demoDM(from: ps["ana"]!, text: "Hi Sam! Can you open the hall on Saturday at 9?", at: now - 7200)
        try? await dms.demoDM(from: ps["dev"]!, text: "I found the spare bike parts you asked about.", at: now - 2 * day)
        try? await dms.demoMail(bridgeSecret: secret("bridge"), sender: "\"Town Hall\" <events@townhall.example>", subject: "Street party permit",
                                text: "Hello,\n\nYour request for the street party on 14 June is approved.\n\nKind regards,\nTown Hall", at: now - 5 * 3600)
        await dms.process()
    }
}
