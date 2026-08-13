/**
 * Rate limiting for the /recover endpoint (by IP and by email), so it can't
 * be used to enumerate which emails have an order. This does NOT count as
 * the "no state" the licensing logic must avoid -- it's abuse-prevention
 * infra, not license/activation state, and Cloudflare's native Rate
 * Limiting binding keeps it out of our hands entirely (no KV, no D1).
 *
 * Binding docs: https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/
 * Configure in wrangler.toml, see the [[unsafe.bindings]] block there.
 *
 * NOTE (unverified, see TODO.md): the Rate Limiting binding is/was gated
 * behind a beta flag on some accounts/plans. If it's unavailable, swap
 * CloudflareRateLimiter for a Durable-Object-based limiter -- do NOT fall
 * back to "no limiting", since that reopens the email-enumeration risk.
 */

export interface RateLimiter {
  /** Returns true if the request is allowed, false if it should be rejected with 429. */
  check(key: string): Promise<boolean>;
}

export interface CloudflareRateLimitBinding {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export class CloudflareRateLimiter implements RateLimiter {
  constructor(private readonly binding: CloudflareRateLimitBinding) {}

  async check(key: string): Promise<boolean> {
    const { success } = await this.binding.limit({ key });
    return success;
  }
}

/** Test double / local dev fallback: fixed-window in-memory limiter. */
export class InMemoryRateLimiter implements RateLimiter {
  private hits = new Map<string, { count: number; windowStart: number }>();

  constructor(
    private readonly maxHits: number,
    private readonly windowSeconds: number,
    private readonly nowSeconds: () => number = () => Math.floor(Date.now() / 1000),
  ) {}

  async check(key: string): Promise<boolean> {
    const now = this.nowSeconds();
    const entry = this.hits.get(key);

    if (!entry || now - entry.windowStart >= this.windowSeconds) {
      this.hits.set(key, { count: 1, windowStart: now });
      return true;
    }

    if (entry.count >= this.maxHits) {
      return false;
    }

    entry.count += 1;
    return true;
  }
}
