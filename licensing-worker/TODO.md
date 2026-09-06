# Open questions to verify against a real Polar order

Everything below was designed from Polar's public documentation (fetched
2026-08-13) rather than a live account, per the brief. Docs for a fast-moving
API can lag or omit details, so treat each of these as "verify on the first
real order, don't assume."

## 1. `issued_at` source: `order.created_at` vs. the true payment instant

Polar's documented `Order` schema has no `paid_at` field -- only `created_at`
and a `paid` boolean. We use `order.created_at` as `issued_at` because:

- it's immutable, which is what lets `/recover` deterministically re-derive
  the exact same license string later (see point 4);
- for a one-time-purchase checkout, the order should already be created in
  `paid` status, so `created_at` should coincide with the payment moment.

**Verify:** pull a real paid order and confirm `created_at` really does
match when the card was actually charged, not when the checkout session was
first opened. If Polar creates the order in `pending` status and flips it to
`paid` later (e.g. for a payment method with async confirmation), `created_at`
would be wrong and we'd need a different immutable field -- or to accept
`modified_at` and give up on `/recover` being deterministic across the
lifetime of the order (see point 4 for why that's a real tradeoff, not just
a theoretical one).

## 2. License key ↔ order linkage: none exists in the API

Polar's API does not expose a direct link from an order to "the license key
this order granted." We reconstruct it by:

1. Fetching the order canonically (`GET /v1/orders/{id}`) to get `customer_id`.
2. Listing that customer's grants against our configured License Keys
   benefit (`GET /v1/benefits/{benefit_id}/grants?customer_id=...`).
3. Taking the **most recently created granted** grant, reading its
   `properties.license_key_id`.
4. Fetching that license key (`GET /v1/license-keys/{id}`) for the full `key`.

This is exact for a customer's first purchase. **Verify:** what happens on a
customer's *second* purchase of the same product (repurchase, gift, whatever
your refund/re-buy policy allows)? The "most recent grant" heuristic would
then pick the newest grant regardless of which order the webhook was
actually about. If that's a real scenario for Peek3D, this needs a better
disambiguator -- possibly `benefit_grant.created` webhook timing correlated
with `order.paid` timing, since both fire close together per purchase.

## 3. `order.paid` webhook envelope shape

Polar's docs state the event exists but the exact JSON body shape (whether
the order is inlined directly or wrapped as `{"type": ..., "data": {...}}`)
wasn't recoverable from the docs available at the time of writing.

**Mitigation already built in:** `handleWebhook` only reads `id` from the
webhook body (trying `data.id` then falling back to top-level `id`), then
re-fetches the order canonically via the API for everything else. So even
if this guess about the envelope is wrong in one direction, the worst case
is a `400 missing_order_id` (visible immediately in Polar's webhook delivery
log) rather than a corrupted license.

**Confirmed 2026-09-06** on the first real order: the envelope is
`{"type": "order.paid", "timestamp": …, "api_version": "2026-10", "data": {…}}`,
so reading `data.id` is correct. No change needed.

Checked 2026-09-05: Polar's dashboard has **no "send test event" button** --
the assumption above was wrong. Deliveries can only be *redelivered* once one
exists, so this can't be exercised before a real (or 100%-discounted) order.

## 4. Grant timing race: does the benefit grant exist yet when `order.paid` fires?

We assume that by the time `order.paid` is delivered, Polar has already
created the License Keys benefit grant (and thus the license key) for that
order. If grant creation happens asynchronously *after* the webhook fires,
`buildLicenseForOrder` will find no grant and the handler returns `503`
(deliberately outside the 2xx range, so standard webhook retry semantics
treat this delivery as failed and retry it) rather than `200`.

**Confirmed 2026-09-06:** the grant already existed when `order.paid` was
delivered — the first successful delivery returned `200` immediately, never
`503`. Polar's retry behaviour was also observed for real: it re-sent the
same event repeatedly while it kept returning 401 (18:05 → 18:18), so
non-2xx really does trigger retries.

## 5. Rate limiting binding syntax

`wrangler.toml` configures Cloudflare's native Rate Limiting binding via
`[[unsafe.bindings]]` with `type = "ratelimit"`. This was the documented
syntax at the time of writing but the API may have graduated to a
first-class `[[ratelimits]]` table since.

**Resolved 2026-09-05:** `wrangler deploy` accepted the binding as written
(it reports `Unsafe Metadata: ratelimit: RECOVER_RATE_LIMITER`), only warning
that "unsafe" fields are experimental. Nothing to change. If a future wrangler
rejects it, fix the syntax -- never drop rate limiting from `/recover`, which
would turn it into an email enumeration oracle (see `rate-limit.ts`).

## 6. Resend "from" domain verification

`RESEND_FROM_EMAIL` sends from `licenze@peek3d.sebdemichelis.dev` -- a
subdomain dedicated to sending, so its SPF/DKIM records never touch the
apex record that iCloud+ uses for Sebastiano's personal mail. That subdomain
has no MX, so `RESEND_REPLY_TO` points replies at `peek3d@sebdemichelis.dev`,
a real iCloud+ alias. Resend requires the sending domain to be verified
(SPF/DKIM records) before it will actually deliver -- this needs doing in
the Resend dashboard before the first real webhook fires, or emails will
silently fail (the worker will return a 5xx from `ResendEmailSender.send`
and Polar will retry, but no email reaches anyone in the meantime).

## 7. Product ID / organization ID / benefit ID placeholders -- DONE (2026-08-14)

`wrangler.toml`'s `[vars]` block and `Peek3D/PolarLicenseConfig.swift` now
carry the real Demichelis Studios / Peek3D organization ID, product ID, and
License Keys benefit ID from the live Polar dashboard.


## 8. Webhook signature: two HMAC keys, depending on the secret's age -- RESOLVED (2026-09-06)

The first real order failed on every delivery with `401 invalid_signature`,
and no email went out. Cause: Polar derives the HMAC key from the `whsec_…`
secret in two different ways, and which one applies depends on **when the
secret was generated**, not on the delivery:

- generated before 2026-09-08T00:00Z ("Polar HMAC", shown in the dashboard
  as *Legacy signing*): the key is the UTF-8 bytes of the **whole** string,
  `whsec_` prefix included;
- generated on or after that instant (Standard Webhooks): the part after
  `whsec_`, base64-decoded.

The worker only implemented the second. An existing endpoint never migrates
by itself, so this would not have fixed itself after the cutover date.

`verifyPolarWebhook` now checks the signature against **both** candidate
keys, which is what Polar's own SDKs do. It costs nothing in security — an
attacker still has to know the secret to forge either MAC — and it means a
future secret rotation works under either scheme without a code change.
Covered by `accepts a legacy Polar HMAC signature…` in
`test/webhook-verify.test.ts`, verified by sabotage (it fails if the legacy
key is removed).
