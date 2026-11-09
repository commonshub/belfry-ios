import CryptoKit
import Foundation
import Security

// Hex, hashes, HMAC/HKDF, randomness and AES-GCM: the primitives under NIP-44, NIP-59 and Blossom.

public extension Data {
    /// Lowercase or uppercase hex; nil for odd length or a non-hex character.
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nib(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nib(chars[i]), let lo = nib(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for b in self {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// A 64-char lowercase hex string (a key or an event id).
public func isHex64(_ s: String) -> Bool {
    s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

public enum Crypto {
    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    public static func sha256(_ s: String) -> Data { sha256(Data(s.utf8)) }

    public static func hmacSHA256(key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    public static func hkdfExtract(salt: Data, ikm: Data) -> Data { hmacSHA256(key: salt, ikm) }

    public static func hkdfExpand(prk: Data, info: Data, length: Int) -> Data {
        var out = Data()
        var t = Data()
        var i: UInt8 = 1
        while out.count < length {
            t = hmacSHA256(key: prk, t + info + Data([i]))
            out += t
            i &+= 1
        }
        return out.prefix(length)
    }

    public static func random(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        let ok = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        precondition(ok == errSecSuccess, "no randomness")
        return Data(bytes)
    }

    /// Constant-time comparison.
    public static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var d: UInt8 = 0
        for (x, y) in zip(a, b) { d |= x ^ y }
        return d == 0
    }

    /// AES-256-GCM as Belfry stores large e-mails on Blossom: ciphertext followed by the 16-byte tag.
    public static func aesGCMOpen(key: Data, nonce: Data, sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw BelfryError.crypto("short ciphertext") }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: sealed.prefix(sealed.count - 16),
            tag: sealed.suffix(16)
        )
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum BelfryError: Error, Equatable, LocalizedError {
    case crypto(String)
    case invalid(String)
    case network(String)
    case relay(String)
    case signer(String)
    case notSignedIn

    public var errorDescription: String? {
        switch self {
        case .crypto(let s): return "Crypto: \(s)"
        case .invalid(let s): return s
        case .network(let s): return s
        case .relay(let s): return s
        case .signer(let s): return s
        case .notSignedIn: return "Not signed in."
        }
    }

    /// The text an outbox item keeps as its reason (classified by Outbox.classify).
    public var relayMessage: String {
        switch self {
        case .relay(let s), .network(let s), .signer(let s), .invalid(let s), .crypto(let s): return s
        case .notSignedIn: return "Not signed in."
        }
    }
}
