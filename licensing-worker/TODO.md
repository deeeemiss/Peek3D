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

**Verify:** trigger a real `order.paid` delivery (Polar's dashboard has a
"send test event" / redelivery feature) and confirm the id is found. If not,
adjust the one line in `handleWebhook` that reads `eventData.id`.

## 4. Grant timing race: does the benefit grant exist yet when `order.paid` fires?

We assume that by the time `order.paid` is delivered, Polar has already
created the License Keys benefit grant (and thus the license key) for that
order. If grant creation happens asynchronously *after* the webhook fires,
`buildLicenseForOrder` will find no grant and the handler returns `503`
(deliberately outside the 2xx range, so standard webhook retry semantics
treat this delivery as failed and retry it) rather than `200`.

**Verify:** confirm Polar's actual retry policy (backoff schedule, max
attempts, and that it really does retry any non-2xx rather than only
specific codes) against a real account -- the 503 choice is a safe default
under Standard-Webhooks-style semantics, not something confirmed against
Polar specifically yet.

## 5. Rate limiting binding syntax

`wrangler.toml` configures Cloudflare's native Rate Limiting binding via
`[[unsafe.bindings]]` with `type = "ratelimit"`. This was the documented
syntax at the time of writing but the API may have graduated to a
first-class `[[ratelimits]]` table since. **Verify with `wrangler deploy`**
-- if it rejects the binding, check current docs and adjust. Do not remove
rate limiting from `/recover` as a workaround; that turns it into an email
enumeration oracle (see `rate-limit.ts` and `handlers.ts` for why).

## 6. Resend "from" domain verification

`RESEND_FROM_EMAIL` in `wrangler.toml` is a placeholder
(`licenze@peek3d.app`). Resend requires the sending domain to be verified
(SPF/DKIM records) before it will actually deliver -- this needs doing in
the Resend dashboard before the first real webhook fires, or emails will
silently fail (the worker will return a 5xx from `ResendEmailSender.send`
and Polar will retry, but no email reaches anyone in the meantime).

## 7. Product ID / organization ID / benefit ID placeholders

`wrangler.toml`'s `[vars]` block has three `REPLACE_WITH_...` placeholders.
These come from the Polar dashboard once the product and its License Keys
benefit exist for real: organization ID, product ID, and the License Keys
benefit's ID (not the product ID -- benefits have their own IDs).
