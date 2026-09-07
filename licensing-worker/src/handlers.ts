import { licenseEmailBody, type EmailSender } from "./email.js";
import { PRODUCT_ID_PEEK3D, SCHEMA_VERSION, signLicense } from "./license.js";
import type { PolarClient, PolarOrder } from "./polar.js";
import type { RateLimiter } from "./rate-limit.js";
import { extractWebhookHeaders, verifyPolarWebhook } from "./webhook-verify.js";

export interface HandlerDeps {
  polar: PolarClient;
  email: EmailSender;
  webhookSecret: string;
  ed25519PrivateKey: Uint8Array;
  recoverRateLimiter: RateLimiter;
  /**
   * Schedules work to run after the HTTP response has already been sent,
   * without making the response wait on it. In production this wraps
   * Cloudflare's `ExecutionContext.waitUntil` (see index.ts) -- the Workers
   * runtime keeps the isolate alive until the promise settles, but the
   * response itself is written the moment the handler returns.
   *
   * Tests supply a collector instead so they can deterministically await
   * the background work before asserting on its side effects (e.g. which
   * emails were sent) -- see test/handlers.test.ts.
   *
   * This exists specifically so /recover can respond BEFORE doing any of
   * the Polar/Resend calls that differ in cost between "email matches a
   * customer" and "email doesn't" -- see handleRecover below.
   */
  waitUntil: (promise: Promise<unknown>) => void;
}

export interface HttpResult {
  status: number;
  body: Record<string, unknown>;
}

function toUnixSeconds(date: Date): number {
  return Math.floor(date.getTime() / 1000);
}

/**
 * Given a paid order, look up its License Keys benefit grant and build the
 * signed license string. Shared by the webhook path and the /recover path
 * so both derive the exact same string for the exact same order.
 *
 * Returns null if the order has no matching license key yet (e.g. the
 * License Keys benefit grant hasn't been created server-side by Polar at
 * the moment order.paid fires -- see TODO.md "grant timing race").
 */
async function buildLicenseForOrder(
  deps: HandlerDeps,
  order: PolarOrder,
): Promise<{ licenseString: string; polarKey: string } | null> {
  if (!order.customerEmail) return null;

  const grants = await deps.polar.listLicenseKeyGrantsForCustomer(order.customerId);
  // No order_id <-> grant link is exposed by Polar's API (see TODO.md
  // "license key <-> order linkage"), so we take the most recently created
  // grant for this customer against our configured License Keys benefit.
  // For a customer with a single order this is exact; for a customer who
  // has purchased more than once it picks the newest grant, which needs
  // confirming against a real repeat-purchase before this is trusted.
  const grant = grants.find((g) => g.isGranted && g.licenseKeyId);
  if (!grant?.licenseKeyId) return null;

  const licenseKey = await deps.polar.getLicenseKey(grant.licenseKeyId);
  if (!licenseKey) return null;

  const licenseString = await signLicense(
    {
      schemaVersion: SCHEMA_VERSION,
      productId: PRODUCT_ID_PEEK3D,
      issuedAt: toUnixSeconds(order.createdAt),
      polarKey: licenseKey.key,
      email: order.customerEmail,
    },
    deps.ed25519PrivateKey,
  );

  return { licenseString, polarKey: licenseKey.key };
}

export interface WebhookRequestInput {
  rawBody: string;
  headers: Headers;
}

export async function handleWebhook(deps: HandlerDeps, input: WebhookRequestInput): Promise<HttpResult> {
  const verification = await verifyPolarWebhook({
    rawBody: input.rawBody,
    headers: extractWebhookHeaders(input.headers),
    secret: deps.webhookSecret,
  });

  if (!verification.valid) {
    // No processing, no leaking *why* beyond a generic 401 -- avoids giving
    // an attacker a signature-forging oracle.
    return { status: 401, body: { error: "invalid_signature" } };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(input.rawBody);
  } catch {
    return { status: 400, body: { error: "invalid_json" } };
  }

  const eventType = (parsed as { type?: string })?.type;
  if (eventType && eventType !== "order.paid") {
    // Defensive: if this endpoint is ever subscribed to more than
    // order.paid, ignore anything else instead of erroring the delivery.
    return { status: 200, body: { ok: true, ignored: eventType } };
  }

  // Polar's exact webhook envelope shape (whether the order is the payload
  // itself or nested under "data") isn't nailed down from docs alone -- see
  // TODO.md "webhook envelope shape". We only rely on it for the order id;
  // everything else is re-fetched canonically from the Orders API below, so
  // this ambiguity can't corrupt the issued license.
  const eventData = (parsed as { data?: unknown })?.data ?? parsed;
  const orderId = (eventData as { id?: string })?.id;

  if (!orderId || typeof orderId !== "string") {
    return { status: 400, body: { error: "missing_order_id" } };
  }

  const order = await deps.polar.getOrder(orderId);
  if (!order) {
    return { status: 404, body: { error: "order_not_found" } };
  }
  if (!order.paid) {
    // Redelivery/race: webhook says paid, canonical fetch disagrees. Ask
    // Polar to retry rather than issuing a license for an unpaid order.
    return { status: 409, body: { error: "order_not_paid_yet" } };
  }

  const result = await buildLicenseForOrder(deps, order);
  if (!result) {
    // The benefit grant may not exist yet at the instant order.paid fires.
    // Deliberately NOT 202: a 2xx status is "delivered, don't retry" under
    // Standard-Webhooks-style delivery semantics (which Polar's is built
    // on) -- returning 202 here would tell Polar this delivery succeeded
    // when it didn't, and the customer would simply never get a license.
    // 503 sits outside the 2xx range on every webhook retry implementation
    // we're aware of, which is what actually gets Polar to retry this
    // delivery once the grant exists. See TODO.md item 4 to confirm the
    // exact retry policy/backoff against a real account.
    return { status: 503, body: { ok: false, reason: "license_key_not_ready" } };
  }

  await deps.email.send(order.customerEmail!, "La tua licenza Peek3D", licenseEmailBody(result.licenseString));

  return { status: 200, body: { ok: true } };
}

