import { createHmac } from "node:crypto";
import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha512";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { FakeEmailSender } from "../src/email.js";
import { handleRecover, handleWebhook, type HandlerDeps } from "../src/handlers.js";
import { decodePayload } from "../src/license.js";
import { decodeCrockford } from "../src/crockford.js";
import { FakePolarClient, type PolarOrder } from "../src/polar.js";
import { InMemoryRateLimiter } from "../src/rate-limit.js";

beforeAll(() => {
  ed.etc.sha512Sync = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));
});

const PRIVATE_KEY = new Uint8Array(32).fill(7);
const WEBHOOK_SECRET_RAW_BASE64 = Buffer.from("handler-test-secret-32-bytes!!!").toString("base64");
const WEBHOOK_SECRET = `whsec_${WEBHOOK_SECRET_RAW_BASE64}`;

function signWebhook(id: string, timestamp: string, rawBody: string): string {
  const key = Buffer.from(WEBHOOK_SECRET_RAW_BASE64, "base64");
  const mac = createHmac("sha256", key)
    .update(`${id}.${timestamp}.${rawBody}`)
    .digest("base64");
  return `v1,${mac}`;
}

function buildWebhookHeaders(rawBody: string, nowSeconds: number): Headers {
  const id = "msg_test";
  const timestamp = String(nowSeconds);
  const signature = signWebhook(id, timestamp, rawBody);
  return new Headers({ "webhook-id": id, "webhook-timestamp": timestamp, "webhook-signature": signature });
}

function extractLicenseString(emailText: string): string {
  const match = emailText.match(/PK3D-[0-9A-Z-]+/);
  if (!match) throw new Error("No license string found in email body");
  return match[0];
}

describe("handleWebhook", () => {
  let polar: FakePolarClient;
  let email: FakeEmailSender;
  let deps: HandlerDeps;
  // handleWebhook verifies the signature against the real wall clock
  // (verifyPolarWebhook defaults nowSeconds to Date.now()), so headers in
  // these tests must be timestamped "now", not a fixed historical epoch.
  const nowSeconds = () => Math.floor(Date.now() / 1000);

  const order: PolarOrder = {
    id: "order_1",
    customerId: "cust_1",
    customerEmail: "buyer@example.com",
    paid: true,
    createdAt: new Date(1_699_999_000 * 1000),
  };

  beforeEach(() => {
    polar = new FakePolarClient();
    email = new FakeEmailSender();
    deps = {
      polar,
      email,
      webhookSecret: WEBHOOK_SECRET,
      ed25519PrivateKey: PRIVATE_KEY,
      recoverRateLimiter: new InMemoryRateLimiter(100, 60),
    };

    polar.orders.set(order.id, order);
    polar.grantsByCustomer.set(order.customerId, [
      { id: "grant_1", customerId: order.customerId, createdAt: new Date(), isGranted: true, licenseKeyId: "lk_1" },
    ]);
    polar.licenseKeys.set("lk_1", { id: "lk_1", key: "POLAR-KEY-0001" });
  });

  it("rejects a request with an invalid signature (401, no email sent)", async () => {
    const rawBody = JSON.stringify({ type: "order.paid", data: { id: order.id } });
    const headers = new Headers({
      "webhook-id": "msg_test",
      "webhook-timestamp": String(nowSeconds()),
      "webhook-signature": "v1,wrong",
    });

    const result = await handleWebhook(deps, { rawBody, headers });

    expect(result.status).toBe(401);
    expect(email.sent).toHaveLength(0);
  });

  it("issues and emails a license for a valid order.paid webhook", async () => {
    const rawBody = JSON.stringify({ type: "order.paid", data: { id: order.id } });
    const headers = buildWebhookHeaders(rawBody, nowSeconds());

    const result = await handleWebhook(deps, { rawBody, headers });

    expect(result.status).toBe(200);
    expect(email.sent).toHaveLength(1);
    expect(email.sent[0]!.to).toBe("buyer@example.com");

    const licenseString = extractLicenseString(email.sent[0]!.text);
    const payload = decodeCrockford(licenseString.slice("PK3D-".length).replace(/-/g, ""));
    const decoded = decodePayload(payload.subarray(0, payload.length - 64));
    expect(decoded.email).toBe("buyer@example.com");
    expect(decoded.polarKey).toBe("POLAR-KEY-0001");
    // issued_at must come from the order's createdAt, never from "now".
    expect(decoded.issuedAt).toBe(Math.floor(order.createdAt.getTime() / 1000));
  });

  it("does not process a delivery whose signature is invalid, even with a correct body", async () => {
    const rawBody = JSON.stringify({ type: "order.paid", data: { id: order.id } });
    const badHeaders = buildWebhookHeaders(rawBody, nowSeconds());
    badHeaders.set("webhook-signature", "v1,AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");

    const result = await handleWebhook(deps, { rawBody, headers: badHeaders });

    expect(result.status).toBe(401);
    expect(email.sent).toHaveLength(0);
  });

  it("rejects a webhook whose timestamp is too old (replay protection)", async () => {
    const rawBody = JSON.stringify({ type: "order.paid", data: { id: order.id } });
    const headers = buildWebhookHeaders(rawBody, nowSeconds() - 3600);

    const result = await handleWebhook(deps, { rawBody, headers });

    expect(result.status).toBe(401);
    expect(email.sent).toHaveLength(0);
  });

  it("returns 404 when the order can't be found via the API", async () => {
    const rawBody = JSON.stringify({ type: "order.paid", data: { id: "does_not_exist" } });
    const headers = buildWebhookHeaders(rawBody, nowSeconds());

    const result = await handleWebhook(deps, { rawBody, headers });

    expect(result.status).toBe(404);
  });

  it("returns 409 (not 200) if the canonically-fetched order disagrees and isn't paid yet", async () => {
    polar.orders.set(order.id, { ...order, paid: false });
    const rawBody = JSON.stringify({ type: "order.paid", data: { id: order.id } });
    const headers = buildWebhookHeaders(rawBody, nowSeconds());

    const result = await handleWebhook(deps, { rawBody, headers });

    expect(result.status).toBe(409);
    expect(email.sent).toHaveLength(0);
  });

  it("returns 503 (outside the 2xx range, so Polar retries) when the grant isn't ready yet", async () => {
    polar.grantsByCustomer.set(order.customerId, []);
    const rawBody = JSON.stringify({ type: "order.paid", data: { id: order.id } });
    const headers = buildWebhookHeaders(rawBody, nowSeconds());

    const result = await handleWebhook(deps, { rawBody, headers });

    expect(result.status).toBe(503);
    expect(email.sent).toHaveLength(0);
  });

  it("ignores non order.paid event types without erroring the delivery", async () => {
    const rawBody = JSON.stringify({ type: "order.updated", data: { id: order.id } });
    const headers = buildWebhookHeaders(rawBody, nowSeconds());

    const result = await handleWebhook(deps, { rawBody, headers });

    expect(result.status).toBe(200);
    expect(email.sent).toHaveLength(0);
  });
});

