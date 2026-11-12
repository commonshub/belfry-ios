import BelfryCore
import Foundation

// Guest mode (SPEC 19.26; collective-belfry docs/guests.md; web village-app b2e968b). A guest link
// opened with no account: this phone makes its session key and uses the link with `{}` (no
// name). One loading screen stays from the link until the channel's stored events are in (or
// the relay said no, or 10 s), then the channel, read-only. Joining = a name and an e-mail, then
// the 6-digit code mailed to it. An address that has an account here: "Sign in instead".

/// The loading screen's line: "Opening # <name>…" (the name from the belfry's answer, never the URL).
struct Opening: Equatable {
    var channel: String?
    var name: String?
}

/// A guest link that can't be used: a fixed message; `closed` = no use trying again.
struct InviteProblem: Equatable {
    let message: String
    let closed: Bool
}

extension AppModel {
    static let openAfterSignInKey = "belfry-open-channel"

    /// Start using a guest link (signed out). Idempotent per token while it runs.
    func openInvite(_ invite: PendingInvite) {
        guard openingToken != invite.token else { return }
        openingToken = invite.token
        inviteProblem = nil
        if opening == nil { opening = Opening() }
        Task { await runOpening(invite) }
    }

    private func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    private func runOpening(_ invite: PendingInvite) async {
        if invite.domain == "demo.belfry.sh" { // the demo: what the belfry would answer, after a moment
            await pause(300)
            opening = Opening(channel: generalId, name: "general")
            await pause(300)
            pendingInvite = nil
            startDemo(reader: true)
            await pause(600)
            opening = nil
            openingToken = nil
            return
        }
        let cfg = (try? await Discovery.fetch(domain: invite.domain)) ?? .defaults(domain: invite.domain)
        let api = BelfryAPI(config: cfg, signer: nil)
        // what the link is (for the loading line, and to say why when it can't be used) …
        let info = Task { () -> Result<InviteInfo, ApiError> in
            do { return .success(try await api.inviteInfo(invite.token)) }
            catch let e as ApiError { return .failure(e) } catch { return .failure(ApiError("http", 0, BelfryAPI.generic)) }
        }
        Task {
            if case .success(let i) = await info.value, i.isOpen, self.opening != nil, self.opening?.name == nil {
                self.opening = Opening(channel: i.channel, name: i.channelName)
            }
        }
        // … while this phone uses it
        do {
            let (j, secret) = try await joinWithNewKey(invite, api: api)
            let s = StoredSession(domain: invite.domain, bunkerURL: j.bunkerURL, clientSecret: secret, pubkey: j.pubkey,
                                  reading: j.reading ? true : nil, guestChannel: j.channel)
            Keychain.save(s)
            pendingInvite = nil
            joinedChannel = j.channel
            if opening?.name == nil { opening = Opening(channel: j.channel, name: nil) }
            open(s, config: cfg)
            if j.emailNeeded { coHostToken = invite.token }
            // until the relay let this key in and sent what it has (or said no), at most 10 s more
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, engine?.access == .unknown { await pause(200) }
        } catch let e as ApiError {
            let problem: InviteProblem
            switch await info.value {
            case .success(let i) where !i.isOpen: problem = InviteProblem(message: i.closedMessage ?? e.message, closed: true)
            case .failure(let f) where f.code == "not_found": problem = InviteProblem(message: f.message, closed: true)
            default: problem = InviteProblem(message: e.message, closed: e.code == "closed" || e.code == "for_agent")
            }
            inviteProblem = problem
        } catch {
            inviteProblem = InviteProblem(message: "Joining did not work just now. Try again.", closed: false)
        }
        opening = nil
        openingToken = nil
    }

    /// One session key per invite in the Keychain until the join works (a retry signs with the same
    /// key and gets the same guest); `session_taken`: once more with a fresh key.
    private func joinWithNewKey(_ invite: PendingInvite, api: BelfryAPI, retried: Bool = false) async throws -> (JoinedNew, String) {
        let keyName = "join-" + invite.token
        let secret = Keychain.string(keyName) ?? {
            let s = Keys.generateSecret().hex
            Keychain.setString(s, keyName)
            return s
        }()
        do {
            let j = try await api.joinAsNew(token: invite.token, sessionSecretHex: secret)
            Keychain.removeString(keyName)
            return (j, secret)
        } catch let e as ApiError where e.code == "session_taken" {
            Keychain.removeString(keyName)
            if retried { throw e }
            return try await joinWithNewKey(invite, api: api, retried: true)
        }
    }

