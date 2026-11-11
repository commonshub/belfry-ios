import BelfryCore
import Foundation
import Security
import SwiftUI
import UIKit

// People and joining (SPEC 19.4, 19.5, 19.15, 19.16): guest links (join as someone new, join
// with an account, save the account), profiles (name, about, picture, username, tags, place),
// the admin switch, a member's own agents, signed-in devices, sign-out that ends the session,
// follows, drop box links. Every server error comes back as a fixed message.

private final class Flag { var on = false }

extension AppModel {
    // ---- guest links ----------------------------------------------------------------------------

    /// A guest link opened (https://chat.<domain>/join/<token>): only its domain and token are kept.
    func handle(url: URL) {
        if handleEventURL(url) { return }
        guard let (domain, token) = InviteLink.parse(url) else { return }
        pendingInvite = PendingInvite(domain: domain, token: token)
    }

    /// Join as someone new (not signed in): one session key per invite, kept until the join works.
    func joinAsNew(_ invite: PendingInvite, name: String) async -> String? {
        let cfg = (try? await Discovery.fetch(domain: invite.domain)) ?? .defaults(domain: invite.domain)
        let api = BelfryAPI(config: cfg, signer: nil)
        let keyName = "join-" + invite.token
        let secret = Keychain.string(keyName) ?? {
            let s = Keys.generateSecret().hex
            Keychain.setString(s, keyName)
            return s
        }()
        do {
            let j = try await api.joinAsNew(token: invite.token, name: name, sessionSecretHex: secret)
            Keychain.removeString(keyName)
            let s = StoredSession(domain: invite.domain, bunkerURL: j.bunkerURL, clientSecret: secret, pubkey: j.pubkey)
            Keychain.save(s)
            pendingInvite = nil
            joinedChannel = j.channel
            open(s, config: cfg)
            if j.emailNeeded { coHostToken = invite.token }
            return nil
        } catch let e as ApiError {
            if e.code == "session_taken" { Keychain.removeString(keyName) }
            return e.message
        } catch {
            return BelfryAPI.generic
        }
    }

    /// Someone signed in uses a guest link: their account gets the channel (no second account).
    func joinWithAccount(_ token: String) async -> String? {
        if engine?.localOnly == true { pendingInvite = nil; joinedChannel = generalId; return nil }
        do {
            let j = try await api.joinWithAccount(token: token)
            pendingInvite = nil
            joinedChannel = j.channel
            await refresh()
            return nil
        } catch let e as ApiError {
            return e.message
        } catch {
            return BelfryAPI.generic
        }
    }

    /// Am I a guest whose account has no e-mail yet ("save your account").
    var unsavedGuest: Bool {
        let joins = derive.guestJoinsOf(me)
        return !joins.isEmpty && joins.allSatisfy(\.unsaved)
    }

    func guestSave(email: String) async -> String? {
        if engine?.localOnly == true { return nil }
        do { try await api.guestSave(email: email); return nil } catch let e as ApiError { return e.message } catch { return BelfryAPI.generic }
    }

    func guestVerify(email: String, code: String) async -> String? {
        if engine?.localOnly == true { return nil }
        do {
            try await api.guestVerify(email: email, code: code)
            if let t = coHostToken {
                coHostToken = nil
                if let e = await joinWithAccount(t) { return e }
            }
            return nil
        } catch let e as ApiError { return e.message } catch { return BelfryAPI.generic }
    }

    // ---- guest links I make ---------------------------------------------------------------------

