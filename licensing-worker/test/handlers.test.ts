import { createHmac } from "node:crypto";
import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha512";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { FakeEmailSender, type EmailSender } from "../src/email.js";
import { handleRecover, handleWebhook, type HandlerDeps } from "../src/handlers.js";
import { decodePayload } from "../src/license.js";
import { decodeCrockford } from "../src/crockford.js";
import { FakePolarClient, type PolarClient, type PolarOrder } from "../src/polar.js";
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

/**
 * Test double for deps.waitUntil: collects the promises handed to it
 * instead of firing-and-forgetting them, so tests can deterministically
 * `await drain()` before asserting on the background work's side effects
 * (e.g. FakeEmailSender.sent) -- mirroring how the real ExecutionContext
 * keeps the isolate alive until the promise settles, just observable.
 */
function createWaitUntilCollector() {
  const pending: Promise<unknown>[] = [];
  return {
    waitUntil: (p: Promise<unknown>) => {
      pending.push(p);
    },
    drain: () => Promise.all(pending),
  };
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
      // handleWebhook never defers work to waitUntil -- it awaits everything
      // inline so Polar's webhook delivery result reflects the real outcome.
      // This is just here to satisfy HandlerDeps.
      waitUntil: () => {},
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

  it("picks the MOST RECENT grant's license key when a customer has more than one grant", async () => {
    // The `beforeEach` above seeds a single grant (lk_1) -- every other test
    // in this file only ever exercises the single-grant case, so a
    // comparator with its sign accidentally flipped in
    // `FakePolarClient.listLicenseKeyGrantsForCustomer` / the real
    // `PolarClient`'s equivalent (oldest-first instead of the intended
    // "most recently created grant" -- see the comment on
    // `buildLicenseForOrder` in src/handlers.ts) would never be caught: with
    // only one candidate, "most recent" and "oldest" pick the same element.
    // Seed a SECOND, OLDER grant here so only a correct descending sort
    // returns lk_1 first.
    polar.grantsByCustomer.set(order.customerId, [
      { id: "grant_1", customerId: order.customerId, createdAt: new Date(2_000_000_000 * 1000), isGranted: true, licenseKeyId: "lk_1" },
      { id: "grant_0", customerId: order.customerId, createdAt: new Date(1_000_000_000 * 1000), isGranted: true, licenseKeyId: "lk_0" },
    ]);
    polar.licenseKeys.set("lk_0", { id: "lk_0", key: "POLAR-KEY-0000-OLDER" });

    const rawBody = JSON.stringify({ type: "order.paid", data: { id: order.id } });
    const headers = buildWebhookHeaders(rawBody, nowSeconds());

    const result = await handleWebhook(deps, { rawBody, headers });

    expect(result.status).toBe(200);
    const licenseString = extractLicenseString(email.sent[0]!.text);
    const payload = decodeCrockford(licenseString.slice("PK3D-".length).replace(/-/g, ""));
    const decoded = decodePayload(payload.subarray(0, payload.length - 64));
    expect(decoded.polarKey).toBe("POLAR-KEY-0001");
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
  let waitUntilCollector: ReturnType<typeof createWaitUntilCollector>;

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
    waitUntilCollector = createWaitUntilCollector();
    deps = {
      polar,
      email,
      webhookSecret: WEBHOOK_SECRET,
      ed25519PrivateKey: PRIVATE_KEY,
      recoverRateLimiter: new InMemoryRateLimiter(100, 60),
      waitUntil: waitUntilCollector.waitUntil,
    };

    polar.customerIdByEmail.set(order.customerEmail!, order.customerId);
    polar.orders.set(order.id, order);
    polar.grantsByCustomer.set(order.customerId, [
      { id: "grant_2", customerId: order.customerId, createdAt: new Date(), isGranted: true, licenseKeyId: "lk_2" },
    ]);
    polar.licenseKeys.set("lk_2", { id: "lk_2", key: "POLAR-KEY-0002" });
  });

  it("responds before the background Polar/email work has settled (does not await it)", async () => {
    let deliveryFinished = false;
    const originalSend = email.send.bind(email);
    email.send = async (...args) => {
      await new Promise((resolve) => setTimeout(resolve, 20));
      deliveryFinished = true;
      return originalSend(...args);
    };

    const result = await handleRecover(deps, { email: order.customerEmail!, clientIp: "1.2.3.4" });

    // The handler must have returned WITHOUT waiting for the slow email
    // send -- this is the core of the fix, distinct from the response body
    // (which was always correct/generic; only its timing leaked data).
    expect(result.status).toBe(200);
    expect(deliveryFinished).toBe(false);
    expect(email.sent).toHaveLength(0);

    await waitUntilCollector.drain();
    expect(deliveryFinished).toBe(true);
    expect(email.sent).toHaveLength(1);
  });

  it("emails the same license string that the original webhook would have produced", async () => {
    const result = await handleRecover(deps, { email: order.customerEmail!, clientIp: "1.2.3.4" });
    await waitUntilCollector.drain();

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
    await waitUntilCollector.drain();

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
    await waitUntilCollector.drain();

    expect(first.status).toBe(200);
    expect(second.status).toBe(429);
  });

  it("rate limits by email independently of IP", async () => {
    deps.recoverRateLimiter = new InMemoryRateLimiter(1, 60);
    const first = await handleRecover(deps, { email: order.customerEmail!, clientIp: "1.1.1.1" });
    const second = await handleRecover(deps, { email: order.customerEmail!, clientIp: "2.2.2.2" });
    await waitUntilCollector.drain();

    expect(first.status).toBe(200);
    expect(second.status).toBe(429);
  });

  it("delivers the license even if the caller never awaits/observes the response (waitUntil work is not dropped)", async () => {
    // Simulates the real Workers contract: the response is what the caller
    // sees, but deps.waitUntil is what keeps the delivery work alive. If a
    // future refactor accidentally fire-and-forgets without registering
    // with waitUntil at all, this test's drain() would have nothing to
    // await and email.sent would stay empty -- catching a regression back
    // to "the promise silently rejects/never runs to completion".
    await handleRecover(deps, { email: order.customerEmail!, clientIp: "5.5.5.5" });
    await waitUntilCollector.drain();

    expect(email.sent).toHaveLength(1);
    expect(email.sent[0]!.to).toBe(order.customerEmail);
  });

  it("logs (does not silently swallow) a background delivery failure after the response was already sent", async () => {
    const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    email.send = async () => {
      throw new Error("Resend rejected the send");
    };

    const result = await handleRecover(deps, { email: order.customerEmail!, clientIp: "1.2.3.4" });
    expect(result.status).toBe(200);

    // The failure happens strictly after the response above was produced --
    // proving it doesn't affect the response -- but must still be visible.
    await waitUntilCollector.drain();

    expect(consoleErrorSpy).toHaveBeenCalled();
    const [message, context] = consoleErrorSpy.mock.calls[0]!;
    expect(String(message)).toContain("background license delivery failed");
    expect((context as { email?: string }).email).toBe(order.customerEmail);

    consoleErrorSpy.mockRestore();
  });
});

