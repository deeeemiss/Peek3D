# Peek3D licensing worker

Cloudflare Worker that issues Peek3D license keys after a Polar.sh purchase.
No database, no persistent state -- every piece of information the worker
needs (order, customer, license key) lives in Polar, and the worker's own
output (the signed license string) is a pure function of that data plus a
private key held only as a Workers secret.

## What it does

1. **`POST /webhooks/polar`** -- receives Polar's `order.paid` webhook,
   verifies its Standard Webhooks HMAC-SHA256 signature, re-fetches the
   order canonically from the Polar API, finds the License Keys benefit
   grant issued for that customer, signs a license string with Ed25519, and
   emails it via Resend as plain copyable text.

2. **`POST /recover`** -- given `{ "email": "..." }`, looks up the
   customer's most recent paid order the same way, and re-derives (not
   re-generates -- the string is a deterministic function of the same
   inputs) and re-emails the identical license string. Always returns the
   same generic "if we find an order you'll get an email" response,
   regardless of whether the email actually has one, and is rate-limited by
   both IP and email.

See `SETUP.md` for the account/keys/deploy checklist, and `TODO.md` for the specific assumptions in this pipeline that still need
confirming against a real Polar order (there's no live account to test
against yet).

## Architecture

```
Polar ──order.paid webhook (HMAC signed)──▶ POST /webhooks/polar
                                                   │
                                                   ▼
                                    verify signature (Standard Webhooks)
                                                   │
                                                   ▼
                              GET /v1/orders/{id}  (canonical order data)
                                                   │
                                                   ▼
                    GET /v1/benefits/{id}/grants?customer_id=...
                                                   │
                                                   ▼
                         GET /v1/license-keys/{id}  (the actual key)
                                                   │
                                                   ▼
                    sign {version, product, issued_at, key, email}
                              with Ed25519 → Crockford Base32
                                                   │
                                                   ▼
                              Resend: email "PK3D-..." to customer

Customer, later, if the email is lost:
POST /recover {email} ──▶ find customer by email ──▶ find latest paid order
                       ──▶ (same grant/key/sign pipeline as above)
                       ──▶ re-email the SAME "PK3D-..." string
```

`/recover` produces the same string as the original webhook because both
paths build the license from the same inputs (`order.created_at`, the
Polar license key value, the customer email) run through the same
deterministic Ed25519 signature -- see `src/handlers.ts`'s
`buildLicenseForOrder`, shared by both routes.

## License string format (authoritative, shared with the Swift verifier)

See the header comment in `src/license.ts` for the full byte layout. In
short: a small binary struct (schema version, product id, issued_at,
Polar's license key string, the buyer's email) signed with Ed25519, then
Crockford-Base32-encoded and grouped into `PK3D-XXXXX-XXXXX-...`.

**Do not change this format** without coordinating with the Swift verifier
side and regenerating `TEST_VECTORS.md` on both sides.

## Project layout

```
src/
  crockford.ts       Crockford Base32 encode/decode (no padding, MSB-first)
  license.ts         Binary payload pack/unpack + Ed25519 sign/verify
  webhook-verify.ts  Standard Webhooks HMAC-SHA256 verification
  polar.ts           Polar API client behind an interface + in-memory fake
  email.ts           Email sending behind an interface + in-memory fake
  rate-limit.ts       /recover rate limiting behind an interface
  handlers.ts        Pure, DI'd request handlers (the actual logic)
  index.ts           Hono app: wires real implementations to Workers env

test/                vitest unit + integration tests (all fakes, no network)
scripts/
  gen-keypair.ts     Generate a real production Ed25519 keypair
  gen-test-vectors.ts   Regenerate TEST_VECTORS.md from a fixed test keypair
TEST_VECTORS.md       Cross-check vectors for the Swift verifier (generated)
TODO.md              Assumptions that need confirming against a real order
```

## Setup

```bash
npm install
npm test          # 42 tests, no network/account needed
npm run typecheck  # tsc against both the Workers and the Node/test tsconfigs
```

### Configuration

Edit the non-secret values in `wrangler.toml` `[vars]`:

- `POLAR_ORGANIZATION_ID` -- from the Polar dashboard.
- `POLAR_LICENSE_KEYS_BENEFIT_ID` -- the License Keys *benefit's* id, not
  the product id (Settings → Benefits in the Polar dashboard).
- `POLAR_PRODUCT_ID` -- Peek3D's product id, used to scope `/recover`'s
  order lookup.
- `RESEND_FROM_EMAIL` -- must be on a domain verified in Resend.

Then set the secrets (never put these in `wrangler.toml` or commit them):

```bash
wrangler secret put POLAR_WEBHOOK_SECRET       # from Polar's webhook endpoint settings
wrangler secret put POLAR_ACCESS_TOKEN         # Polar API access token (orders:read, benefits:read scopes)
wrangler secret put RESEND_API_KEY             # Resend dashboard
wrangler secret put LICENSE_ED25519_PRIVATE_KEY  # see below
```

### Generating the production Ed25519 keypair

```bash
npm run keygen
```

This prints a private key (hex) and public key (hex). Put the private key
into `wrangler secret put LICENSE_ED25519_PRIVATE_KEY` and immediately clear
your terminal scrollback -- it is never stored anywhere by this script. Give
the public key to whoever builds the Swift verifier; it is not secret and is
meant to be embedded in the shipped app.

**This keypair is entirely separate from `POLAR_WEBHOOK_SECRET`** (which
authenticates that a webhook really came from Polar) and from
`POLAR_ACCESS_TOKEN` (which authenticates the worker to Polar's API). Losing
the Ed25519 private key means re-issuing it and shipping a new app build
with the new public key baked in -- every previously issued license string
becomes unverifiable. Treat it accordingly.

### Local development

```bash
npm run dev
```

`wrangler dev` reads secrets from a local `.dev.vars` file (gitignored) in
the same `KEY=value` format as `wrangler secret put`. Point Polar's webhook
endpoint (or `curl`, for manual testing) at the `wrangler dev` tunnel URL.

### Deploy

```bash
npm run deploy
```

## Testing philosophy

Every external dependency (Polar's API, Resend, the rate limiter) sits
behind a small interface in `src/`, with both a real implementation and an
in-memory fake (`FakePolarClient`, `FakeEmailSender`, `InMemoryRateLimiter`).
`src/handlers.ts` contains the actual request-handling logic as plain,
dependency-injected async functions with no Cloudflare-specific types in
sight -- `src/index.ts` is a thin Hono adapter on top. This means the whole
webhook → verify → fetch order → find grant → sign → email pipeline, and
the whole recover → lookup → re-derive → email pipeline, run in `test/
handlers.test.ts` with zero network calls and no real Polar/Resend account.