    func makeGuestLink(_ channel: String, people: Int, linkDays: Int, agent: Bool = false, role: String? = nil) async -> Result<GuestLink, ApiError> {
        if engine?.localOnly == true {
            let url = "https://chat.\(config.domain)/join/demo\(agent ? "agent" : "guest")link0123456789abcd"
            return .success(GuestLink(url: url, agentURL: agent ? "https://belfry.\(config.domain)/invite/demoagentlink0123456789.md" : nil,
                                      days: agent ? 0 : 30, people: people, linkDays: linkDays, expiresAt: nil, ownAgent: agent))
        }
        do { return .success(try await api.createGuestLink(channel: channel, people: people, linkDays: linkDays, agent: agent, role: role)) }
        catch let e as ApiError { return .failure(e) }
        catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    // ---- profiles -------------------------------------------------------------------------------

    /// Name and about in my kind 0 (its other fields kept), and a new picture when given.
    func saveProfile(name: String, about: String, picture: Data?) async -> String? {
        var url: String?
        if let picture {
            guard let engine else { return "Not signed in." }
            if engine.localOnly {
                url = nil
            } else {
                do { url = try await engine.upload(picture, name: "avatar.jpg", mime: "image/jpeg", sha: Crypto.sha256(picture).hex) }
                catch { return "The picture could not be uploaded. Try again." }
            }
        }
        engine?.enqueue(Actions.saveProfile(current: derive.myProfileJSON, name: name, about: about, nip05: derive.profiles()[me]?.nip05, picture: url))
        return nil
    }

    /// My address here (username@domain); the belfry changes it and its nip05 in my profile.
    func setUsername(_ username: String) async -> String? {
        let u = username.jsTrim().lowercased()
        if u.isEmpty { return "A username is 1 to 30 lowercase letters, digits, dots, dashes or underscores." }
        if engine?.localOnly == true {
            engine?.enqueue(Actions.saveProfile(current: derive.myProfileJSON, name: realName(me), about: derive.aboutOf(me), nip05: u + "@" + config.domain))
            return nil
        }
        do {
            let n = try await api.setUsername(u)
            engine?.enqueue(Actions.saveProfile(current: derive.myProfileJSON, name: realName(me), about: derive.aboutOf(me), nip05: n))
            return nil
        } catch let e as ApiError { return e.message } catch { return BelfryAPI.generic }
    }

    func saveExtras(tags: [String], share: Share, place: Place?) {
        engine?.enqueue(Actions.saveExtras(tags: tags, share: share, place: place))
    }

    func searchPlaces(_ q: String) async -> [Place] {
        if engine?.localOnly != false { return People.demoPlaces(q) }
        return (try? await api.searchPlaces(q))?.places ?? []
    }

    func addPlace(name: String, country: String, near: String) async -> Result<Place, ApiError> {
        if engine?.localOnly != false {
            let n = People.demoPlaces.first { $0.placeId == near }
            return .success(Place(country: country, id: "b:demo", name: name, lat: n?.lat, lon: n?.lon))
        }
        do { return .success(try await api.addPlace(name: name, country: country, nearId: near)) }
        catch let e as ApiError { return .failure(e) }
        catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    /// "Admin of the belfry" (belfry admins only); belfry.json is read again after.
    func setAdmin(_ pk: String, _ on: Bool) async -> String? {
        if let reason = derive.noAdminReason(pk), on { return reason }
        if engine?.localOnly != false {
            var c = config
            if on { if !c.admins.contains(pk) { c.admins.append(pk) } } else { c.admins.removeAll { $0 == pk } }
            config = c
            version += 1
            return nil
        }
        do {
            try await api.setAdmin(pk, admin: on)
            await revalidateConfig(force: true)
            return nil
        } catch let e as ApiError { return e.message } catch { return BelfryAPI.generic }
    }

    // ---- a member's own agents ------------------------------------------------------------------

    func myAgents() async -> MyAgents? {
        if engine?.localOnly != false { return MyAgents(agents: [], limit: 1) }
        return try? await api.myAgents()
    }

    func setMyAgent(_ pk: String, mine: Bool) async -> String? {
        if engine?.localOnly != false {
            var c = config
            var a = c.agents
            if mine { a[pk] = me } else { a[pk] = nil }
            c.agentsMap = a
            config = c
            version += 1
            return nil
        }
        do {
            _ = try await api.setMyAgent(pk, mine: mine)
            await revalidateConfig(force: true)
            await askWhois([pk])
            return nil
        } catch let e as ApiError { return e.message } catch { return BelfryAPI.generic }
    }

    /// "Make it my agent": a guest agent, I am a member (not a guest or an agent), I invited it or am an admin.
    func mayMakeMine(_ pk: String) -> Bool {
        let d = derive
        guard d.agentOwner(pk) == nil, d.isAgent(pk), d.isGuest(pk), !d.isGuest(me), !d.isAgent(me) else { return false }
        return d.isCommunityAdmin || d.guestJoinsOf(pk).contains { $0.by == me }
    }

    // ---- sessions and sign-out ------------------------------------------------------------------

    func sessions() async -> Result<[SessionInfo], ApiError> {
        if engine?.localOnly != false {
            return .success([SessionInfo(applicationName: "Belfry for iPhone", device: "iPhone", redirectOrigin: "sh.belfry.app://connect",
                                         bunkerPubkey: String(repeating: "0", count: 64), createdAt: "2026-11-01", lastActivity: "2026-11-11")])
        }
        do { return .success(try await api.sessions()) }
        catch let e as ApiError { return .failure(e) }
        catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    /// This device's session: the bunker URL's key.
    var mySessionKey: String? { session?.bunkerURL.flatMap(BunkerURL.init)?.remotePubkey }

    func endSession(_ pk: String) async -> String? {
        if engine?.localOnly != false { return nil }
        do { try await api.revokeSession(pk); return nil } catch let e as ApiError { return e.message } catch { return BelfryAPI.generic }
    }

    /// Sign out: end this device's session on the belfry (best effort, 3 s), then wipe the phone.
    func signOutEverywhere() async {
        await removePushDevice()
        if let s = session, !s.demo, let pk = mySessionKey {
            let api = self.api
            let f = Flag()
            Task { try? await api.revokeSession(pk); await MainActor.run { f.on = true } }
            var waited = 0
            while !f.on && waited < 30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
        }
        signOut()
    }

    // ---- follows (e-mails of a channel's announcements) -----------------------------------------

    func follow(_ channel: String) async -> String? {
        if engine?.localOnly != false { return demoFollows[channel] }
        return (try? await api.follows())?.byChannel[channel]
    }

    /// CHOICE: asap | monthly | stop. Returns the frequency now in force (nil: not following) or an error.
    func setFollow(_ channel: String, _ choice: String) async -> Result<String?, ApiError> {
        if engine?.localOnly != false {
            demoFollows[channel] = choice == "stop" ? nil : choice
            return .success(demoFollows[channel])
        }
        do { return .success(try await api.setFollow(channel: channel, choice: choice)) }
        catch let e as ApiError { return .failure(e) }
        catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    // ---- drop box links -------------------------------------------------------------------------

    @discardableResult
    func createDropLink(_ group: String, days: Int, login: Bool) -> String {
        let (token, d) = Actions.createDropLink(group, days: days, login: login, now: .now)
        engine?.enqueue(d)
        return token
    }

    func endDropLink(_ l: DropLink) { engine?.enqueue(Actions.endDropLink(l)) }
}

/// A guest link waiting to be used (kept through sign-in; only its domain and token).
struct PendingInvite: Codable, Equatable, Identifiable {
    let domain: String
    let token: String
    var id: String { token }
}

extension Keychain {
    static func setString(_ value: String, _ account: String) {
        removeString(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".keys",
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func string(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".keys",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func removeString(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".keys", kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

enum Images {
    /// A picture as JPEG, at most MAX pixels on its longer side.
    static func jpeg(_ data: Data, max: CGFloat) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        let k = min(1, max / Swift.max(w, h))
        let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return out.jpegData(compressionQuality: 0.85)
    }
}
