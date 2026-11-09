import Foundation
import P256K

// secp256k1 through swift-secp256k1 (P256K): x-only public keys, BIP-340 Schnorr signatures and
// the ECDH shared point (unhashed X, as NIP-44 wants). Kept in this one file: P256K and CryptoKit
// both define SHA256.

public enum Keys {
    /// A fresh secret key.
    public static func generateSecret() -> Data {
        while true {
            let d = Crypto.random(32)
            if (try? P256K.Schnorr.PrivateKey(dataRepresentation: d)) != nil { return d }
        }
    }

    /// The x-only public key (32 bytes) of a secret key.
    public static func publicKey(secret: Data) throws -> Data {
        guard secret.count == 32 else { throw BelfryError.crypto("secret key must be 32 bytes") }
        do {
            let key = try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
            return Data(key.xonly.bytes)
        } catch {
            throw BelfryError.crypto("invalid secret key")
        }
    }

    public static func publicKeyHex(secret: Data) throws -> String { try publicKey(secret: secret).hex }

    /// BIP-340 signature of a 32-byte message (an event id), with fresh auxiliary randomness.
    public static func sign(message: Data, secret: Data) throws -> Data {
        guard message.count == 32 else { throw BelfryError.crypto("message must be 32 bytes") }
        let key: P256K.Schnorr.PrivateKey
        do { key = try P256K.Schnorr.PrivateKey(dataRepresentation: secret) } catch { throw BelfryError.crypto("invalid secret key") }
        var msg = [UInt8](message)
        var aux = [UInt8](Crypto.random(32))
        let sig = try key.signature(message: &msg, auxiliaryRand: &aux, strict: true)
        return sig.dataRepresentation
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard signature.count == 64, message.count == 32, publicKey.count == 32 else { return false }
        guard let sig = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: signature) else { return false }
        let x = P256K.Schnorr.XonlyKey(dataRepresentation: publicKey, keyParity: 0)
        var msg = [UInt8](message)
        return x.isValid(sig, for: &msg)
    }

    /// The X coordinate of secret × peer (peer given x-only, even Y assumed as in BIP-340).
    public static func sharedX(secret: Data, publicKey: Data) throws -> Data {
        guard secret.count == 32, publicKey.count == 32 else { throw BelfryError.crypto("bad key length") }
        let priv: P256K.KeyAgreement.PrivateKey
        let pub: P256K.KeyAgreement.PublicKey
        do {
            priv = try P256K.KeyAgreement.PrivateKey(dataRepresentation: secret)
        } catch { throw BelfryError.crypto("invalid secret key") }
        do {
            pub = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data([0x02]) + publicKey, format: .compressed)
        } catch { throw BelfryError.crypto("invalid public key") }
        let shared = priv.sharedSecretFromKeyAgreement(with: pub, format: .compressed)
        let bytes = shared.withUnsafeBytes { Data($0) }
        guard bytes.count == 33 else { throw BelfryError.crypto("unexpected shared secret size") }
        return bytes.dropFirst()
    }
}
