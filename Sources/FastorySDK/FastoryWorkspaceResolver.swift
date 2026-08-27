import Foundation

/// Why a publishable key could not be exchanged for a workspace. `code` carries the API's
/// machine-readable failure code (`sdk_key_revoked`, `sdk_application_not_allowed`, …) so hosts
/// branch on it instead of on a message.
public enum FastoryBootstrapError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreachable
    case rejected(code: String)
    case malformedResponse

    public var description: String {
        switch self {
        case .unreachable:
            return "could not reach the Fastory API to resolve the publishable key"
        case .rejected(let code):
            return "publishable key rejected: \(code)"
        case .malformedResponse:
            return "unexpected response from the Fastory API"
        }
    }

    /// The failure as a single code, which is the shape Android's resolver already produces and the
    /// one `FastoryLoadFailureClassifier` reads on both platforms. The two synthesised codes name
    /// outcomes the API never answers, and the classifier turns them back into a reason rather than
    /// letting either reach a host as something to branch on (§ 9.1).
    var code: String {
        switch self {
        case .unreachable:
            return FastoryLoadFailureClassifier.unreachableCode
        case .rejected(let code):
            return code
        case .malformedResponse:
            return FastoryLoadFailureClassifier.malformedResponseCode
        }
    }
}

struct FastoryWorkspace: Equatable, Sendable {
    let id: String
    let slug: String
}

/// Exchanges a publishable key for the workspace it belongs to, once per configuration.
///
/// The fanzone to open is not in the config when the host configures by key — it comes back from
/// `POST /sdk/auth/bootstrap`. `configure` starts the exchange and `openGames` waits on it, so the
/// public API stays synchronous and the hub reuses the loading and error views it already has.
///
/// The short-lived session token the endpoint also returns is deliberately dropped: no
/// authenticated route accepts it yet, and holding a credential nothing consumes only creates a
/// leak surface. It gets stored here when the routes that read it ship.
final class FastoryWorkspaceResolver {
    static let shared = FastoryWorkspaceResolver()

    // Spelled exactly as the API declares them in validate_publishable_key.ts.
    static let keyHeader = "x-fastory-publishable-key"
    static let applicationHeader = "x-fastory-application-id"

    private enum State {
        case idle
        case resolving
        case resolved(FastoryWorkspace)
        case failed(FastoryBootstrapError)
    }

    private var state: State = .idle
    /// The configuration `state` was reached for. A resolved workspace belongs to the configuration
    /// that asked for it: served under another one, its slug builds a hub URL in the wrong
    /// environment — the warm hub's defect reached by the resolver's route instead.
    /// `configure` resets this resolver anyway, but it does so on a later main-loop turn (§ 2.7), and
    /// a stamp closes the gap structurally instead of depending on that ordering.
    private var stateConfig: FastoryConfig?
    private var waiters: [(Result<FastoryWorkspace, FastoryBootstrapError>) -> Void] = []

    /// Seam for unit tests: production performs the real request.
    var performRequest: (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void = {
        request, completion in
        URLSession.shared.dataTask(with: request) { data, response, error in
            completion(data, response, error)
        }.resume()
    }

    /// Bundle identifier on iOS, package name on Android: the key only bootstraps for the
    /// applications it was created with, so this must match what the workspace declared.
    var applicationId: () -> String? = { Bundle.main.bundleIdentifier }

    func reset() {
        state = .idle
        stateConfig = nil
        waiters.removeAll()
    }

    /// Drops an outcome that belongs to a configuration no longer being asked about. Keeping the
    /// stamped one for an equal configuration is **not** what decides whether a new exchange goes
    /// out: `resolve` moves `.failed` to `.resolving`, so a cached failure re-arms on an equal
    /// `configure` too, on both platforms — that is § 9's escape hatch, and it does not pass through
    /// here. What an equal configuration really keeps is a cached *success*, which `configure`
    /// discards anyway on this platform by calling `reset()` unconditionally (§ 2.1).
    private func discardOutcomeFromAnotherConfiguration(_ config: FastoryConfig) {
        guard let stateConfig, stateConfig != config else { return }
        reset()
    }

    /// Starts the exchange if it has not run for this configuration yet.
    func resolve(config: FastoryConfig) {
        guard let key = config.publishableKey else { return }
        discardOutcomeFromAnotherConfiguration(config)
        switch state {
        case .resolving, .resolved:
            return
        case .idle, .failed:
            state = .resolving
        }
        stateConfig = config

        guard let applicationId = applicationId(), !applicationId.isEmpty else {
            finish(.failure(.rejected(code: "sdk_application_id_required")))
            return
        }

        var request = URLRequest(url: config.environment.bootstrapURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: Self.keyHeader)
        request.setValue(applicationId, forHTTPHeaderField: Self.applicationHeader)

        performRequest(request) { [weak self] data, response, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                // `for: config` is the other half of the stamp. Written when the request starts and
                // never read when it lands, the stamp lets a re-configure be overtaken by its own
                // predecessor: the exchange for the previous configuration completes late, and
                // `finish` records *its* workspace against the current stamp and hands it to the
                // current configuration's waiters (SPEC § 2.1). Checked at both ends, a stale
                // exchange is simply dropped — the live one is already in flight behind it.
                self.handle(data: data, response: response, for: config)
            }
        }
    }

    /// Hands over the resolved workspace, waiting if the exchange is still in flight.
    func whenResolved(
        config: FastoryConfig,
        _ completion: @escaping (Result<FastoryWorkspace, FastoryBootstrapError>) -> Void
    ) {
        discardOutcomeFromAnotherConfiguration(config)
        switch state {
        case .resolved(let workspace):
            completion(.success(workspace))
        case .failed(let error):
            completion(.failure(error))
        case .resolving:
            waiters.append(completion)
        case .idle:
            waiters.append(completion)
            resolve(config: config)
        }
    }

    private func handle(data: Data?, response: URLResponse?, for config: FastoryConfig) {
        guard stateConfig == config else { return }
        guard let httpResponse = response as? HTTPURLResponse, let data else {
            finish(.failure(.unreachable))
            return
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            finish(.failure(.malformedResponse))
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            // Every failure carries `code`; fall back to the status so an unexpected shape
            // (a proxy error page, say) still reaches the host as something actionable.
            let code = payload["code"] as? String ?? "http_\(httpResponse.statusCode)"
            finish(.failure(.rejected(code: code)))
            return
        }
        guard let workspace = payload["workspace"] as? [String: Any],
              let id = workspace["id"] as? String,
              let slug = workspace["slug"] as? String,
              !slug.isEmpty else {
            finish(.failure(.malformedResponse))
            return
        }
        finish(.success(FastoryWorkspace(id: id, slug: slug)))
    }

    private func finish(_ result: Result<FastoryWorkspace, FastoryBootstrapError>) {
        switch result {
        case .success(let workspace):
            state = .resolved(workspace)
        case .failure(let error):
            state = .failed(error)
        }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0(result) }
    }
}

extension FastoryEnvironment {
    /// The API host mirrors the fanzone host per environment; development points at the
    /// integrator's own base URL, which is where their API lives too.
    var bootstrapURL: URL {
        let base: URL
        switch self {
        case .production:
            base = URL(string: "https://api.fastory.io")!
        case .staging:
            base = URL(string: "https://api.staging.fastory.io")!
        case .development(let baseURL):
            base = baseURL
        }
        return base.appendingPathComponent("sdk/auth/bootstrap")
    }
}
