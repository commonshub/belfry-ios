import Foundation

// Signing in without a browser (SPEC 19.20; collective-belfry sessions.py): the member's address
// name@domain, a 6-digit code by e-mail, then a NIP-46 session bound to this device's session
// key. Two calls, NIP-98 signed by that key:
//
//     POST <sign_in.sessions.api>         {"nip05","app","client"}  → {"state":"code_sent","to","nip05"}
//     POST <sign_in.sessions.api>/verify  {"code"}                  → {"state":"open","bunker_url","pubkey",…}
//
// Nothing the belfry writes is shown: its `error` key picks one of this file's fixed messages.
// Port of the Android app's core/net/NativeSignIn.kt and Onboarding.requestCode / verifyCode.

/// What a person types to sign in: `name@domain`, their address in their community.
public struct MemberAddress: Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public let domain: String

    public init(name: String, domain: String) { self.name = name; self.domain = domain }

    public var description: String { name + "@" + domain }

    /// Nil unless RAW is one name, one `@`, and a hostname (trimmed, lower-cased).
    public static func parse(_ raw: String) -> MemberAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = s.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[0], domain = parts[1]
        // every character is checked by hand: a regex's `$` also matches before a last newline
        guard (1...64).contains(name.unicodeScalars.count), name.unicodeScalars.allSatisfy(isNameScalar),
              let first = name.unicodeScalars.first, first != ".", first != "_", first != "-",
              domain.unicodeScalars.allSatisfy(isHostScalar), Discovery.isDomain(domain) else { return nil }
        return MemberAddress(name: name, domain: domain)
    }

    static func isNameScalar(_ u: Unicode.Scalar) -> Bool {
        (u >= "a" && u <= "z") || (u >= "0" && u <= "9") || u == "." || u == "_" || u == "-"
    }

    static func isHostScalar(_ u: Unicode.Scalar) -> Bool {
        (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || (u >= "0" && u <= "9") || u == "." || u == "-"
    }
}

/// The reasons the native sign-in can stop for. The message is ours, chosen by the belfry's
/// `error` key: never the server's own text.
public enum SessionFailure: Error, Equatable, Sendable {
    case notAnAddress
    /// No belfry.json at the domain typed (validated as a hostname before it gets here).
    case noBelfry(String)
    case unknownMember, noEmail, invalid, tooMany, unauthorized
    case wrongCode, expired, ownKey, mismatch, keyTaken, notApproved
    /// 503 `signer`: the belfry's signer did not answer the belfry. The code is spent.
    case signer
    /// The right code, but this phone could not reach the signer yet: "Try again" reconnects.
    case connect
    /// An older belfry without this API: the browser sign-in works there.
    case unsupported
    case network, other

    public var message: String {
        switch self {
        case .notAnAddress: return "Type your address like name@belfry.sh."
        case .noBelfry(let domain): return "There is no belfry at \(domain). Check the address and your connection."
        case .unknownMember: return "No member has this address. Check the name before the @."
        case .noEmail: return "This account has no e-mail address to send a code to. Ask an admin of your community."
        case .invalid: return "Type your address like name@belfry.sh."
        case .tooMany: return "Too many codes were asked for. Try again in half an hour."
        case .unauthorized: return "The belfry did not accept this request. Check the date and time of this phone, then try again."
        case .wrongCode: return "That code is not right."
        case .expired: return "That code has expired. Ask for a new one."
        case .ownKey: return "You hold your own key: this app can’t sign you in yet."
        case .mismatch: return "This address changed while you were signing in. Start again."
        case .keyTaken: return "This phone’s sign-in key is linked to another account. Start again: a new one is made."
        case .notApproved: return "This app is not approved on this belfry yet. Ask an admin to approve it."
        case .signer: return "The belfry’s signer is not answering. Send a new code and try again."
        case .connect: return "The belfry’s signer did not answer this phone. Check your connection and try again."
        case .unsupported: return "This belfry can’t sign you in here yet. Sign in with the browser instead."
        case .network: return "No connection to the belfry. Check your connection and try again."
        case .other: return "Not signed in. Please try again."
        }
    }

    /// After these the belfry has forgotten the request (or it can never work): screen 1 again.
    public var endsTheRequest: Bool {
        switch self {
        case .expired, .keyTaken, .ownKey, .mismatch, .notApproved: return true
        default: return false
        }
    }
}

public struct SessionError: Error, Equatable, Sendable {
    public let failure: SessionFailure
    public let triesLeft: Int?

    public init(_ failure: SessionFailure, triesLeft: Int? = nil) { self.failure = failure; self.triesLeft = triesLeft }