export interface RecoverRequestInput {
  email: string;
  clientIp: string;
}

const GENERIC_RECOVER_RESPONSE: HttpResult = {
  status: 200,
  body: {
    ok: true,
    message: "Se troviamo un ordine associato a questa email, riceverai a breve la tua licenza.",
  },
};

export async function handleRecover(deps: HandlerDeps, input: RecoverRequestInput): Promise<HttpResult> {
  const email = input.email.trim().toLowerCase();
  if (!email || !email.includes("@")) {
    return { status: 400, body: { error: "invalid_email" } };
  }

  // Rate limit by IP and by email independently; either bucket tripping
  // blocks the request. Same generic response either way -- a 429 here
  // would itself leak "you're being rate limited specifically", which is
  // fine, but we still never want the *body* to reveal whether the email
  // has an order.
  const ipAllowed = await deps.recoverRateLimiter.check(`ip:${input.clientIp}`);
  const emailAllowed = await deps.recoverRateLimiter.check(`email:${email}`);
  if (!ipAllowed || !emailAllowed) {
    return { status: 429, body: { error: "rate_limited" } };
  }

  // Everything past this point -- the Polar customer/order/grant lookups
  // and the Resend email send -- is deliberately NOT awaited before
  // responding. An email that matches a paying customer costs several
  // sequential network calls (customer lookup, order lookup, grant list,
  // key fetch, then the Resend send itself); an email that matches nobody
  // costs exactly one. If that work ran inline, response latency alone
  // would tell a caller which case they're in, turning the intentionally
  // generic response body below into a customer-enumeration timing oracle
  // (this was a real audit finding -- see PR/commit history for the report).
  //
  // deps.waitUntil hands the work to Cloudflare's ExecutionContext.waitUntil
  // in production (via index.ts), which keeps it running after the response
  // is sent without the caller ever seeing its latency.
  deps.waitUntil(deliverRecoveredLicense(deps, email));

  return GENERIC_RECOVER_RESPONSE;
}

/**
 * The actual "find the customer's order and email them their license" work
 * for /recover, run in the background (see handleRecover). Every early
 * return here is deliberately silent to the caller -- the HTTP response
 * already went out before this started -- but a genuine failure (a Polar
 * API error, Resend rejecting the send, etc.) is NOT the same as "no
 * matching order" and must not be swallowed the same way: a customer who
 * asked for their license and never got one, with nobody aware it
 * happened, is worse than the timing leak this function exists to close.
 */
async function deliverRecoveredLicense(deps: HandlerDeps, email: string): Promise<void> {
  try {
    const customerId = await deps.polar.findCustomerIdByEmail(email);
    if (!customerId) return;

    const order = await deps.polar.findLatestPaidOrderForCustomer(customerId);
    if (!order || !order.paid) return;

    const result = await buildLicenseForOrder(deps, order);
    if (!result) return;

    await deps.email.send(email, "La tua licenza Peek3D", licenseEmailBody(result.licenseString));
  } catch (err) {
    // Runs after the response is already sent, so there's no request to
    // fail -- surface it loudly (Cloudflare captures console.error in the
    // worker's logs/Tail) instead of letting it disappear as a dropped
    // waitUntil rejection. Whoever operates this worker needs to be able to
    // find and manually resend to this customer.
    console.error("recover: background license delivery failed", {
      email,
      message: err instanceof Error ? err.message : String(err),
    });
  }
}
