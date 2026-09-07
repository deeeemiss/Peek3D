import Foundation

/// Real implementation of `PolarLicenseAPIClient`: hand-written `URLSession`
/// calls against `POST {apiBase}/v1/customer-portal/license-keys/{activate,
/// validate,deactivate}` — no Polar SDK exists for Swift, per this task's
/// brief, so this talks HTTP directly. Field names, required-ness, and
/// status codes below were read from Polar's live OpenAPI document
/// (`https://api.polar.sh/openapi.json`, fetched 2026-08-14) — see
/// `PolarLicenseConfig` and `PolarLicenseAPIClient` for the verification
/// trail and what's still unconfirmed against a real account.
final class HTTPPolarLicenseAPIClient: PolarLicenseAPIClient {
    private let baseURL: URL
    private let session: URLSession

    /// `.ephemeral`, not `.default` — this traffic has no business being
    /// cached or cookie-tracked, and an ephemeral session needs no on-disk
    /// cache directory inside the sandbox container.
    ///
    /// Explicit timeouts on both axes: `timeoutIntervalForRequest` bounds
    /// how long a single attempt can hang with no data at all,
    /// `timeoutIntervalForResource` bounds the whole exchange even if bytes
    /// trickle in slowly. Both exist because "a request that pends forever
    /// is indistinguishable from a hang" — this app's background activation/
    /// reverify calls must always resolve to SOME outcome in bounded time,
    /// never hold a `Task` open indefinitely.
    init(baseURL: URL = PolarLicenseConfig.apiBase) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: configuration)
    }

    func activate(key: String, organizationId: String, label: String) async -> PolarAPIOutcome<PolarActivation> {
        await perform(
            path: "/v1/customer-portal/license-keys/activate",
            body: ["key": key, "organization_id": organizationId, "label": label],
            decode: PolarActivation.self
        )
    }

    func validate(key: String, organizationId: String, activationId: String) async -> PolarAPIOutcome<PolarValidatedLicense> {
        await perform(
            path: "/v1/customer-portal/license-keys/validate",
            body: ["key": key, "organization_id": organizationId, "activation_id": activationId],
            decode: PolarValidatedLicense.self
        )
    }

    func deactivate(key: String, organizationId: String, activationId: String) async -> PolarAPIOutcome<Void> {
        await performExpectingNoBody(
            path: "/v1/customer-portal/license-keys/deactivate",
            body: ["key": key, "organization_id": organizationId, "activation_id": activationId]
        )
    }

    // MARK: - Shared request/response plumbing

    private func makeRequest(path: String, body: [String: String]) -> URLRequest? {
        let url = baseURL.appendingPathComponent(path)
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `label` never carries anything except `MachineIdentifier.current()`
    /// output (see `PolarLicenseAPIClient.activate`'s doc comment) — never
    /// the raw hardware UUID, the license key, or the email inside it. This
    /// log line is deliberately limited to path + HTTP status, nothing from
    /// the request or response body, so it can never leak the license key,
    /// the purchase email embedded in it, or the machine identifier.
    private func logFailure(path: String, status: Int?, transportError: String? = nil) {
        if let status {
            print("PolarLicenseAPIClient: \(path) -> HTTP \(status)")
        } else {
            // `transportError` is a `URLError`/system error description
            // (e.g. connection refused, ATS policy, DNS failure) — never
            // PII, just the transport-level reason nothing was reached.
            print("PolarLicenseAPIClient: \(path) -> transport failure\(transportError.map { ": \($0)" } ?? " (no response)")")
        }
    }

    private func perform<T: Decodable>(
        path: String,
        body: [String: String],
        decode responseType: T.Type
    ) async -> PolarAPIOutcome<T> {
        guard let request = makeRequest(path: path, body: body) else {
            return .transportFailure(description: "failed to encode request body")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logFailure(path: path, status: nil, transportError: String(describing: error))
            return .transportFailure(description: String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            return .transportFailure(description: "non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
                logFailure(path: path, status: http.statusCode)
                return .transportFailure(description: "200 with undecodable body")
            }
            return .success(decoded)
        case 403:
            return .notPermitted(detail: errorDetail(from: data))
        case 404:
            return .notFound(detail: errorDetail(from: data))
        case 422:
            return .validationError(detail: errorDetail(from: data))
        default:
            logFailure(path: path, status: http.statusCode)
            return .transportFailure(description: "unexpected HTTP \(http.statusCode)")
        }
    }

    /// `deactivate` returns `204 No Content` on success per Polar's spec —
    /// no body to decode, so this is a separate small function rather than
    /// forcing `Void` through the generic `Decodable` path above.
    private func performExpectingNoBody(
        path: String,
        body: [String: String]
    ) async -> PolarAPIOutcome<Void> {
        guard let request = makeRequest(path: path, body: body) else {
            return .transportFailure(description: "failed to encode request body")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logFailure(path: path, status: nil, transportError: String(describing: error))
            return .transportFailure(description: String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            return .transportFailure(description: "non-HTTP response")
        }

        switch http.statusCode {
        case 204, 200:
            return .success(())
        case 404:
            return .notFound(detail: errorDetail(from: data))
        case 422:
            return .validationError(detail: errorDetail(from: data))
        default:
            logFailure(path: path, status: http.statusCode)
            return .transportFailure(description: "unexpected HTTP \(http.statusCode)")
        }
    }

    private func errorDetail(from data: Data) -> String {
        (try? JSONDecoder().decode(PolarErrorBody.self, from: data))?.detail ?? "no detail"
    }
}

/// Mirror of `PolarLicenseAPIClient.swift`'s private `PolarErrorBody` —
/// duplicated on purpose rather than shared, since Swift access control
/// would otherwise force it `internal` just to cross this file boundary,
/// widening its visibility for a two-field decode helper nothing else needs.
private struct PolarErrorBody: Decodable {
    let error: String
    let detail: String
}
