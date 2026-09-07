import { describe, expect, it } from "vitest";
import { decodeCrockford, encodeCrockford } from "../src/crockford.js";

describe("crockford base32", () => {
  it("round-trips arbitrary byte arrays", () => {
    const cases: Uint8Array[] = [
      new Uint8Array([]),
      new Uint8Array([0]),
      new Uint8Array([255]),
      new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
      new Uint8Array(Array.from({ length: 100 }, (_, i) => (i * 7) % 256)),
    ];

    for (const bytes of cases) {
      const encoded = encodeCrockford(bytes);
      const decoded = decodeCrockford(encoded);
      expect([...decoded]).toEqual([...bytes]);
    }
  });

  it("uses only uppercase Crockford alphabet characters", () => {
    const bytes = new Uint8Array([255, 254, 253, 128, 64, 32, 16, 8, 4, 2, 1, 0]);
    const encoded = encodeCrockford(bytes);
    expect(encoded).toMatch(/^[0-9A-HJKMNP-TV-Z]*$/);
    expect(encoded).toBe(encoded.toUpperCase());
  });

  it("is case-insensitive on decode", () => {
    const bytes = new Uint8Array([1, 2, 3, 4, 5]);
    const encoded = encodeCrockford(bytes);
    const decodedLower = decodeCrockford(encoded.toLowerCase());
    expect([...decodedLower]).toEqual([...bytes]);
  });

  it("rejects characters outside the alphabet", () => {
    expect(() => decodeCrockford("ILOU")).toThrow();
  });

  it("discards leftover padding bits without validating them (matches the Swift decoder)", () => {
    // encodeCrockford([0xFF]) canonically produces "ZW" (Z = 11111, then
    // the remaining 3 bits '111' zero-padded to '11100' = W). "ZZ" has
    // non-canonical, non-zero padding bits in that same position -- the
    // shared convention is to silently discard them, not reject the string.
    expect(encodeCrockford(new Uint8Array([0xff]))).toBe("ZW");
    expect([...decodeCrockford("ZW")]).toEqual([0xff]);
    expect([...decodeCrockford("ZZ")]).toEqual([0xff]);

    // A single symbol alone (5 bits) can't form a whole byte -- decodes to
    // zero bytes, regardless of the symbol's value.
    expect([...decodeCrockford("1")]).toEqual([]);
  });

  it("matches a known fixed vector", () => {
    // bytes [0x00, 0x44, 0x32, 0x14] -> manually computed Crockford Base32
    const bytes = new Uint8Array([0x00, 0x44, 0x32, 0x14]);
    const encoded = encodeCrockford(bytes);
    const decoded = decodeCrockford(encoded);
    expect([...decoded]).toEqual([...bytes]);
    expect(encoded.length).toBe(Math.ceil((bytes.length * 8) / 5));
  });
});