    /// The text to show: for a wrong code, with how many tries are left.
    public var display: String {
        guard failure == .wrongCode, let n = triesLeft else { return failure.message }
        if n <= 0 { return "That code is not right. Ask for a new one." }
        if n == 1 { return "That code is not right. 1 try left." }
        return "That code is not right. \(n) tries left."
    }
}

/// The belfry mailed a code. `to` is the masked address, only when it looks like one.
public struct CodeSent: Equatable, Sendable {
    public let to: String?
    public let nip05: String?
}

/// The right code: the NIP-46 session, bound to the key that signed the requests.
public struct SessionOpened: Equatable, Sendable {
    public let bunkerURL: String
    public let pubkey: String
}

public struct NativeSignIn: Sendable {
    public static let app = "sh.belfry.app://connect"

    /// belfry.json `sign_in.sessions.api`: the full address of the session endpoint.
    public let endpoint: String
    public let session: URLSession
    public let clock: @Sendable () -> Int

    public init(endpoint: String, session: URLSession = .shared, clock: @escaping @Sendable () -> Int = { Int.now }) {
        self.endpoint = endpoint
        self.session = session
        self.clock = clock
    }

    public func request(_ address: MemberAddress, sessionSecretHex: String) async throws -> CodeSent {
        let body = "{\"nip05\":\(JSON.string(address.description)),\"app\":\(JSON.string(NativeSignIn.app)),\"client\":\(JSON.string(SignIn.clientId))}"
        let (status, obj) = try await post(endpoint, body, sessionSecretHex)
        if status == 200, obj?["state"] as? String == "code_sent" {
            let to = (obj?["to"] as? String).flatMap { NativeSignIn.isMaskedAddress($0) ? $0 : nil }
            return CodeSent(to: to, nip05: (obj?["nip05"] as? String).flatMap(MemberAddress.parse)?.description)
        }
        throw SessionError(NativeSignIn.failure(status: status, body: obj, verifying: false))
    }

    public func verify(_ code: String, sessionSecretHex: String) async throws -> SessionOpened {
        guard NativeSignIn.isCode(code) else { throw SessionError(.wrongCode) }
        let (status, obj) = try await post(endpoint + "/verify", "{\"code\":\(JSON.string(code))}", sessionSecretHex)
        if status == 200, obj?["state"] as? String == "open", let bunker = obj?["bunker_url"] as? String, BunkerURL(bunker) != nil,
           let pubkey = (obj?["pubkey"] as? String)?.lowercased(), isHex64(pubkey) {
            return SessionOpened(bunkerURL: bunker, pubkey: pubkey)
        }
        let f = NativeSignIn.failure(status: status, body: obj, verifying: true)
        let tries = f == .wrongCode ? (obj?["tries_left"] as? NSNumber).map { min(max($0.intValue, 0), 9) } : nil
        throw SessionError(f, triesLeft: tries)
    }

