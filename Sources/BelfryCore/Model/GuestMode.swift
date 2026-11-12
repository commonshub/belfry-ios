import Foundation

// Guest mode (SPEC 19.26; collective-belfry docs/guests.md, web village-app b2e968b
// core/guestmode.ts + core/guestjoin.ts). Someone who opened a guest link without an account
// reads its channel at once, with no name. Nothing they do is sent until they join (a name, an
// e-mail and the 6-digit code mailed to it). The relay does not enforce this: the app does, at the
// places everything goes through (the outbox, signed HTTP calls, direct messages), and each
// refusal opens the Join sheet.

/// Something that writes was refused because this device is only reading as a guest.
public struct GuestModeRefused: Error, Equatable, LocalizedError {
    public init() {}
    public static let message = "Join to do this: you are reading as a guest."
    public var errorDescription: String? { GuestModeRefused.message }
}

/// The switch every write checks. `reading` is set by the app from the stored session; `onRefused`
/// opens the Join sheet (called on any thread).
public final class GuestModeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    public var onRefused: (() -> Void)?

    public init(reading: Bool = false) { on = reading }

    public var reading: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); on = newValue; lock.unlock() }
    }

    /// True (and the Join sheet asked for) when a write must not go out.
    @discardableResult
    public func refuse() -> Bool {
        guard reading else { return false }
        onRefused?()
        return true
    }

    /// Throws for any write while reading.
    public func check() throws {
        if refuse() { throw GuestModeRefused() }
    }

    /// Throws for an HTTP call that writes while reading (reads and joining itself pass).
    public func check(url: String, method: String) throws {
        guard reading, !GuestModeGate.allowsWhileReading(url: url, method: method) else { return }
        onRefused?()
        throw GuestModeRefused()
    }

    /// What the belfry may be asked while reading: any GET; joining itself (`/guest/save`,
    /// `/guest/save/verify`), using a link (`/channel-invites/<token>/join`), ending this session
    /// (`/me/sessions/revoke`) and asking who people are (`/whois`, a read sent as a POST).
    public static func allowsWhileReading(url: String, method: String) -> Bool {
        if method.uppercased() == "GET" { return true }
        let path = URL(string: url)?.path ?? ""
        return allowedPath.test(path)
    }

    static let allowedPath = Rx("/(guest/save(/verify)?|me/sessions/revoke|channel-invites/[^/]+/join|whois)$")
}

/// What joining from guest mode can answer (`POST /guest/save`, `/guest/save/verify`), by the
/// server's `error` code. The messages are this app's own fixed words (web JOIN_ERRORS).
public enum GuestJoinError: String, Error, CaseIterable, Sendable {
    case invalid, nameNeeded = "name_needed", tooMany = "too_many", wrongCode = "wrong_code", expired, taken
    case notGuest = "not_guest", offline, failed

    public var message: String {
        switch self {
        case .invalid: return "That doesn’t look like an e-mail address."
        case .nameNeeded: return "Your name is needed to join."
        case .tooMany: return "Too many codes for now. Try again in half an hour."
        case .wrongCode: return "That code is not right. Check the e-mail and try again."
        case .expired: return "That code has expired. Send a new one."
        case .taken: return "This address already has an account here."
        case .notGuest: return "This guest access has ended. Ask for a new invite."
        case .offline: return "No connection. Try again."
        case .failed: return "That did not work. Try again."
        }
    }

    /// The server's code (unknown codes: `failed`).
    public init(code: String) { self = GuestJoinError(rawValue: code) ?? .failed }
}

/// A refusal of `/guest/save` or `/guest/save/verify`. `moved`: with `taken`, the belfry gave the
/// address's account the channel and closed this guest (sign in with the address).
public struct GuestJoinFailure: Error, Equatable, LocalizedError {
    public let error: GuestJoinError
    public let moved: Bool
    /// `wrong_code`: how many tries the code has left (collective-belfry d2b4c52).
    public let triesLeft: Int?
    /// `taken`: that account's address here (`name@domain`), when the belfry could read it.
    public let nip05: String?
    public init(_ error: GuestJoinError, moved: Bool = false, triesLeft: Int? = nil, nip05: String? = nil) {
        self.error = error; self.moved = moved; self.triesLeft = triesLeft; self.nip05 = nip05
    }
    public var errorDescription: String? { display }

    /// The text to show: a wrong code says how many tries are left (as the native sign-in does).
    public var display: String {
        guard error == .wrongCode, let n = triesLeft else { return error.message }
        if n <= 0 { return "That code is not right. Ask for a new one." }
        if n == 1 { return "That code is not right. 1 try left." }
        return "That code is not right. \(n) tries left."
    }
}

public enum GuestJoinForm {
    /// A name as it is sent: trimmed, inner spaces folded, at most 100 UTF-16 units (web `clean`).
    public static func cleanName(_ name: String) -> String {
        Rx("\\s+").replace(name.jsTrim(), with: " ").sliceUnits(100)
    }

    /// The e-mail field is worth sending (web: /^\S+@\S+\.\S+$/ on the trimmed text).
    public static func looksLikeEmail(_ s: String) -> Bool { Rx("^\\S+@\\S+\\.\\S+$").test(s.jsTrim()) }

    /// The address to put in the native sign-in after "Sign in instead" (SPEC 19.26): the
    /// belfry's `nip05` for that account when it is name@DOMAIN, else the typed e-mail when it is
    /// such an address, else nil (the field stays empty, with a fixed hint).
    public static func signInAddress(nip05: String?, typed: String, domain: String) -> String? {
        let d = domain.lowercased()
        for c in [nip05, typed] {
            guard let a = c?.jsTrim().lowercased(), !a.isEmpty else { continue }
            let parts = a.split(separator: "@", omittingEmptySubsequences: false)
            if parts.count == 2, parts[1] == Substring(d), Rx("^[a-z0-9._-]{1,64}$").test(String(parts[0])) { return a }
        }
        return nil
    }

    /// What the Join sheet's first step needs before Continue unlocks.
    public static func canContinue(name: String, email: String, askName: Bool) -> Bool {
        (!askName || !cleanName(name).isEmpty) && looksLikeEmail(email)
    }
}
