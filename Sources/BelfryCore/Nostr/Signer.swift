import Foundation

// Who signs for the member. Real sessions use the belfry's remote signer (NIP-46, BunkerSigner);
// the demo and one-time gift-wrap keys sign locally.

public protocol Signer: AnyObject, Sendable {
    var pubkey: String { get }
    func sign(_ t: EventTemplate) async throws -> NostrEvent
    func nip44Encrypt(peer: String, plaintext: String) async throws -> String
    func nip44Decrypt(peer: String, payload: String) async throws -> String
}

public final class LocalSigner: Signer, @unchecked Sendable {
    public let secret: Data
    public let pubkey: String

    public init(secret: Data) throws {
        self.secret = secret
        self.pubkey = try Keys.publicKeyHex(secret: secret)
    }

    public convenience init(secretHex: String) throws {
        guard let d = Data(hex: secretHex) else { throw BelfryError.crypto("bad hex") }
        try self.init(secret: d)
    }

    public func sign(_ t: EventTemplate) async throws -> NostrEvent {
        try signNow(t)
    }

    public func signNow(_ t: EventTemplate) throws -> NostrEvent {
        try t.event(pubkey: pubkey).signed(with: secret)
    }

    public func nip44Encrypt(peer: String, plaintext: String) async throws -> String {
        try NIP44.encrypt(plaintext, conversationKey: NIP44.conversationKey(secretHex: secret.hex, publicKeyHex: peer))
    }

    public func nip44Decrypt(peer: String, payload: String) async throws -> String {
        try NIP44.decrypt(payload, conversationKey: NIP44.conversationKey(secretHex: secret.hex, publicKeyHex: peer))
    }
}
