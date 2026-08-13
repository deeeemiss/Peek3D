/**
 * Polar webhook signature verification, per the Standard Webhooks spec
 * (https://github.com/standard-webhooks/standard-webhooks), which is what
 * Polar documents itself as following:
 * https://polar.sh/docs/integrate/webhooks/endpoints
 *
 * Headers:
 *   webhook-id        opaque message id
 *   webhook-timestamp integer unix seconds
 *   webhook-signature space-delimited list of "v1,<base64 sig>" entries
 *     (Standard Webhooks allows multiple signatures during secret rotation;
 *      we accept if ANY of them matches.)
 *
 * Signed content: `${webhook-id}.${webhook-timestamp}.${rawBody}`
 * MAC: HMAC-SHA256, base64-encoded.
 *
 * KEY DETAIL (documented by Polar, easy to miss): the webhook secret is
 * base64-encoded. It's usually handed to you with a "whsec_" prefix, same
 * as the Standard Webhooks convention -- strip that prefix if present, then
 * base64-decode the remainder to get the raw HMAC key bytes. Using the
 * secret's *text* as the HMAC key (instead of decoding it first) produces a
 * signature that will never match Polar's, silently.
 *
 * Replay protection: reject if the timestamp is outside a tolerance window
 * of "now" (default 300s / 5 minutes -- Standard Webhooks recommends a
 * tolerance without prescribing an exact number; 5 minutes is the common
 * default used by Svix-based implementations, which Polar's is).
 */

export interface WebhookVerificationResult {
  valid: boolean;
  reason?: string;
}

export interface WebhookHeaders {
  id: string | null;
  timestamp: string | null;
  signature: string | null;
}

export function extractWebhookHeaders(headers: Headers): WebhookHeaders {
  return {
    id: headers.get("webhook-id"),
    timestamp: headers.get("webhook-timestamp"),
    signature: headers.get("webhook-signature"),
  };
}

/** Strip an optional "whsec_" prefix and base64-decode the Polar webhook secret. */
export function decodeWebhookSecret(secret: string): Uint8Array {
  const withoutPrefix = secret.startsWith("whsec_") ? secret.slice("whsec_".length) : secret;
  return base64ToBytes(withoutPrefix);
}

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return diff === 0;
}

async function hmacSha256(key: Uint8Array, message: string): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(message));
  return new Uint8Array(signature);
}

export interface VerifyWebhookOptions {
  rawBody: string;
  headers: WebhookHeaders;
  /** Raw secret as configured (may or may not have the "whsec_" prefix). */
  secret: string;
  /** Unix seconds "now"; injectable for tests. Defaults to Date.now(). */
  nowSeconds?: number;
  toleranceSeconds?: number;
}

export async function verifyPolarWebhook(options: VerifyWebhookOptions): Promise<WebhookVerificationResult> {
  const { rawBody, headers, secret } = options;
  const nowSeconds = options.nowSeconds ?? Math.floor(Date.now() / 1000);
  const toleranceSeconds = options.toleranceSeconds ?? 300;

  if (!headers.id || !headers.timestamp || !headers.signature) {
    return { valid: false, reason: "missing_headers" };
  }

  const timestamp = Number.parseInt(headers.timestamp, 10);
  if (!Number.isFinite(timestamp)) {
    return { valid: false, reason: "invalid_timestamp" };
  }

  if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) {
    return { valid: false, reason: "timestamp_out_of_tolerance" };
  }

  let keyBytes: Uint8Array;
  try {
    keyBytes = decodeWebhookSecret(secret);
  } catch {
    return { valid: false, reason: "invalid_secret_encoding" };
  }

  const signedContent = `${headers.id}.${headers.timestamp}.${rawBody}`;
  const expectedMac = await hmacSha256(keyBytes, signedContent);
  const expectedB64 = bytesToBase64(expectedMac);

  const candidates = headers.signature.split(" ").filter(Boolean);
  for (const candidate of candidates) {
    const commaIndex = candidate.indexOf(",");
    if (commaIndex === -1) continue;
    const version = candidate.slice(0, commaIndex);
    const sigB64 = candidate.slice(commaIndex + 1);
    if (version !== "v1") continue;

    try {
      const provided = base64ToBytes(sigB64);
      const expected = base64ToBytes(expectedB64);
      if (timingSafeEqual(provided, expected)) {
        return { valid: true };
      }
    } catch {
      // malformed candidate signature, try the next one
    }
  }

  return { valid: false, reason: "signature_mismatch" };
}
