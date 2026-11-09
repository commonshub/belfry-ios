import Foundation

// NIP-44 v2: secp256k1 ECDH, HKDF-SHA256, ChaCha20, HMAC-SHA256, padding. Checked against the
// official vectors (vectors/nip44.json).

public enum NIP44 {
    public static let minPlaintext = 1
    public static let maxPlaintext = 65535

    public static func conversationKey(secret: Data, publicKey: Data) throws -> Data {
        let x = try Keys.sharedX(secret: secret, publicKey: publicKey)
        return Crypto.hkdfExtract(salt: Data("nip44-v2".utf8), ikm: x)
    }

    public static func conversationKey(secretHex: String, publicKeyHex: String) throws -> Data {
        guard let s = Data(hex: secretHex), let p = Data(hex: publicKeyHex) else { throw BelfryError.crypto("bad hex") }
        return try conversationKey(secret: s, publicKey: p)
    }

    public struct MessageKeys { public let chachaKey: Data; public let chachaNonce: Data; public let hmacKey: Data }

    public static func messageKeys(conversationKey: Data, nonce: Data) throws -> MessageKeys {
        guard conversationKey.count == 32 else { throw BelfryError.crypto("invalid conversation key length") }
        guard nonce.count == 32 else { throw BelfryError.crypto("invalid nonce length") }
        let k = Crypto.hkdfExpand(prk: conversationKey, info: nonce, length: 76)
        return MessageKeys(chachaKey: k.subdata(in: k.startIndex..<k.startIndex + 32),
                           chachaNonce: k.subdata(in: k.startIndex + 32..<k.startIndex + 44),
                           hmacKey: k.subdata(in: k.startIndex + 44..<k.startIndex + 76))
    }

    public static func calcPaddedLen(_ len: Int) -> Int {
        if len <= 32 { return 32 }
        var nextPower = 1
        while nextPower < len { nextPower <<= 1 } // 1 << (floor(log2(len - 1)) + 1)
        let chunk = nextPower <= 256 ? 32 : nextPower / 8
        return chunk * ((len - 1) / chunk + 1)
    }

    static func pad(_ plaintext: String) throws -> Data {
        let bytes = Data(plaintext.utf8)
        guard bytes.count >= minPlaintext, bytes.count <= maxPlaintext else { throw BelfryError.crypto("invalid plaintext length") }
        var out = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)])
        out += bytes
        out += Data(count: calcPaddedLen(bytes.count) - bytes.count)
        return out
    }

    static func unpad(_ padded: Data) throws -> String {
        let p = [UInt8](padded)
        guard p.count >= 2 else { throw BelfryError.crypto("invalid padding") }
        let len = Int(p[0]) << 8 | Int(p[1])
        guard len >= minPlaintext, len <= maxPlaintext, p.count == 2 + calcPaddedLen(len), len + 2 <= p.count else {
            throw BelfryError.crypto("invalid padding")
        }
        guard let s = String(bytes: p[2..<(2 + len)], encoding: .utf8) else { throw BelfryError.crypto("invalid utf-8") }
        return s
    }

    public static func encrypt(_ plaintext: String, conversationKey: Data, nonce: Data = Crypto.random(32)) throws -> String {
        let keys = try messageKeys(conversationKey: conversationKey, nonce: nonce)
        let padded = try pad(plaintext)
        let ciphertext = ChaCha20.xor(key: keys.chachaKey, nonce: keys.chachaNonce, data: padded)
        let mac = Crypto.hmacSHA256(key: keys.hmacKey, nonce + ciphertext)
        return (Data([2]) + nonce + ciphertext + mac).base64EncodedString()
    }

    public static func decrypt(_ payload: String, conversationKey: Data) throws -> String {
        guard !payload.isEmpty, !payload.hasPrefix("#") else { throw BelfryError.crypto("unknown version") }
        let plen = payload.utf8.count
        guard plen >= 132, plen <= 87472 else { throw BelfryError.crypto("invalid payload size") }
        guard let data = Data(base64Encoded: payload) else { throw BelfryError.crypto("invalid base64") }
        let d = [UInt8](data)
        guard d.count >= 99, d.count <= 65603 else { throw BelfryError.crypto("invalid data size") }
        guard d[0] == 2 else { throw BelfryError.crypto("unknown version \(d[0])") }
        let nonce = Data(d[1..<33])
        let ciphertext = Data(d[33..<(d.count - 32)])
        let mac = Data(d[(d.count - 32)...])
        let keys = try messageKeys(conversationKey: conversationKey, nonce: nonce)
        let expected = Crypto.hmacSHA256(key: keys.hmacKey, nonce + ciphertext)
        guard Crypto.equal(expected, mac) else { throw BelfryError.crypto("invalid MAC") }
        return try unpad(ChaCha20.xor(key: keys.chachaKey, nonce: keys.chachaNonce, data: ciphertext))
    }
}

/// ChaCha20 (RFC 8439), counter starting at 0, as NIP-44 uses it. CryptoKit only has the AEAD.
public enum ChaCha20 {
    @inline(__always) static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }

    static func quarter(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    static func words(_ d: Data) -> [UInt32] {
        let b = [UInt8](d)
        return stride(from: 0, to: b.count, by: 4).map {
            UInt32(b[$0]) | UInt32(b[$0 + 1]) << 8 | UInt32(b[$0 + 2]) << 16 | UInt32(b[$0 + 3]) << 24
        }
    }

    public static func xor(key: Data, nonce: Data, data: Data, counter: UInt32 = 0) -> Data {
        precondition(key.count == 32 && nonce.count == 12)
        let k = words(key), n = words(nonce)
        var state: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574] + k + [counter] + n
        var out = [UInt8](data)
        var offset = 0
        var block = [UInt8](repeating: 0, count: 64)
        while offset < out.count {
            var x = state
            for _ in 0..<10 {
                quarter(&x, 0, 4, 8, 12); quarter(&x, 1, 5, 9, 13); quarter(&x, 2, 6, 10, 14); quarter(&x, 3, 7, 11, 15)
                quarter(&x, 0, 5, 10, 15); quarter(&x, 1, 6, 11, 12); quarter(&x, 2, 7, 8, 13); quarter(&x, 3, 4, 9, 14)
            }
            for i in 0..<16 {
                let v = x[i] &+ state[i]
                block[i * 4] = UInt8(v & 0xff)
                block[i * 4 + 1] = UInt8((v >> 8) & 0xff)
                block[i * 4 + 2] = UInt8((v >> 16) & 0xff)
                block[i * 4 + 3] = UInt8((v >> 24) & 0xff)
            }
            let n = min(64, out.count - offset)
            for i in 0..<n { out[offset + i] ^= block[i] }
            offset += 64
            state[12] = state[12] &+ 1
        }
        return Data(out)
    }
}
