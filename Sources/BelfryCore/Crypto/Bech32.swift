import Foundation

// NIP-19 npub / nsec (bech32, BIP-173).

public enum Bech32 {
    static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    static let generator: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

    static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 where (top >> UInt32(i)) & 1 == 1 { chk ^= generator[i] }
        }
        return chk
    }

    static func hrpExpand(_ hrp: String) -> [UInt8] {
        let b = Array(hrp.utf8)
        return b.map { $0 >> 5 } + [0] + b.map { $0 & 31 }
    }

    static func convert(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0, bits = 0
        var out = [UInt8]()
        let maxv = (1 << to) - 1
        for v in data {
            guard Int(v) >> from == 0 else { return nil }
            acc = (acc << from) | Int(v)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return out
    }

    public static func encode(hrp: String, data: Data) -> String {
        let values = convert([UInt8](data), from: 8, to: 5, pad: true)!
        let pm = polymod(hrpExpand(hrp) + values + [0, 0, 0, 0, 0, 0]) ^ 1
        let checksum = (0..<6).map { UInt8((pm >> UInt32(5 * (5 - $0))) & 31) }
        return hrp + "1" + String((values + checksum).map { charset[Int($0)] })
    }

    public static func decode(_ s: String) -> (hrp: String, data: Data)? {
        let lower = s.lowercased()
        guard lower == s || s.uppercased() == s, let sep = lower.lastIndex(of: "1") else { return nil }
        let hrp = String(lower[..<sep])
        let rest = lower[lower.index(after: sep)...]
        guard !hrp.isEmpty, rest.count >= 6 else { return nil }
        var values = [UInt8]()
        for c in rest {
            guard let i = charset.firstIndex(of: c) else { return nil }
            values.append(UInt8(i))
        }
        guard polymod(hrpExpand(hrp) + values) == 1 else { return nil }
        guard let bytes = convert(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else { return nil }
        return (hrp, Data(bytes))
    }

    public static func npub(_ hex: String) -> String? {
        guard let d = Data(hex: hex), d.count == 32 else { return nil }
        return encode(hrp: "npub", data: d)
    }

    public static func nsec(_ hex: String) -> String? {
        guard let d = Data(hex: hex), d.count == 32 else { return nil }
        return encode(hrp: "nsec", data: d)
    }

    /// The hex key of an npub, or nil.
    public static func pubkey(npub: String) -> String? {
        guard let (hrp, d) = decode(npub), hrp == "npub", d.count == 32 else { return nil }
        return d.hex
    }
}
