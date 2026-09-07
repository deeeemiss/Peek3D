import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha512";
import { beforeAll, describe, expect, it } from "vitest";
import {
  decodePayload,
  encodePayload,
  PRODUCT_ID_PEEK3D,
  SCHEMA_VERSION,
  signLicense,
  verifyLicenseString,
  type LicenseFields,
} from "../src/license.js";

beforeAll(() => {
  ed.etc.sha512Sync = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));
});

// Fixed test keypair -- NEVER use in production. Also written out by
// `npm run vectors` into TEST_VECTORS.md for cross-checking against the
// Swift verifier.
const TEST_PRIVATE_KEY = hexToBytes(
  "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1eaa", // 32 bytes
);

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = Number.parseInt(hex.substr(i * 2, 2), 16);
  return out;
}

const SAMPLE_FIELDS: LicenseFields = {
  schemaVersion: SCHEMA_VERSION,
  productId: PRODUCT_ID_PEEK3D,
  issuedAt: 1_762_000_000,
  polarKey: "POLAR-TEST-KEY-0001",
  email: "buyer@example.com",
};

describe("payload encode/decode", () => {
  it("round-trips all fields", () => {
    const payload = encodePayload(SAMPLE_FIELDS);
    const decoded = decodePayload(payload);
    expect(decoded.schemaVersion).toBe(SAMPLE_FIELDS.schemaVersion);
    expect(decoded.productId).toBe(SAMPLE_FIELDS.productId);
    expect(decoded.issuedAt).toBe(SAMPLE_FIELDS.issuedAt);
    expect(decoded.polarKey).toBe(SAMPLE_FIELDS.polarKey);
    expect(decoded.email).toBe(SAMPLE_FIELDS.email);
    expect(decoded.signedBytes.length).toBe(payload.length);
  });

  it("lays out bytes exactly per the authoritative offset table", () => {
    const fields: LicenseFields = {
      schemaVersion: 1,
      productId: 1,
      issuedAt: 0x01020304,
      polarKey: "AB", // 2 bytes
      email: "x@y.z", // 5 bytes
    };
    const payload = encodePayload(fields);
    // offset 0: schema_version
    expect(payload[0]).toBe(1);
    // offset 1: product_id
    expect(payload[1]).toBe(1);
    // offset 2..5: issued_at big-endian
    expect([...payload.slice(2, 6)]).toEqual([0x01, 0x02, 0x03, 0x04]);
    // offset 6: polar_key_len
    expect(payload[6]).toBe(2);
    // offset 7..8: polar_key
    expect(new TextDecoder().decode(payload.slice(7, 9))).toBe("AB");
    // offset 9: email_len
    expect(payload[9]).toBe(5);
    // offset 10..14: email
    expect(new TextDecoder().decode(payload.slice(10, 15))).toBe("x@y.z");
    // total length = 8 + n + m = 8 + 2 + 5 = 15
    expect(payload.length).toBe(15);
  });

  it("rejects fields whose UTF-8 length exceeds 255 bytes", () => {
    const tooLong = "x".repeat(256);
    expect(() => encodePayload({ ...SAMPLE_FIELDS, polarKey: tooLong })).toThrow();
    expect(() => encodePayload({ ...SAMPLE_FIELDS, email: tooLong })).toThrow();
  });
});

describe("signLicense / verifyLicenseString", () => {
  it("produces a string with the PK3D- prefix and 5-char hyphenated groups", async () => {
    const licenseString = await signLicense(SAMPLE_FIELDS, TEST_PRIVATE_KEY);
    expect(licenseString.startsWith("PK3D-")).toBe(true);
    const groups = licenseString.slice("PK3D-".length).split("-");
    for (const group of groups.slice(0, -1)) {
      expect(group.length).toBe(5);
    }
    expect(groups[groups.length - 1]!.length).toBeLessThanOrEqual(5);
  });

  it("round-trips through verify with the matching public key", async () => {
    const publicKey = ed.getPublicKey(TEST_PRIVATE_KEY);
    const licenseString = await signLicense(SAMPLE_FIELDS, TEST_PRIVATE_KEY);
    const result = await verifyLicenseString(licenseString, publicKey);

    expect(result.valid).toBe(true);
    expect(result.schemaVersion).toBe(SAMPLE_FIELDS.schemaVersion);
    expect(result.productId).toBe(SAMPLE_FIELDS.productId);
    expect(result.issuedAt).toBe(SAMPLE_FIELDS.issuedAt);
    expect(result.polarKey).toBe(SAMPLE_FIELDS.polarKey);
    expect(result.email).toBe(SAMPLE_FIELDS.email);
  });

  it("fails verification against the wrong public key", async () => {
    const otherPrivateKey = hexToBytes(
      "11111111111111111111111111111111111111111111111111111111111111bb", // 32 bytes
    );
    const wrongPublicKey = ed.getPublicKey(otherPrivateKey);
    const licenseString = await signLicense(SAMPLE_FIELDS, TEST_PRIVATE_KEY);
    const result = await verifyLicenseString(licenseString, wrongPublicKey);
    expect(result.valid).toBe(false);
  });

  it("fails verification when a single character is tampered with", async () => {
    const publicKey = ed.getPublicKey(TEST_PRIVATE_KEY);
    const licenseString = await signLicense(SAMPLE_FIELDS, TEST_PRIVATE_KEY);

    // Flip one character deep in the encoded body (not the prefix) to a
    // different valid Crockford symbol.
    const tamperIndex = licenseString.length - 3;
    const original = licenseString[tamperIndex];
    const replacement = original === "0" ? "1" : "0";
    const tampered =
      licenseString.slice(0, tamperIndex) + replacement + licenseString.slice(tamperIndex + 1);

    const result = await verifyLicenseString(tampered, publicKey);
    expect(result.valid).toBe(false);
  });

  it("rejects strings without the PK3D- prefix", async () => {
    await expect(verifyLicenseString("NOPE-AAAAA", new Uint8Array(32))).rejects.toThrow();
  });

  it("deterministic golden vector for cross-checking with the Swift verifier", async () => {
    const fields: LicenseFields = {
      schemaVersion: 1,
      productId: 1,
      issuedAt: 1_700_000_000,
      polarKey: "POLAR-ABCD-1234",
      email: "vector@example.com",
    };
    const licenseString = await signLicense(fields, TEST_PRIVATE_KEY);
    // Deterministic: same inputs + same key must always produce the same
    // string (this is exactly what the /recover endpoint relies on).
    const licenseStringAgain = await signLicense(fields, TEST_PRIVATE_KEY);
    expect(licenseString).toBe(licenseStringAgain);
  });
});

