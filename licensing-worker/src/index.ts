import { Hono } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import { ResendEmailSender } from "./email.js";
import { handleRecover, handleWebhook, type HandlerDeps } from "./handlers.js";
import { HttpPolarClient } from "./polar.js";
import { CloudflareRateLimiter, InMemoryRateLimiter, type RateLimiter } from "./rate-limit.js";

export interface Env {
  // Vars (wrangler.toml [vars], safe to be non-secret)
  POLAR_API_BASE: string;
  POLAR_ORGANIZATION_ID: string;
  POLAR_LICENSE_KEYS_BENEFIT_ID: string;
  POLAR_PRODUCT_ID: string;
  RESEND_FROM_EMAIL: string;
  RESEND_REPLY_TO: string;

  // Secrets (wrangler secret put ...)
  POLAR_WEBHOOK_SECRET: string;
  POLAR_ACCESS_TOKEN: string;
  RESEND_API_KEY: string;
  /** 64 hex characters = 32-byte Ed25519 seed. */
  LICENSE_ED25519_PRIVATE_KEY: string;

  // Optional: Cloudflare native Rate Limiting binding. See rate-limit.ts.
  RECOVER_RATE_LIMITER?: { limit(options: { key: string }): Promise<{ success: boolean }> };
}

function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim();
  if (clean.length % 2 !== 0) {
    throw new Error("LICENSE_ED25519_PRIVATE_KEY must have an even number of hex characters");
  }
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = Number.parseInt(clean.substr(i * 2, 2), 16);
  }
  return bytes;
}

function buildDeps(env: Env, waitUntil: (promise: Promise<unknown>) => void): HandlerDeps {
  const polar = new HttpPolarClient({
    apiBase: env.POLAR_API_BASE,
    accessToken: env.POLAR_ACCESS_TOKEN,
    organizationId: env.POLAR_ORGANIZATION_ID,
    licenseKeysBenefitId: env.POLAR_LICENSE_KEYS_BENEFIT_ID,
    productId: env.POLAR_PRODUCT_ID,
  });

  const email = new ResendEmailSender({
    apiKey: env.RESEND_API_KEY,
    fromEmail: env.RESEND_FROM_EMAIL,
    replyTo: env.RESEND_REPLY_TO,
  });

  // Falls back to an in-memory (per-isolate, best-effort) limiter if the
  // Cloudflare Rate Limiting binding isn't configured, so local `wrangler
  // dev` and early deploys still work -- see TODO.md, this fallback is NOT
  // safe as the only line of defense in production because it resets on
  // every isolate recycle and isn't shared across colo locations.
  const recoverRateLimiter: RateLimiter = env.RECOVER_RATE_LIMITER
    ? new CloudflareRateLimiter(env.RECOVER_RATE_LIMITER)
    : new InMemoryRateLimiter(5, 60);

  return {
    polar,
    email,
    webhookSecret: env.POLAR_WEBHOOK_SECRET,
    ed25519PrivateKey: hexToBytes(env.LICENSE_ED25519_PRIVATE_KEY),
    recoverRateLimiter,
    waitUntil,
  };
}

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.json({ ok: true }));

app.post("/webhooks/polar", async (c) => {
  const rawBody = await c.req.text();
  const deps = buildDeps(c.env, (p) => c.executionCtx.waitUntil(p));
  const result = await handleWebhook(deps, { rawBody, headers: c.req.raw.headers });
  return c.json(result.body, result.status as ContentfulStatusCode);
});

app.post("/recover", async (c) => {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }

  const email = (body as { email?: unknown })?.email;
  if (typeof email !== "string") {
    return c.json({ error: "invalid_email" }, 400);
  }

  const clientIp = c.req.header("cf-connecting-ip") ?? "unknown";
  // deps.waitUntil is wired to the real ExecutionContext here so the
  // background Polar/Resend work in handleRecover keeps running after this
  // handler returns -- see the comment on handleRecover in handlers.ts for
  // why that matters (timing side channel on /recover).
  const deps = buildDeps(c.env, (p) => c.executionCtx.waitUntil(p));
  const result = await handleRecover(deps, { email, clientIp });
  return c.json(result.body, result.status as ContentfulStatusCode);
});

// Explicit default error handler: Hono's built-in default already returns a
// generic 500 without leaking the thrown error's message, but pinning that
// behavior here makes the guarantee visible in code instead of resting on
// framework default behavior that could change or be misread.
app.onError((err, c) => {
  console.error("unhandled error", { path: c.req.path, message: err instanceof Error ? err.message : String(err) });
  return c.json({ error: "internal_error" }, 500);
});

export default app;