describe("handleRecover: timing side channel (audit finding)", () => {
  /**
   * Reproduces the exact defect the audit flagged: a non-matching email
   * used to cost a single Polar call, while a matching email with a paid
   * order cost several sequential Polar calls plus an inline Resend send --
   * a difference measured in hundreds of milliseconds, easily distinguished
   * by timing alone even though the response BODY was already identical.
   *
   * This test builds fake dependencies with controlled, deliberately large
   * latency on the "expensive" path (customer lookup, order lookup, grant
   * list, key fetch, email send) and near-zero latency on the "cheap"
   * path (a single customer lookup that finds nothing), the same shape as
   * the real Polar/Resend calls. It then asserts the wall-clock time to
   * get a *response* from handleRecover is close for both -- proving the
   * fix (deferring that work via waitUntil) actually closes the channel,
   * not just that the response body looks generic.
   */
  const LATENCY_MS = 150;
  const MAX_ALLOWED_DIFFERENCE_MS = 40; // generous vs. LATENCY_MS=150 -- would fail hard pre-fix

  function delay<T>(value: T, ms: number): Promise<T> {
    return new Promise((resolve) => setTimeout(() => resolve(value), ms));
  }

  class SlowPathPolarClient implements PolarClient {
    async getOrder(): Promise<PolarOrder | null> {
      return null;
    }
    async listLicenseKeyGrantsForCustomer() {
      return delay(
        [{ id: "g", customerId: "cust_slow", createdAt: new Date(), isGranted: true, licenseKeyId: "lk_slow" }],
        LATENCY_MS,
      );
    }
    async getLicenseKey() {
      return delay({ id: "lk_slow", key: "POLAR-KEY-SLOW" }, LATENCY_MS);
    }
    async findCustomerIdByEmail() {
      return delay("cust_slow", LATENCY_MS);
    }
    async findLatestPaidOrderForCustomer() {
      const order: PolarOrder = {
        id: "order_slow",
        customerId: "cust_slow",
        customerEmail: "slow@example.com",
        paid: true,
        createdAt: new Date(),
      };
      return delay(order, LATENCY_MS);
    }
  }

  class FastMissPolarClient implements PolarClient {
    async getOrder(): Promise<PolarOrder | null> {
      return null;
    }
    async listLicenseKeyGrantsForCustomer() {
      return [];
    }
    async getLicenseKey() {
      return null;
    }
    async findCustomerIdByEmail() {
      // The one call a non-matching email actually costs -- fast, no order chain behind it.
      return null;
    }
    async findLatestPaidOrderForCustomer() {
      return null;
    }
  }

  class SlowEmailSender implements EmailSender {
    sent: Array<{ to: string; subject: string; text: string }> = [];
    async send(to: string, subject: string, text: string): Promise<void> {
      await delay(undefined, LATENCY_MS);
      this.sent.push({ to, subject, text });
    }
  }

  it("responds in roughly the same time for a matching vs. a non-matching email", async () => {
    const matchDeps: HandlerDeps = {
      polar: new SlowPathPolarClient(),
      email: new SlowEmailSender(),
      webhookSecret: WEBHOOK_SECRET,
      ed25519PrivateKey: PRIVATE_KEY,
      recoverRateLimiter: new InMemoryRateLimiter(1000, 60),
      waitUntil: () => {}, // fire-and-forget is fine here; we only measure response latency
    };
    const missDeps: HandlerDeps = { ...matchDeps, polar: new FastMissPolarClient() };

    const t0 = performance.now();
    const matchResult = await handleRecover(matchDeps, { email: "slow@example.com", clientIp: "1.1.1.1" });
    const matchElapsed = performance.now() - t0;

    const t1 = performance.now();
    const missResult = await handleRecover(missDeps, { email: "nobody@example.com", clientIp: "2.2.2.2" });
    const missElapsed = performance.now() - t1;

    expect(matchResult.body).toEqual(missResult.body);
    expect(matchElapsed).toBeLessThan(MAX_ALLOWED_DIFFERENCE_MS);
    expect(missElapsed).toBeLessThan(MAX_ALLOWED_DIFFERENCE_MS);
    expect(Math.abs(matchElapsed - missElapsed)).toBeLessThan(MAX_ALLOWED_DIFFERENCE_MS);
  });
});