describe("handleRecover", () => {
  let polar: FakePolarClient;
  let email: FakeEmailSender;
  let deps: HandlerDeps;

  const order: PolarOrder = {
    id: "order_2",
    customerId: "cust_2",
    customerEmail: "recover-me@example.com",
    paid: true,
    createdAt: new Date(1_650_000_000 * 1000),
  };

  beforeEach(() => {
    polar = new FakePolarClient();
    email = new FakeEmailSender();
    deps = {
      polar,
      email,
      webhookSecret: WEBHOOK_SECRET,
      ed25519PrivateKey: PRIVATE_KEY,
      recoverRateLimiter: new InMemoryRateLimiter(100, 60),
    };

    polar.customerIdByEmail.set(order.customerEmail!, order.customerId);
    polar.orders.set(order.id, order);
    polar.grantsByCustomer.set(order.customerId, [
      { id: "grant_2", customerId: order.customerId, createdAt: new Date(), isGranted: true, licenseKeyId: "lk_2" },
    ]);
    polar.licenseKeys.set("lk_2", { id: "lk_2", key: "POLAR-KEY-0002" });
  });

  it("emails the same license string that the original webhook would have produced", async () => {
    const result = await handleRecover(deps, { email: order.customerEmail!, clientIp: "1.2.3.4" });

    expect(result.status).toBe(200);
    expect(email.sent).toHaveLength(1);

    const recovered = extractLicenseString(email.sent[0]!.text);

    // Re-derive independently via the same signing path the webhook uses,
    // to prove determinism end to end (not just unit-level in license.ts).
    const rawBody = JSON.stringify({ type: "order.paid", data: { id: order.id } });
    const id = "msg_x";
    const timestamp = String(Math.floor(Date.now() / 1000));
    const signature = signWebhook(id, timestamp, rawBody);
    const webhookResult = await handleWebhook(deps, {
      rawBody,
      headers: new Headers({ "webhook-id": id, "webhook-timestamp": timestamp, "webhook-signature": signature }),
    });
    expect(webhookResult.status).toBe(200);
    const fromWebhook = extractLicenseString(email.sent[1]!.text);

    expect(recovered).toBe(fromWebhook);
  });

  it("returns the same generic response whether or not the email has an order (no enumeration)", async () => {
    const knownResult = await handleRecover(deps, { email: order.customerEmail!, clientIp: "1.2.3.4" });
    const unknownResult = await handleRecover(deps, { email: "nobody@example.com", clientIp: "1.2.3.4" });

    expect(knownResult.status).toBe(unknownResult.status);
    expect(knownResult.body).toEqual(unknownResult.body);
  });

  it("rejects invalid email input with 400", async () => {
    const result = await handleRecover(deps, { email: "not-an-email", clientIp: "1.2.3.4" });
    expect(result.status).toBe(400);
  });

  it("rate limits by IP", async () => {
    deps.recoverRateLimiter = new InMemoryRateLimiter(1, 60);
    const first = await handleRecover(deps, { email: order.customerEmail!, clientIp: "9.9.9.9" });
    const second = await handleRecover(deps, { email: "someone-else@example.com", clientIp: "9.9.9.9" });

    expect(first.status).toBe(200);
    expect(second.status).toBe(429);
  });

  it("rate limits by email independently of IP", async () => {
    deps.recoverRateLimiter = new InMemoryRateLimiter(1, 60);
    const first = await handleRecover(deps, { email: order.customerEmail!, clientIp: "1.1.1.1" });
    const second = await handleRecover(deps, { email: order.customerEmail!, clientIp: "2.2.2.2" });

    expect(first.status).toBe(200);
    expect(second.status).toBe(429);
  });
});
