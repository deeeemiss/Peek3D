import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { extractWebhookHeaders, verifyPolarWebhook } from "../src/webhook-verify.js";

// Independent (not shared with src/webhook-verify.ts) computation of what a
// valid Polar signature would look like, so the test isn't just checking
// the implementation against itself.
function computeValidSignatureHeader(
  secretBase64NoPrefix: string,
  id: string,
  timestamp: string,
  rawBody: string,
): string {
  const key = Buffer.from(secretBase64NoPrefix, "base64");
  const signedContent = `${id}.${timestamp}.${rawBody}`;
  const mac = createHmac("sha256", key).update(signedContent).digest("base64");
  return `v1,${mac}`;
}

// 32 raw bytes, base64-encoded -- a plausible Polar webhook secret.
const SECRET_RAW_BASE64 = Buffer.from("this-is-a-32-byte-test-secret!!").toString("base64");
const SECRET_WITH_PREFIX = `whsec_${SECRET_RAW_BASE64}`;

describe("verifyPolarWebhook", () => {
  const rawBody = JSON.stringify({ type: "order.paid", data: { id: "order_123" } });
  const id = "msg_abc123";
  const nowSeconds = 1_700_000_000;
  const timestamp = String(nowSeconds);

  it("accepts a validly signed request (secret with whsec_ prefix)", async () => {
    const signature = computeValidSignatureHeader(SECRET_RAW_BASE64, id, timestamp, rawBody);

    const result = await verifyPolarWebhook({
      rawBody,
      headers: { id, timestamp, signature },
      secret: SECRET_WITH_PREFIX,
      nowSeconds,
    });

    expect(result.valid).toBe(true);
  });

  it("accepts a validly signed request (secret without whsec_ prefix)", async () => {
    const signature = computeValidSignatureHeader(SECRET_RAW_BASE64, id, timestamp, rawBody);

    const result = await verifyPolarWebhook({
      rawBody,
      headers: { id, timestamp, signature },
      secret: SECRET_RAW_BASE64,
      nowSeconds,
    });

    expect(result.valid).toBe(true);
  });

  it("rejects a request with a wrong signature", async () => {
    const result = await verifyPolarWebhook({
      rawBody,
      headers: { id, timestamp, signature: "v1,not-the-right-signature-at-all" },
      secret: SECRET_WITH_PREFIX,
      nowSeconds,
    });

    expect(result.valid).toBe(false);
    expect(result.reason).toBe("signature_mismatch");
  });

  it("rejects a request signed with a different secret", async () => {
    const wrongSecret = Buffer.from("a-completely-different-secret!!").toString("base64");
    const signature = computeValidSignatureHeader(wrongSecret, id, timestamp, rawBody);

    const result = await verifyPolarWebhook({
      rawBody,
      headers: { id, timestamp, signature },
      secret: SECRET_WITH_PREFIX,
      nowSeconds,
    });

    expect(result.valid).toBe(false);
  });

  it("rejects a request whose body was tampered with after signing", async () => {
    const signature = computeValidSignatureHeader(SECRET_RAW_BASE64, id, timestamp, rawBody);
    const tamperedBody = JSON.stringify({ type: "order.paid", data: { id: "order_999" } });

    const result = await verifyPolarWebhook({
      rawBody: tamperedBody,
      headers: { id, timestamp, signature },
      secret: SECRET_WITH_PREFIX,
      nowSeconds,
    });

    expect(result.valid).toBe(false);
  });

  it("rejects a timestamp outside the tolerance window (replay protection)", async () => {
    const oldTimestamp = String(nowSeconds - 600); // 10 minutes old, default tolerance is 300s
    const signature = computeValidSignatureHeader(SECRET_RAW_BASE64, id, oldTimestamp, rawBody);

    const result = await verifyPolarWebhook({
      rawBody,
      headers: { id, timestamp: oldTimestamp, signature },
      secret: SECRET_WITH_PREFIX,
      nowSeconds,
    });

    expect(result.valid).toBe(false);
    expect(result.reason).toBe("timestamp_out_of_tolerance");
  });

  it("accepts a timestamp within a custom tolerance window", async () => {
    const slightlyOldTimestamp = String(nowSeconds - 100);
    const signature = computeValidSignatureHeader(SECRET_RAW_BASE64, id, slightlyOldTimestamp, rawBody);

    const result = await verifyPolarWebhook({
      rawBody,
      headers: { id, timestamp: slightlyOldTimestamp, signature },
      secret: SECRET_WITH_PREFIX,
      nowSeconds,
      toleranceSeconds: 120,
    });

    expect(result.valid).toBe(true);
  });

  it.each(["webhook-id", "webhook-timestamp", "webhook-signature"])(
    "rejects a request missing the %s header",
    async (missingHeader) => {
      const signature = computeValidSignatureHeader(SECRET_RAW_BASE64, id, timestamp, rawBody);
      const headers = extractWebhookHeaders(
        new Headers({
          "webhook-id": id,
          "webhook-timestamp": timestamp,
          "webhook-signature": signature,
        }),
      );

      const patched = { ...headers, [headerKey(missingHeader)]: null };

      const result = await verifyPolarWebhook({
        rawBody,
        headers: patched,
        secret: SECRET_WITH_PREFIX,
        nowSeconds,
      });

      expect(result.valid).toBe(false);
      expect(result.reason).toBe("missing_headers");
    },
  );

  // These three guard `timingSafeEqual`'s length check specifically. Without
  // `if (a.length !== b.length) return false;`, the comparison loop only
  // ever runs for `provided.length` iterations (`provided` is `a`), so any
  // byte of `expected` beyond that point is never looked at, and any byte of
  // `provided` beyond `expected`'s length is compared against `?? 0`. Three
  // distinct exploitable shapes fall out of that:
  //   - an EMPTY provided signature: the loop runs zero times, `diff` stays
  //     0, and the comparison returns true unconditionally. This is the
  //     concrete exploit the audit demonstrated: header
  //     `signature: "v1,"` (empty base64 payload after the comma) against
  //     ANY body/secret/timestamp produces `{ valid: true }`.
  //   - a signature that's a genuine byte-for-byte PREFIX of the correct
  //     one, just shorter: every byte the shortened loop does check matches,
  //     so it passes despite being a different (much weaker) signature.
  //   - a signature that's the correct one with extra zero bytes appended:
  //     the loop's tail comparisons land on `expected[i] ?? 0` (0, out of
  //     bounds) against the appended zero bytes, which also match.
  it("rejects an empty signature instead of vacuously matching", async () => {
    const result = await verifyPolarWebhook({
      rawBody,
      headers: { id, timestamp, signature: "v1," },
      secret: SECRET_WITH_PREFIX,
      nowSeconds,
    });

    expect(result.valid).toBe(false);
    expect(result.reason).toBe("signature_mismatch");
  });

  it("rejects a signature that is a truncated (shorter) prefix of the correct one", async () => {
    const validSignature = computeValidSignatureHeader(SECRET_RAW_BASE64, id, timestamp, rawBody);
    const validBytes = Buffer.from(validSignature.slice("v1,".length), "base64");
    const truncatedB64 = validBytes.subarray(0, validBytes.length - 1).toString("base64");

    const result = await verifyPolarWebhook({
      rawBody,
      headers: { id, timestamp, signature: `v1,${truncatedB64}` },
      secret: SECRET_WITH_PREFIX,
      nowSeconds,
    });

    expect(result.valid).toBe(false);
    expect(result.reason).toBe("signature_mismatch");
  });

  it("rejects a signature that is the correct one with extra zero bytes appended", async () => {
    const validSignature = computeValidSignatureHeader(SECRET_RAW_BASE64, id, timestamp, rawBody);
    const validBytes = Buffer.from(validSignature.slice("v1,".length), "base64");
    const extendedB64 = Buffer.concat([validBytes, Buffer.from([0, 0])]).toString("base64");

    const result = await verifyPolarWebhook({
      rawBody,
      headers: { id, timestamp, signature: `v1,${extendedB64}` },
      secret: SECRET_WITH_PREFIX,
      nowSeconds,
    });

    expect(result.valid).toBe(false);
    expect(result.reason).toBe("signature_mismatch");
  });

  it("accepts when the matching signature is one of several space-separated candidates", async () => {
    const validSignature = computeValidSignatureHeader(SECRET_RAW_BASE64, id, timestamp, rawBody);
    const combined = `v1,bogus-signature-one ${validSignature} v1,bogus-signature-two`;

    const result = await verifyPolarWebhook({
      rawBody,
      headers: { id, timestamp, signature: combined },
      secret: SECRET_WITH_PREFIX,
      nowSeconds,
    });

    expect(result.valid).toBe(true);
  });
});

function headerKey(name: string): "id" | "timestamp" | "signature" {
  if (name === "webhook-id") return "id";
  if (name === "webhook-timestamp") return "timestamp";
  return "signature";
}
