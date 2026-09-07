/**
 * License string format -- AUTHORITATIVE, shared byte-for-byte with the Swift
 * verifier implemented in parallel. Do not change this without updating both
 * sides and re-checking the test vectors in TEST_VECTORS.md.
 *
 * Binary payload (everything before the signature is what gets signed):
 *
 *   offset  size  field
 *   0       1     schema_version   u8, currently 1
 *   1       1     product_id       u8, 1 for Peek3D
 *   2       4     issued_at        u32 big-endian, unix seconds
 *   6       1     polar_key_len    u8
 *   7       n     polar_key        UTF-8
 *   7+n     1     email_len        u8
 *   8+n     m     email            UTF-8
 *   8+n+m   64    signature        Ed25519 over bytes [0, 8+n+m)
 *
 * Text encoding: Crockford Base32 (see crockford.ts) over the full byte
 * array INCLUDING the signature, uppercase, grouped in blocks of 5 characters
 * separated by "-", with a "PK3D-" prefix that is NOT part of the signed
 * payload and NOT part of the base32 alphabet stream -- it's glued on after
 * encoding purely for human/branding purposes.
 */

import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha512";
import { decodeCrockford, encodeCrockford } from "./crockford.js";

// @noble/ed25519 v2 ships hash-agnostic to stay zero-dependency. We wire in
// a pure-JS SHA-512 and then deliberately use the SYNC sign/getPublicKey/
// verify functions below (not signAsync/getPublicKeyAsync/verifyAsync).
//
// This matters: the async variants default `etc.sha512Async` to
// `crypto.subtle.digest('SHA-512', ...)` when it isn't explicitly
// overridden -- so calling them would silently reintroduce a WebCrypto
// dependency into the Ed25519 chain, exactly what we were told to avoid
// ("non usare crypto.subtle per Ed25519: il supporto nei runtime Workers
// non è garantito uniforme"). Using the sync functions with sha512Sync set
// keeps the whole stack pure-JS with zero platform crypto involved.
ed.etc.sha512Sync = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

export const SCHEMA_VERSION = 1;
export const PRODUCT_ID_PEEK3D = 1;
const SIGNATURE_LENGTH = 64;
const PREFIX = "PK3D-";
const GROUP_SIZE = 5;

export interface LicenseFields {
  schemaVersion: number;
  productId: number;
  /** Unix seconds. Must come from Polar's order data, never from the clock at request time. */
  issuedAt: number;
  polarKey: string;
  email: string;
}

function assertByteLength(fieldName: string, value: string, maxBytes: number): Uint8Array {
  const bytes = new TextEncoder().encode(value);
  if (bytes.length > maxBytes) {
    throw new Error(
      `${fieldName} is ${bytes.length} UTF-8 bytes, exceeds the ${maxBytes}-byte (u8 length prefix) limit`,
    );
  }
  return bytes;
}

/** Build the unsigned payload bytes (everything the signature covers). */
export function encodePayload(fields: LicenseFields): Uint8Array {
  if (fields.schemaVersion < 0 || fields.schemaVersion > 255) {
    throw new Error("schemaVersion must fit in a u8");
  }
  if (fields.productId < 0 || fields.productId > 255) {
    throw new Error("productId must fit in a u8");
  }
  if (fields.issuedAt < 0 || fields.issuedAt > 0xffffffff) {
    throw new Error("issuedAt must fit in a u32");
  }

  const polarKeyBytes = assertByteLength("polarKey", fields.polarKey, 255);
  const emailBytes = assertByteLength("email", fields.email, 255);

  const total = 1 + 1 + 4 + 1 + polarKeyBytes.length + 1 + emailBytes.length;
  const out = new Uint8Array(total);
  const view = new DataView(out.buffer);

  let offset = 0;
  view.setUint8(offset, fields.schemaVersion);
  offset += 1;
  view.setUint8(offset, fields.productId);
  offset += 1;
  view.setUint32(offset, fields.issuedAt, false /* big-endian */);
  offset += 4;
  view.setUint8(offset, polarKeyBytes.length);
  offset += 1;
  out.set(polarKeyBytes, offset);
  offset += polarKeyBytes.length;
  view.setUint8(offset, emailBytes.length);
  offset += 1;
  out.set(emailBytes, offset);
  offset += emailBytes.length;

  return out;
}

