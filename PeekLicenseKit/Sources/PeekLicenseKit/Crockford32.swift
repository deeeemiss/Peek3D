import Foundation

/// Crockford Base32 codec — the human-friendly Base32 variant that excludes
/// the visually ambiguous letters I, L, O, U from its alphabet and maps
/// common OCR/typo confusions (O -> 0, I and L -> 1) when decoding.
///
/// Reference: https://www.crockford.com/base32.html
///
/// Encoding treats the input as one continuous MSB-first bit stream, sliced
/// into 5-bit groups. The final group is right-padded with zero bits if the
/// input isn't a multiple of 5 bits — there is no '=' padding character.
/// Decoding reverses this: 5-bit groups are packed back into a bit stream,
/// and any trailing bits that don't complete a full byte are discarded (they
/// are the zero padding introduced by encode(_:), never real payload data).
///
/// This bit-packing convention (not a per-character lookup table glued onto
/// RFC 4648 groups-of-8) is an interpretation of the Crockford spec, which
/// only defines the alphabet and the ambiguous-character mapping, not an
/// exact bit-grouping algorithm for arbitrary byte arrays. Any other
/// implementation producing PK3D- license strings MUST use this same
/// MSB-first, zero-pad-on-encode, discard-on-decode convention, or the two
/// sides will disagree on well-formed input.
enum Crockford32 {
    /// The 32 symbols, in value order 0...31. Excludes I, L, O, U.
    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Reverse lookup, including Crockford's documented ambiguous-character
    /// aliases: O decodes as 0, I and L both decode as 1. Lookup is
    /// case-sensitive here by design — callers are expected to uppercase
    /// input before calling decode(_:), matching the sanitization order
    /// specified for license strings (trim -> strip prefix -> strip
    /// separators -> uppercase -> decode).
    private static let charToValue: [Character: UInt8] = {
        var map = [Character: UInt8](minimumCapacity: 40)
        for (index, character) in alphabet.enumerated() {
            map[character] = UInt8(index)
        }
        map["O"] = 0
        map["I"] = 1
        map["L"] = 1
        return map
    }()

    /// Encodes arbitrary bytes into a Crockford Base32 string (no grouping,
    /// no prefix — callers add those separately for display purposes).
    static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        var result = ""
        result.reserveCapacity((data.count * 8 + 4) / 5)

        var buffer: UInt32 = 0
        var bitCount = 0

        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((buffer >> bitCount) & 0x1F)
                result.append(alphabet[index])
            }
        }
        if bitCount > 0 {
            let index = Int((buffer << (5 - bitCount)) & 0x1F)
            result.append(alphabet[index])
        }
        return result
    }

    /// Decodes a Crockford Base32 string back into bytes. The caller is
    /// responsible for prior sanitization (trimming, prefix removal,
    /// separator removal, uppercasing) — this function only maps characters
    /// through the alphabet (with ambiguous-character aliasing) and packs
    /// bits back into bytes. Returns nil if any character isn't a valid
    /// Crockford symbol (including its aliases).
    static func decode(_ string: String) -> Data? {
        guard !string.isEmpty else { return Data() }

        var buffer: UInt32 = 0
        var bitCount = 0
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count * 5 / 8)

        for character in string {
            guard let value = charToValue[character] else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                let byte = UInt8((buffer >> bitCount) & 0xFF)
                bytes.append(byte)
            }
        }
        return Data(bytes)
    }
}
