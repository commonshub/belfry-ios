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
        msg(you, "general", y - 3000, "I can bring mine on Saturday, it's 4 m.")
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