    private func post(_ url: String, _ text: String, _ secretHex: String) async throws -> (Int, [String: Any]?) {
        let body = Data(text.utf8)
        guard let u = URL(string: url), u.scheme == "https", let signer = try? LocalSigner(secretHex: secretHex),
              let auth = try? signer.signNow(Actions.httpAuth(url: url, method: "POST", body: body, now: NativeSignIn.stamp(clock()))) else {
            throw SessionError(.other)
        }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Nostr " + Data(auth.json.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw SessionError(.network) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    // ---- the checks -------------------------------------------------------------------------------

    private static let stampLock = NSLock()
    nonisolated(unsafe) private static var lastStamp = 0

    /// `created_at` of a NIP-98 event: the belfry accepts each signed event once, so two calls in
    /// the same second (a resend, a quick retry) must not carry the same second.
    static func stamp(_ now: Int) -> Int {
        stampLock.lock()
        defer { stampLock.unlock() }
        lastStamp = max(lastStamp + 1, now)
        return lastStamp
    }

    static func isDigit(_ u: Unicode.Scalar) -> Bool { u >= "0" && u <= "9" }

    public static func isCode(_ s: String) -> Bool { s.unicodeScalars.count == 6 && s.unicodeScalars.allSatisfy(isDigit) }

    /// What six code boxes hold after their field changed from OLD to RAW (web `nextCode`,
    /// Android `NativeSignIn.next`, #issues 2026-11-13): the digits of RAW when there are at most
    /// six ("123 456", "Code: 123456"); a whole code pasted over a full row (or after some digits)
    /// replaces it (what was added past OLD, when that is six digits or more); one more digit typed
    /// into a full row changes nothing. The field itself has no length limit: a limit would cut a
    /// paste before its digits were picked.
    public static func next(old: String, raw: String) -> String {
        let d = String(String.UnicodeScalarView(raw.unicodeScalars.filter(isDigit)))
        if d.unicodeScalars.count <= 6 { return d }
        let added = d.hasPrefix(old) ? String(d.unicodeScalars.dropFirst(old.unicodeScalars.count)) : d
        return String((added.unicodeScalars.count >= 6 ? added : d).unicodeScalars.prefix(6))
    }

    /// The six digits in what was typed or pasted ("123 456", "Your code: 123456"), else what
    /// digits there are (at most six). ASCII digits only.
    public static func digits(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        for u in raw.unicodeScalars where isDigit(u) {
            out.append(u)
            if out.count == 6 { break }
        }
        return String(out)
    }

    /// Is this the belfry's masked address (`x•••@example.org`: one character, three dots, a
    /// hostname)? Only then is it shown; anything else reads "your e-mail address".
    public static func isMaskedAddress(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        let dot: Unicode.Scalar = "\u{2022}"
        guard s.utf16.count <= 260, u.count >= 6, u[0].value < 0x10000, u[0] != "@", u[0] != dot,
              !CharacterSet.whitespacesAndNewlines.contains(u[0]), u[1] == dot, u[2] == dot, u[3] == dot, u[4] == "@" else { return false }
        let host = u[5...]
        guard host.allSatisfy(MemberAddress.isHostScalar) else { return false }
        return Discovery.isDomain(String(String.UnicodeScalarView(host)))
    }

    static func failure(status: Int, body: [String: Any]?, verifying: Bool) -> SessionFailure {
        guard let key = body?["error"] as? String else {
            switch status {
            // no `error` key: not this API's answer (an older belfry, or a proxy's page)
            case 404, 405, 501: return .unsupported
            case 429: return .tooMany
            case 401: return .unauthorized
            default: return .other
            }
        }
        switch key {
        case "unknown": return .unknownMember
        case "no_email": return .noEmail
        case "invalid", "app_address", "invalid_json": return verifying ? .other : .invalid
        case "too_many": return .tooMany
        case "unauthorized": return .unauthorized
        case "wrong_code": return .wrongCode
        case "expired": return .expired
        case "own_key": return .ownKey
        case "mismatch": return .mismatch
        case "key_taken": return .keyTaken
        case "app_not_approved": return .notApproved
        case "signer": return .signer
        default: return status == 429 ? .tooMany : .other
        }
    }
}

// ---- the flow, kept across the app being killed ---------------------------------------------------

/// Small secrets by name (the app: the Keychain; tests: memory).
public protocol Vault: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
}

public final class MemoryVault: Vault, @unchecked Sendable {
    private let lock = NSLock()
    private var values = [String: String]()
    public init() {}
    public func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ key: String, _ value: String) { lock.lock(); values[key] = value; lock.unlock() }
    public func remove(_ key: String) { lock.lock(); values[key] = nil; lock.unlock() }
}

/// What screen 2 shows: the address typed and, when the belfry gave a well-formed one, the masked e-mail.
public struct PendingCode: Equatable, Sendable {
    public let address: String
    public let to: String?
    public init(address: String, to: String?) { self.address = address; self.to = to }
}

/// A finished native sign-in: what the app stores as its session.
public struct NativeSession: Equatable, Sendable {
    public let config: BelfryConfig
    public let bunkerURL: String
    /// This device's session key: signed the two calls, and is the NIP-46 client key from now on.
    public let clientSecretHex: String
    public let pubkey: String
}

/// The native sign-in in progress, in the vault: this device's session key and, once the code was
/// right, the session to connect to.
struct NativeFlowState: Codable, Equatable {
    var config: BelfryConfig
    var address: String
    var secret: String
    var to: String?
    var sentAt: Int = 0
    var bunkerURL: String?
    var pubkey: String?

    /// Nil unless every field still passes the checks it passed when it was written.
    static func read(_ text: String?) -> NativeFlowState? {
        guard let text, var s = try? JSONDecoder().decode(NativeFlowState.self, from: Data(text.utf8)),
              let a = MemberAddress.parse(s.address), a.description == s.address, isHex64(s.secret) else { return nil }
        if let to = s.to, !NativeSignIn.isMaskedAddress(to) { s.to = nil }
        if let b = s.bunkerURL, BunkerURL(b) == nil { s.bunkerURL = nil }
        if let p = s.pubkey, !isHex64(p) { s.pubkey = nil }
        return s
    }

    var text: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}

public final class NativeSignInFlow: @unchecked Sendable {
    public static let vaultKey = "native-signin"
    /// The belfry keeps a request for 15 minutes (a code for 10): after that, screen 1 again.
    public static let codeSeconds = 900

    public typealias Discover = @Sendable (String) async throws -> BelfryConfig
    /// Connects to the signer with the session key and returns the key it signs for (`get_public_key`).
    public typealias Connect = @Sendable (BunkerURL, String) async throws -> String