describe("cross-check against TEST_VECTORS.md (shared with the Swift verifier)", () => {
  // Deterministic, NOT secret: SHA-256("PeekLicenseKit-TEST-KEY-DO-NOT-USE-IN-PRODUCTION").
  // See scripts/gen-test-vectors.ts. These three cases were independently
  // verified against Python's `cryptography` (OpenSSL-backed) Ed25519
  // implementation before being locked in here -- if this test ever fails,
  // do NOT "fix" it by pasting in a new expected string; it means either
  // this worker's signing or the Swift verifier's signing/encoding has
  // regressed, and that divergence is the bug to chase.
  const VECTOR_PRIVATE_KEY = hexToBytes(
    "63f2716f729f77386f71aa3388ae4a2784badf3a65f4088189fddb5b9f894acf",
  );
  const VECTOR_PUBLIC_KEY = hexToBytes(
    "e60868d30765ae875f1fa9317197f3328cff10935386011dfb42470d05a6e741",
  );

  it("vector 1 -- ASCII email", async () => {
    const fields: LicenseFields = {
      schemaVersion: 1,
      productId: 1,
      issuedAt: 1_732_000_000,
      polarKey: "POLAR-AB12-CD34-EF56-7890",
      email: "mario.rossi@example.com",
    };
    const licenseString = await signLicense(fields, VECTOR_PRIVATE_KEY);
    expect(licenseString).toBe(
      "PK3D-040PE-F1S00-CN0KT-C8592-TGA26-4S2TG-T46CT-2THA6-6MV2T-DSR74-R1EVB-1E9MP-YBKJD-XSQ6T-A0CNW-62VBG-DHJJW-RVFDM-YM364-33MH9-0JFXZ-8X667-9FDN4-6MX64-15EH3-2HXWF-8F2CE-K15PG-1H28N-X13N1-HE97R-H344N-J9XTC-6TW5B-MEH2N-4SHZ5-0KQ0R-W3T7S-05",
    );
    const verified = await verifyLicenseString(licenseString, VECTOR_PUBLIC_KEY);
    expect(verified.valid).toBe(true);
  });

  it("vector 2 -- non-ASCII UTF-8 email", async () => {
    const fields: LicenseFields = {
      schemaVersion: 1,
      productId: 1,
      issuedAt: 1_690_000_000,
      polarKey: "POLAR-0000-1111-2222-3333",
      email: "società@ésempio.it",
    };
    const licenseString = await signLicense(fields, VECTOR_PRIVATE_KEY);
    expect(licenseString).toBe(
      "PK3D-040P9-ETTG0-CN0KT-C8592-TC1G6-0R2TC-9H64R-JTCHJ-68S2T-CSK6C-SH8WV-FCDMP-AX63M-10C7A-BKCNP-Q0TBF-5SMQ8-VN6TX-ENZQB-QZ1YZ-MS5GG-EMYNB-EZJGF-3B0ED-BBGT4-2V0P2-61DAB-ARMJ7-M72E8-BKZMT-N4AYJ-Y3KCN-CM1PS-P1SZ7-6G3S3-396BG-CA5XB-830",
    );
    const verified = await verifyLicenseString(licenseString, VECTOR_PUBLIC_KEY);
    expect(verified.valid).toBe(true);
  });

  it("vector 3 -- another ASCII case", async () => {
    const fields: LicenseFields = {
      schemaVersion: 1,
      productId: 1,
      issuedAt: 1_800_000_000,
      polarKey: "POLAR-ZZZZ-9999-AAAA-BBBB",
      email: "qa+peek3d@anthropic.test",
    };
    const licenseString = await signLicense(fields, VECTOR_PRIVATE_KEY);
    expect(licenseString).toBe(
      "PK3D-040PP-JEJ00-CN0KT-C8592-TPJTB-9D2TE-9S74W-JTGA1-850JT-GJ289-11GWB-15DR6-ASBB6-DJ40R-BEEHM-74VVG-D5HJW-X35ED-T0NSE-3BYYR-D26WN-7PWB3-2STPE-ATN2K-5PAVJ-6H24B-J2RY2-446FE-Q5Z9D-9P0G3-PRVZR-1FHM7-KCCV9-YFKWJ-JET8R-DKACH-YGGZX-DNFCP-M514",
    );
    const verified = await verifyLicenseString(licenseString, VECTOR_PUBLIC_KEY);
    expect(verified.valid).toBe(true);
  });
});
