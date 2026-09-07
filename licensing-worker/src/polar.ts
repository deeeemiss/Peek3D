/**
 * Polar API client, isolated behind an interface so the rest of the worker
 * (and its tests) never depend on a live Polar account. See FakePolarClient
 * in this file for the test double, and TEST_VECTORS.md / TODO.md for what
 * is verified-from-docs vs. inferred and still needs confirming against a
 * real order.
 */

export interface PolarOrder {
  id: string;
  customerId: string;
  customerEmail: string | null;
  paid: boolean;
  /**
   * Used as the license's issued_at. Polar's Order schema (as documented)
   * has no explicit "paid_at" field -- only "created_at" and a "paid"
   * boolean. For a one-time-purchase checkout the order is created already
   * in paid status, so created_at should coincide with the payment moment.
   * created_at is also immutable, which is what makes the /recover endpoint
   * able to deterministically re-derive the same license string later.
   * See TODO.md item "issued_at source" -- confirm with the first real order.
   */
  createdAt: Date;
}

export interface PolarBenefitGrant {
  id: string;
  customerId: string;
  createdAt: Date;
  isGranted: boolean;
  /** Only present for benefits of type "license_keys". */
  licenseKeyId: string | null;
}

export interface PolarLicenseKey {
  id: string;
  /** Full, unmasked key string. */
  key: string;
}

export interface PolarClient {
  getOrder(orderId: string): Promise<PolarOrder | null>;
  /** Grants for one customer against the configured License Keys benefit, newest first. */
  listLicenseKeyGrantsForCustomer(customerId: string): Promise<PolarBenefitGrant[]>;
  getLicenseKey(licenseKeyId: string): Promise<PolarLicenseKey | null>;
  /** Exact-match email lookup, used only by /recover. Returns null if no customer exists. */
  findCustomerIdByEmail(email: string): Promise<string | null>;
  /** Most recent paid order for a customer against the configured product, or null. */
  findLatestPaidOrderForCustomer(customerId: string): Promise<PolarOrder | null>;
}

export interface PolarConfig {
  apiBase: string;
  accessToken: string;
  organizationId: string;
  licenseKeysBenefitId: string;
  productId: string;
}

class PolarApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
  ) {
    super(message);
  }
}

/** Real implementation, talks to api.polar.sh. */
export class HttpPolarClient implements PolarClient {
  constructor(private readonly config: PolarConfig) {}