export interface DecodedPayload extends LicenseFields {
  /** The exact bytes that were/should be signed (payload without signature). */
  signedBytes: Uint8Array;
}

/** Parse the unsigned payload bytes back into fields. Does not touch the signature. */
export function decodePayload(bytes: Uint8Array): DecodedPayload {
  if (bytes.length < 7) {
    throw new Error("Payload too short to contain a fixed header");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

  let offset = 0;
  const schemaVersion = view.getUint8(offset);
  offset += 1;
  const productId = view.getUint8(offset);
  offset += 1;
  const issuedAt = view.getUint32(offset, false);
  offset += 4;
  const polarKeyLen = view.getUint8(offset);
  offset += 1;

  if (offset + polarKeyLen + 1 > bytes.length) {
    throw new Error("Payload truncated before polar_key/email_len");
  }
  const polarKey = new TextDecoder().decode(bytes.subarray(offset, offset + polarKeyLen));
  offset += polarKeyLen;

  const emailLen = view.getUint8(offset);
  offset += 1;

  if (offset + emailLen > bytes.length) {
    throw new Error("Payload truncated before email");
  }
  const email = new TextDecoder().decode(bytes.subarray(offset, offset + emailLen));
  offset += emailLen;

  return {
    schemaVersion,
    productId,
    issuedAt,
    polarKey,
    email,
    signedBytes: bytes.subarray(0, offset),
  };
}

/** privateKey: 32-byte Ed25519 seed. Returns the "PK3D-XXXXX-XXXXX-..." string. */
export async function signLicense(fields: LicenseFields, privateKey: Uint8Array): Promise<string> {
  const payload = encodePayload(fields);
  const signature = ed.sign(payload, privateKey); // sync: uses etc.sha512Sync, no crypto.subtle

  const full = new Uint8Array(payload.length + SIGNATURE_LENGTH);
  full.set(payload, 0);
  full.set(signature, payload.length);

  return formatLicenseString(full);
}

function formatLicenseString(fullBytes: Uint8Array): string {
  const encoded = encodeCrockford(fullBytes);
  const groups: string[] = [];
  for (let i = 0; i < encoded.length; i += GROUP_SIZE) {
    groups.push(encoded.slice(i, i + GROUP_SIZE));
  }
  return PREFIX + groups.join("-");
}

export interface VerifiedLicense extends LicenseFields {
  valid: boolean;
}

/** Parse a "PK3D-..." string and verify its Ed25519 signature against publicKey (32 bytes). */
export async function verifyLicenseString(
  licenseString: string,
  publicKey: Uint8Array,
): Promise<VerifiedLicense> {
  const trimmed = licenseString.trim();
  if (!trimmed.toUpperCase().startsWith(PREFIX)) {
    throw new Error(`License string must start with "${PREFIX}"`);
  }
  const body = trimmed.slice(PREFIX.length).replace(/-/g, "");
  const fullBytes = decodeCrockford(body);

  if (fullBytes.length < SIGNATURE_LENGTH + 7) {
    throw new Error("License string too short to contain a valid payload + signature");
  }

  const payload = fullBytes.subarray(0, fullBytes.length - SIGNATURE_LENGTH);
  const signature = fullBytes.subarray(fullBytes.length - SIGNATURE_LENGTH);

  const decoded = decodePayload(payload);
  const valid = ed.verify(signature, decoded.signedBytes, publicKey); // sync, no crypto.subtle

  return { ...decoded, valid };
}
