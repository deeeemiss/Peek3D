import Foundation

/// Configuration for the single-machine activation layer (`PolarLicenseAPIClient`
/// and `LicenseActivationService`). Kept in its own tiny file, not buried
/// inside the client, so the one value that MUST change before shipping is
/// impossible to miss.
///
/// Every field name and endpoint shape this app talks to
/// (`/v1/customer-portal/license-keys/{activate,validate,deactivate}`, the
/// `key`/`organization_id`/`label`/`activation_id` request fields, the
/// `status`/`activation` response fields) was read directly from Polar's
/// live OpenAPI document at `https://api.polar.sh/openapi.json` on
/// 2026-08-14 — not guessed, not inferred from the (org-authenticated)
/// `/v1/license-keys/*` variants a Node SDK README describes. The
/// `customer-portal` variant is the one whose `security` field is empty in
/// the spec, i.e. the one Polar intends a public, unauthenticated client
/// (a shipped desktop app, exactly like this one) to call directly. See
/// `HTTPPolarLicenseAPIClient` for the full mapping.
enum PolarLicenseConfig {
    /// Polar organization ID, required in the body of every
    /// `/v1/customer-portal/license-keys/*` call (`organization_id`,
    /// `string(uuid4)`, per the OpenAPI schema). NOT secret — it identifies
    /// which storefront a request is against, the same way `POLAR_ORGANIZATION_ID`
    /// already does in `licensing-worker/wrangler.toml`.
    ///
    /// Set to the real Demichelis Studios / Peek3D organization ID
    /// (2026-08-14) — matches `POLAR_ORGANIZATION_ID` in
    /// `licensing-worker/wrangler.toml`.
    static let organizationId = "7f3f54b3-470d-4704-be44-4d1e7e53b319"

    /// `https://api.polar.sh` in production.
    ///
    /// Overridable ONLY in DEBUG via `PEEK3D_POLAR_API_BASE_OVERRIDE` (a
    /// full base URL string, e.g. `http://127.0.0.1:8933`) — this is how the
    /// real compiled app is pointed at a local fake-Polar HTTP server for
    /// manual verification (see `scripts/fake_polar_server.py` and
    /// `scripts/test_activation.sh`) instead of ever needing a live account.
    /// Structurally absent from Release builds: the `#if DEBUG` block below
    /// doesn't exist in that binary, so this can never become a way to
    /// silently redirect a shipped copy's license traffic.
    static var apiBase: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["PEEK3D_POLAR_API_BASE_OVERRIDE"],
           let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "https://api.polar.sh")!
    }
}
