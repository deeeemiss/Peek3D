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

/**
 * Polar signs with one of two different HMAC keys derived from the same
 * `whsec_…` secret, and which one depends on WHEN the secret was generated:
 *
 * - secrets generated before 2026-09-08T00:00Z ("Polar HMAC", what the
 *   dashboard labels *Legacy signing*) use the UTF-8 bytes of the **entire**
 *   `whsec_…` string, prefix included, as the key;
 * - secrets generated on or after that instant use Standard Webhooks: the
 *   part after `whsec_`, base64-decoded.
 *
 * The cutover is a property of the secret, not of the delivery, so an old
 * endpoint keeps using the legacy key indefinitely — it does not migrate on
 * its own. Verifying against both candidates is exactly what Polar's own
 * SDKs do, and it costs nothing in security: an attacker still has to know
 * the secret to produce either MAC.
 *
 * Found the hard way: the first real order returned 401 on every delivery
 * because only the Standard Webhooks key was tried.
 */
function webhookKeyCandidates(secret: string): Uint8Array[] {
  const keys: Uint8Array[] = [];
  try {
    keys.push(decodeWebhookSecret(secret));
  } catch {
    // Not valid base64 — only the legacy interpretation is possible.
  }
  keys.push(new TextEncoder().encode(secret));
  return keys;
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

  // Number.parseInt("1700000000xyz", 10) === 1700000000 -- it happily
  // parses a leading run of digits and silently ignores any trailing
  // garbage, so it alone can't tell a well-formed timestamp header from a
  // malformed one. Require the header to be nothing but digits first.
  if (!/^\d+$/.test(headers.timestamp)) {
    return { valid: false, reason: "invalid_timestamp" };
  }
  const timestamp = Number.parseInt(headers.timestamp, 10);
  if (!Number.isFinite(timestamp)) {
    return { valid: false, reason: "invalid_timestamp" };
  }

  if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) {
    return { valid: false, reason: "timestamp_out_of_tolerance" };
  }

  const keyCandidates = webhookKeyCandidates(secret);
  if (keyCandidates.length === 0) {
    return { valid: false, reason: "invalid_secret_encoding" };
  }

  const signedContent = `${headers.id}.${headers.timestamp}.${rawBody}`;
  const expectedSignatures: string[] = [];
  for (const keyBytes of keyCandidates) {
    expectedSignatures.push(bytesToBase64(await hmacSha256(keyBytes, signedContent)));
  }

  const candidates = headers.signature.split(" ").filter(Boolean);
  for (const candidate of candidates) {
    const commaIndex = candidate.indexOf(",");
    if (commaIndex === -1) continue;
    const version = candidate.slice(0, commaIndex);
    const sigB64 = candidate.slice(commaIndex + 1);
    if (version !== "v1") continue;

    try {
      const provided = base64ToBytes(sigB64);
      for (const expectedB64 of expectedSignatures) {
        if (timingSafeEqual(provided, base64ToBytes(expectedB64))) {
          return { valid: true };
        }
      }
    } catch {
      // malformed candidate signature, try the next one
    }
  }

  return { valid: false, reason: "signature_mismatch" };
}