    /// "Try again" on the problem screen.
    func retryInvite() {
        guard let inv = pendingInvite else { return }
        inviteProblem = nil
        openInvite(inv)
    }

    /// "Close" on the problem screen: forget the link.
    func dropInvite() {
        inviteProblem = nil
        pendingInvite = nil
    }

    // ---- joining (the Join sheet) -------------------------------------------------------------------

    /// The channel guest mode opened (for the sheet's title).
    var guestChannel: String? { session?.guestChannel }

    /// Ask for the code: it goes by e-mail to EMAIL. NAME is sent in guest mode (none yet).
    func sendJoinCode(email: String, name: String?) async -> GuestJoinFailure? {
        if isDemo { await pause(400); return nil } // demo: no mail; the code is 123456
        do { try await api.guestSave(email: email, name: name); return nil }
        catch let f as GuestJoinFailure { return f } catch { return GuestJoinFailure(.failed) }
    }

    /// The code from the e-mail: the account is saved under that address (and name).
    func verifyJoinCode(email: String, code: String, name: String?) async -> GuestJoinFailure? {
        if isDemo {
            await pause(400)
            if email.jsTrim().lowercased() == "taken@example.org" { return GuestJoinFailure(.taken, moved: true, nip05: "taken@demo.belfry.sh") }
            if code != "123456" { return GuestJoinFailure(.wrongCode, triesLeft: 4) }
            if guestReading, let name, let e = engine {
                // what the belfry would publish: the 9000 with the name, then the label
                let gk = Demo.signer("groups")
                let ch = guestChannel ?? generalId
                let now = Int.now
                e.add([try! gk.signNow(EventTemplate(kind: 9000, content: "", tags: [["h", ch], ["p", me, "member"], ["guest", "2026-12-12"], ["invited-by", Demo.signer("ana").pubkey], ["name", GuestJoinForm.cleanName(name)]], createdAt: now)),
                       try! gk.signNow(EventTemplate(kind: 1985, content: "", tags: [["h", ch], ["L", "belfry/guest"], ["l", "saved", "belfry/guest"], ["p", me]], createdAt: now + 1))], verify: false)
            }
        } else {
            do { try await api.guestVerify(email: email, code: code, name: name) }
            catch let f as GuestJoinFailure { return f } catch { return GuestJoinFailure(.failed) }
        }
        finishJoining()
        // a co-host link waiting for a proven e-mail: now it makes them a host
        if let t = coHostToken {
            coHostToken = nil
            _ = await joinWithAccount(t)
        }
        await refresh()
        return nil
    }

    /// Joined (or saved): writes go out again, and the session no longer says "reading".
    func finishJoining() {
        engine?.guestMode.reading = false
        guestReading = false
        joinAsked = false
        if var s = Keychain.load(), s.reading == true {
            s.reading = nil
            Keychain.save(s)
        }
        Task { await self.checkPush() }
        version += 1
    }

    /// The address proven in guest mode has an account here: this guest session goes (the belfry
    /// closed it itself when MOVED), the person signs in with the address, and CHANNEL opens after.
    /// The native sign-in's address: the belfry's `nip05` for that account, else the typed e-mail
    /// when it is name@<domain>, else empty with a fixed hint (`signInNote`).
    func signInInstead(channel: String, moved: Bool, nip05: String? = nil, typed: String = "") async {
        if isDemo {
            signOut()
            return
        }
        if !moved, let pk = mySessionKey { _ = await endSession(pk) }
        let domain = config.domain
        let address = GuestJoinForm.signInAddress(nip05: nip05, typed: typed, domain: domain)
        signOut()
        UserDefaults.standard.set(address ?? "", forKey: "last-address")
        signInNote = address == nil ? "Sign in with your address here (name@\(domain)), or with the browser using the e-mail you typed." : nil
        if !channel.isEmpty { UserDefaults.standard.set(channel, forKey: AppModel.openAfterSignInKey) }
        pendingInvite = nil
        inviteSignInFirst = false
        signInDomainHint = domain
    }
}