    private let vault: Vault
    private let session: URLSession
    private let clock: @Sendable () -> Int
    private let discover: Discover
    private let connect: Connect

    public init(vault: Vault, session: URLSession = .shared, clock: @escaping @Sendable () -> Int = { Int.now },
                discover: Discover? = nil, connect: Connect? = nil) {
        self.vault = vault
        self.session = session
        self.clock = clock
        self.discover = discover ?? { domain in try await Discovery.fetch(domain: domain, session: session) }
        self.connect = connect ?? NativeSignInFlow.askSigner
    }

    /// The signer's own answer, over NIP-46 with the session key.
    public static let askSigner: Connect = { bunker, secretHex in
        guard let secret = Data(hex: secretHex) else { throw BelfryError.signer("bad key") }
        let signer = try BunkerSigner(bunker: bunker, clientSecret: secret, pubkey: nil)
        defer { signer.disconnect() }
        return try await signer.ensurePubkey()
    }

    private func state() -> NativeFlowState? { NativeFlowState.read(vault.get(NativeSignInFlow.vaultKey)) }
    private func keep(_ s: NativeFlowState) { vault.set(NativeSignInFlow.vaultKey, s.text) }

    /// A sign-in waiting for its code (the person left the app to read the e-mail).
    public var pending: PendingCode? {
        guard let s = state(), s.sentAt > 0, clock() - s.sentAt < NativeSignInFlow.codeSeconds else { return nil }
        return PendingCode(address: s.address, to: s.to)
    }

    /// Screen 1: finds the belfry at the address's domain, makes this device's session key (the
    /// same key for a resend or a second try) and asks the belfry to mail a code.
    /// Throws `SessionError`; `.unsupported` = offer the browser sign-in.
    public func requestCode(_ raw: String) async throws -> PendingCode {
        guard let a = MemberAddress.parse(raw) else { throw SessionError(.notAnAddress) }
        let config: BelfryConfig
        // the domain is what the person typed, checked as a hostname by MemberAddress.parse
        do { config = try await discover(a.domain) } catch { throw SessionError(.noBelfry(a.domain)) }
        guard let endpoint = config.sessionAPI else { throw SessionError(.unsupported) }
        let kept = state().flatMap { $0.address == a.description && $0.bunkerURL == nil ? $0 : nil }
        let secret = kept?.secret ?? Keys.generateSecret().hex
        // kept before asking, so a retry after a lost answer signs with the same key
        keep(NativeFlowState(config: config, address: a.description, secret: secret, to: kept?.to, sentAt: kept?.sentAt ?? 0))
        let sent: CodeSent
        do {
            sent = try await NativeSignIn(endpoint: endpoint, session: session, clock: clock).request(a, sessionSecretHex: secret)
        } catch let e as SessionError {
            if e.failure == .keyTaken { cancel() }
            throw e
        }
        keep(NativeFlowState(config: config, address: a.description, secret: secret, to: sent.to, sentAt: clock()))
        return PendingCode(address: a.description, to: sent.to)
    }

    /// "Send a new code": the first request again, signed by the same key.
    public func resendCode() async throws -> PendingCode {
        guard let s = state() else { throw SessionError(.expired) }
        return try await requestCode(s.address)
    }

    /// Back to screen 1, or the code expired: forget the request (the address is the screen's to keep).
    public func cancel() { vault.remove(NativeSignInFlow.vaultKey) }

    /// Screen 2: the six digits. With the right code the belfry opens a NIP-46 session bound to
    /// this device's session key; the signer is asked for its key, which must be the one the
    /// belfry named. The bunker address is kept until the signer has answered: the code is spent,
    /// so a second call after `.connect` reconnects without a second verify.
    public func verifyCode(_ code: String) async throws -> NativeSession {
        guard var s = state() else { throw SessionError(.expired) }
        if s.bunkerURL == nil || s.pubkey == nil {
            guard let endpoint = s.config.sessionAPI else { cancel(); throw SessionError(.expired) }
            let opened: SessionOpened
            do {
                opened = try await NativeSignIn(endpoint: endpoint, session: session, clock: clock).verify(code, sessionSecretHex: s.secret)
            } catch let e as SessionError {
                if e.failure.endsTheRequest { cancel() }
                throw e
            }
            s.bunkerURL = opened.bunkerURL
            s.pubkey = opened.pubkey
            keep(s)
        }
        guard let url = s.bunkerURL, let bunker = BunkerURL(url), let expected = s.pubkey else { cancel(); throw SessionError(.other) }
        let me: String
        do { me = try await connect(bunker, s.secret) } catch { throw SessionError(.connect) }
        guard me == expected else { cancel(); throw SessionError(.mismatch) }
        cancel()
        return NativeSession(config: s.config, bunkerURL: url, clientSecretHex: s.secret, pubkey: me)
    }
}