  private async request<T>(path: string, searchParams?: Record<string, string>): Promise<T> {
    const url = new URL(this.config.apiBase + path);
    if (searchParams) {
      for (const [key, value] of Object.entries(searchParams)) {
        url.searchParams.set(key, value);
      }
    }

    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${this.config.accessToken}`,
        Accept: "application/json",
      },
    });

    if (response.status === 404) {
      throw new PolarApiError("not_found", 404);
    }
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      throw new PolarApiError(`Polar API ${path} failed: ${response.status} ${body}`, response.status);
    }

    return (await response.json()) as T;
  }

  async getOrder(orderId: string): Promise<PolarOrder | null> {
    try {
      // Response shape per https://polar.sh/docs/api-reference/orders/get-order.md
      const raw = await this.request<{
        id: string;
        customer_id: string;
        customer: { email: string | null } | null;
        paid: boolean;
        created_at: string;
      }>(`/v1/orders/${orderId}`);

      return {
        id: raw.id,
        customerId: raw.customer_id,
        customerEmail: raw.customer?.email ?? null,
        paid: raw.paid,
        createdAt: new Date(raw.created_at),
      };
    } catch (err) {
      if (err instanceof PolarApiError && err.status === 404) return null;
      throw err;
    }
  }

  async listLicenseKeyGrantsForCustomer(customerId: string): Promise<PolarBenefitGrant[]> {
    // GET /v1/benefits/{id}/grants -- scoped to our License Keys benefit
    // already, so no separate benefit_id filter is needed or offered.
    // https://polar.sh/docs/api-reference/benefits/list-benefit-grants.md
    const raw = await this.request<{
      items: Array<{
        id: string;
        customer_id: string;
        created_at: string;
        is_granted: boolean;
        properties: { license_key_id?: string } | null;
      }>;
    }>(`/v1/benefits/${this.config.licenseKeysBenefitId}/grants`, {
      customer_id: customerId,
      is_granted: "true",
      limit: "100",
    });

    return raw.items
      .map((item) => ({
        id: item.id,
        customerId: item.customer_id,
        createdAt: new Date(item.created_at),
        isGranted: item.is_granted,
        licenseKeyId: item.properties?.license_key_id ?? null,
      }))
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  async getLicenseKey(licenseKeyId: string): Promise<PolarLicenseKey | null> {
    try {
      // https://polar.sh/docs/api-reference/license_keys/get-license-key.md
      const raw = await this.request<{ id: string; key: string }>(`/v1/license-keys/${licenseKeyId}`);
      return { id: raw.id, key: raw.key };
    } catch (err) {
      if (err instanceof PolarApiError && err.status === 404) return null;
      throw err;
    }
  }

  async findCustomerIdByEmail(email: string): Promise<string | null> {
    // https://polar.sh/docs/api-reference/customers/list-customers.md -- "email"
    // is documented as an exact-match filter.
    const raw = await this.request<{ items: Array<{ id: string }> }>("/v1/customers", {
      organization_id: this.config.organizationId,
      email,
      limit: "1",
    });
    return raw.items[0]?.id ?? null;
  }

  async findLatestPaidOrderForCustomer(customerId: string): Promise<PolarOrder | null> {
    // https://polar.sh/docs/api-reference/orders/list-orders.md -- no "paid"
    // filter exists server-side, so we sort by -created_at and take the
    // first order whose `paid` field is true.
    const raw = await this.request<{
      items: Array<{
        id: string;
        customer_id: string;
        customer: { email: string | null } | null;
        paid: boolean;
        created_at: string;
      }>;
    }>("/v1/orders", {
      organization_id: this.config.organizationId,
      customer_id: customerId,
      product_id: this.config.productId,
      sorting: "-created_at",
      limit: "100",
    });

    const paidOrder = raw.items.find((item) => item.paid);
    if (!paidOrder) return null;

    return {
      id: paidOrder.id,
      customerId: paidOrder.customer_id,
      customerEmail: paidOrder.customer?.email ?? null,
      paid: paidOrder.paid,
      createdAt: new Date(paidOrder.created_at),
    };
  }
}

/**
 * In-memory test double. Lets webhook/recovery logic be exercised end to end
 * with fixed, fake data -- no network, no live Polar account required.
 */
export class FakePolarClient implements PolarClient {
  orders = new Map<string, PolarOrder>();
  grantsByCustomer = new Map<string, PolarBenefitGrant[]>();
  licenseKeys = new Map<string, PolarLicenseKey>();
  customerIdByEmail = new Map<string, string>();

  async getOrder(orderId: string): Promise<PolarOrder | null> {
    return this.orders.get(orderId) ?? null;
  }

  async listLicenseKeyGrantsForCustomer(customerId: string): Promise<PolarBenefitGrant[]> {
    return [...(this.grantsByCustomer.get(customerId) ?? [])].sort(
      (a, b) => b.createdAt.getTime() - a.createdAt.getTime(),
    );
  }

  async getLicenseKey(licenseKeyId: string): Promise<PolarLicenseKey | null> {
    return this.licenseKeys.get(licenseKeyId) ?? null;
  }

  async findCustomerIdByEmail(email: string): Promise<string | null> {
    return this.customerIdByEmail.get(email) ?? null;
  }

  async findLatestPaidOrderForCustomer(customerId: string): Promise<PolarOrder | null> {
    const candidates = [...this.orders.values()]
      .filter((o) => o.customerId === customerId && o.paid)
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
    return candidates[0] ?? null;
  }
}
