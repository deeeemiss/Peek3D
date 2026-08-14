import Foundation

/// Mirrors Polar's `LicenseKeyStatus` enum exactly (`granted` / `revoked` /
/// `disabled`) — `components.schemas.LicenseKeyStatus` in Polar's live
/// OpenAPI document. `revoked` and `disabled` are both treated as "the
/// server says this key is no longer good" by `LicenseActivationService` —
/// see its doc comment for why they're folded together instead of given
/// separate handling.
enum PolarLicenseKeyStatus: String, Decodable, Equatable, Sendable {
    case granted
    case revoked
    case disabled
}

/// The subset of Polar's `LicenseKeyActivationRead` (returned by
/// `POST /v1/customer-portal/license-keys/activate`) this app actually
/// reads. Polar's real response has more fields (customer info, full nested
/// license key object, timestamps) — `JSONDecoder` ignores unknown keys by
/// default, so this deliberately narrow model never needs updating just
/// because Polar adds a field.
struct PolarActivation: Decodable, Equatable, Sendable {
    let activationId: String
    let label: String

    private enum CodingKeys: String, CodingKey {
        case activationId = "id"
        case label
    }
}

/// The subset of Polar's `ValidatedLicenseKey` (returned by
/// `POST /v1/customer-portal/license-keys/validate`) this app actually
/// reads.
struct PolarValidatedLicense: Decodable, Equatable, Sendable {
    let status: PolarLicenseKeyStatus
}

/// Polar's error envelope for a `403`/`404` response
/// (`components.schemas.NotPermitted` / `.ResourceNotFound` — same shape,
/// only the `error` string's value differs).
private struct PolarErrorBody: Decodable {
    let error: String
    let detail: String
}

/// Outcome of one Polar customer-portal license-key call. Four cases, not a
/// `Result<T, Error>`, because `LicenseActivationService` must react
/// differently to each — most importantly, `.transportFailure` (never
/// reached the server) must NEVER be treated the same as `.notFound`/
/// `.notPermitted` (the server was reached and gave a definitive answer).
/// Collapsing those into one "it failed" case is exactly the bug this app's
/// non-negotiable rule exists to prevent — see `LicenseActivationService`.
enum PolarAPIOutcome<Success> {
    /// `200`/`204` with a decodable body (or no body, for `Void`).
    case success(Success)
    /// `404` — Polar has no record of this key/activation. A real,
    /// server-given answer, not a network failure.
    case notFound(detail: String)
    /// `403` on `/activate` only — activation unsupported for this key, or
    /// its activation limit is already reached. This is the "already active
    /// elsewhere" signal for a device that just tried to become active.
    case notPermitted(detail: String)
    /// `422` — the request body didn't validate against Polar's schema.
    /// Should never happen against a correctly-built request; surfaced
    /// distinctly rather than silently folded into `.transportFailure` so a
    /// real bug here doesn't masquerade as "server unreachable".
    case validationError(detail: String)
    /// Never reached the server with a definitive answer: no connection,
    /// DNS failure, timeout, an unexpected non-JSON body, an HTTP status
    /// this client doesn't recognize, etc. `description` is for logs only —
    /// see `HTTPPolarLicenseAPIClient` for what it does and does not
    /// contain (never the license key or email).
    case transportFailure(description: String)
}

/// The three Polar customer-portal license-key operations this app needs,
/// behind a protocol so `LicenseActivationService` can be driven by
/// `HTTPPolarLicenseAPIClient` (real network) or `FakePolarLicenseAPIClient`
/// (scripted, in-memory) — same shape as `licensing-worker/src/polar.ts`'s
/// `PolarClient` interface + `FakePolarClient`, and for the same reasons:
/// tests need to run with zero network and no live Polar account.
///
/// All three map 1:1 onto `POST /v1/customer-portal/license-keys/{activate,
/// validate,deactivate}` — the UNAUTHENTICATED variant (empty `security` in
/// Polar's OpenAPI spec), the one meant to be called directly from a public
/// client like this app. The organization-scoped `/v1/license-keys/*`
/// variants (which DO require a bearer token with `license_keys:write`) are
/// deliberately NOT used here — embedding that token in a shipped binary
/// would hand every user the ability to activate/deactivate/inspect any
/// customer's license key, not just their own.
protocol PolarLicenseAPIClient {
    /// `POST /v1/customer-portal/license-keys/activate`. `label` is this
    /// device's identifier (see `MachineIdentifier`) — Polar's schema calls
    /// it a free-form "activation instance label"; using the machine
    /// identifier hash there is what lets a human (or `licenze@peek3d.app`,
    /// per the support flow in `docs/FAQ.en.md`) tell which Mac an
    /// activation belongs to without this app ever sending the raw hardware
    /// UUID.
    func activate(key: String, organizationId: String, label: String) async -> PolarAPIOutcome<PolarActivation>

    /// `POST /v1/customer-portal/license-keys/validate`. `activationId` is
    /// REQUIRED here (unlike Polar's schema, where it's optional) — this
    /// app only ever validates a specific activation it already holds, never
    /// a bare key with no device context, so there is no legitimate call
    /// site for the schema's "no activation_id" mode.
    func validate(key: String, organizationId: String, activationId: String) async -> PolarAPIOutcome<PolarValidatedLicense>

    /// `POST /v1/customer-portal/license-keys/deactivate`. Frees the seat
    /// server-side so the SAME key can activate elsewhere — the self-service
    /// building block behind "free up its seat yourself" in `docs/FAQ.en.md`.
    func deactivate(key: String, organizationId: String, activationId: String) async -> PolarAPIOutcome<Void>
}
