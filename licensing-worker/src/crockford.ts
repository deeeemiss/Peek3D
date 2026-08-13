/**
 * Crockford Base32 encode/decode.
 *
 * Encoding convention (must match the Swift verifier byte-for-byte):
 *  - Alphabet: "0123456789ABCDEFGHJKMNPQRSTVWXYZ" (32 symbols, excludes I, L, O, U).
 *  - No padding character. The bit stream is packed MSB-first, 5 bits per symbol.
 *  - The number of output symbols is ceil(totalBits / 5). The final symbol's
 *    unused low bits are zero-padded.
 *  - Decoding reverses this: concatenate 5-bit groups MSB-first, then keep only
 *    floor(totalBits / 8) whole bytes and silently discard the leftover
 *    padding bits (at most 4 of them) WITHOUT validating they are zero --
 *    this matches the parallel Swift verifier's decoder exactly, which was
 *    fixed as the authoritative convention after cross-checking. Do not
 *    reintroduce a "reject non-zero padding" check here: it would make this
 *    decoder reject strings the Swift verifier accepts, and vice versa.
 *  - Output is always uppercase.
 *
 * This module has no knowledge of the "PK3D-" prefix or the 5-character
 * grouping with hyphens -- that formatting lives in license.ts, on top of
 * the raw encode/decode primitives here.
 */

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

const CHAR_TO_VALUE: Record<string, number> = (() => {
  const map: Record<string, number> = {};
  for (let i = 0; i < ALPHABET.length; i++) {
    map[ALPHABET[i]!] = i;
  }
  return map;
})();

/** Encode raw bytes into unpadded, uppercase Crockford Base32 (no hyphens, no prefix). */
export function encodeCrockford(bytes: Uint8Array): string {
  let bitBuffer = 0;
  let bitCount = 0;
  let output = "";

  for (const byte of bytes) {
    bitBuffer = (bitBuffer << 8) | byte;
    bitCount += 8;

    while (bitCount >= 5) {
      bitCount -= 5;
      const index = (bitBuffer >> bitCount) & 0x1f;
      output += ALPHABET[index];
    }
  }

  if (bitCount > 0) {
    const index = (bitBuffer << (5 - bitCount)) & 0x1f;
    output += ALPHABET[index];
  }

  return output;
}

/**
 * Decode unpadded, case-insensitive Crockford Base32 back into raw bytes.
 * Throws only if a character isn't in the alphabet. Leftover padding bits
 * (fewer than 5, from the final partial group) are discarded without
 * validation -- see the module-level note on why.
 */
export function decodeCrockford(input: string): Uint8Array {
  const normalized = input.toUpperCase();

  let bitBuffer = 0;
  let bitCount = 0;
  const bytes: number[] = [];

  for (const char of normalized) {
    const value = CHAR_TO_VALUE[char];
    if (value === undefined) {
      throw new Error(`Invalid Crockford Base32 character: ${char}`);
    }

    bitBuffer = (bitBuffer << 5) | value;
    bitCount += 5;

    if (bitCount >= 8) {
      bitCount -= 8;
      bytes.push((bitBuffer >> bitCount) & 0xff);
    }
  }

  // Whatever bits remain (< 5 of them) are padding from the final partial
  // group -- discarded, not validated. See module-level note.
  return new Uint8Array(bytes);
}
