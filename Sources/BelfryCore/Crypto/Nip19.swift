import Foundation

/// NIP-19 `naddr` (an addressable event's coordinate): TLV 0 = identifier (`d`, UTF-8), 1 = a relay
/// (UTF-8, any number), 2 = author (32 bytes), 3 = kind (u32 big-endian). Written in the order
/// 3, 2, 1, 0 like nostr-tools (the web chat), so every client produces the same string; read in
/// any order. Vectors: vectors/channel-refs.json.
public enum Nip19 {
    public struct Addr: Hashable, Sendable {
        public let kind: Int
        public let pubkey: String
        public let identifier: String
        public let relays: [String]
        public init(kind: Int, pubkey: String, identifier: String, relays: [String] = []) {
            self.kind = kind
            self.pubkey = pubkey
            self.identifier = identifier
            self.relays = relays
        }
    }

    public static func naddr(_ a: Addr) -> String? {
        guard let pk = Data(hex: a.pubkey), pk.count == 32 else { return nil }
        var out = [UInt8]()
        func tlv(_ type: UInt8, _ v: [UInt8]) -> Bool {
            guard v.count <= 255 else { return false }
            out.append(type)
            out.append(UInt8(v.count))
            out += v
            return true
        }
        let k = UInt32(truncatingIfNeeded: a.kind)
        guard tlv(3, [UInt8(k >> 24 & 0xff), UInt8(k >> 16 & 0xff), UInt8(k >> 8 & 0xff), UInt8(k & 0xff)]) else { return nil }
        guard tlv(2, [UInt8](pk)) else { return nil }
        for r in a.relays { guard tlv(1, [UInt8](r.utf8)) else { return nil } }
        guard tlv(0, [UInt8](a.identifier.utf8)) else { return nil }
        return Bech32.encode(hrp: "naddr", data: Data(out))
    }

    /// The coordinate an `naddr1…` holds, or nil when it is not a valid naddr.
    public static func decodeNaddr(_ text: String) -> Addr? {
        guard let (hrp, data) = Bech32.decode(text), hrp == "naddr" else { return nil }
        let b = [UInt8](data)
        var identifier: String?
        var pubkey: String?
        var kind: Int?
        var relays = [String]()
        var i = 0
        while i < b.count {
            guard i + 2 <= b.count else { return nil }
            let type = b[i]
            let len = Int(b[i + 1])
            guard i + 2 + len <= b.count else { return nil }
            let v = Array(b[(i + 2)..<(i + 2 + len)])
            switch type {
            case 0: identifier = String(decoding: v, as: UTF8.self)
            case 1: relays.append(String(decoding: v, as: UTF8.self))
            case 2:
                guard len == 32 else { return nil }
                pubkey = Data(v).hex
            case 3:
                guard len == 4 else { return nil }
                kind = Int(v[0]) << 24 | Int(v[1]) << 16 | Int(v[2]) << 8 | Int(v[3])
            default: break
            }
            i += 2 + len
        }
        guard let identifier, let pubkey, let kind else { return nil }
        return Addr(kind: kind, pubkey: pubkey, identifier: identifier, relays: relays)
    }
}
