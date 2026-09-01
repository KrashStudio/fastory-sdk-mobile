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

    /// Whether a retry must not send a second exchange on this failure.
    ///
    /// One code only, and it is not an optimisation: § 2.5 requires that `sdk_rate_limited` not be
    /// presented as transient, and its sanction ladder counts requests from the caller's address.
    /// Every other refusal costs one request per tap, which is the fan's own business — this one
    /// costs everyone behind the same address a block with no expiry.
    var forbidsRetry: Bool {
        guard case .rejected(let code) = self else { return false }
        return code == FastoryLoadFailureClassifier.rateLimitedCode
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

    /// How long the exchange waits before it is declared failed. Set explicitly rather than left to
    /// `URLSession`'s 60 s default, which was four times Android's and made the same dead network
    /// two very different waits for the fan depending on the phone they held.
    static let exchangeTimeout: TimeInterval = 15

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

    /// Drops everything this resolver holds — and **answers** the waiters rather than forgetting
    /// them, which is the part that is not housekeeping.
    ///
    /// A waiter is a surface sitting on its loading state with nothing else to hear back from: a hub
    /// whose completion is discarded keeps spinning with its error view hidden, so the fan can
    /// neither see what happened nor press Retry again, and the host is told nothing either. The
    /// window is real because `configure` resets on the caller's schedule, not on the exchange's,
    /// and it widened the day Retry started parking a waiter of its own. Reported as unreachable:
    /// the exchange never answered, which is what § 9.1's `network` row describes, and it leaves the
    /// surface recoverable.
    ///
    /// State first, waiters after, so a callback coming back through `whenResolved` finds this
    /// resolver already clean rather than half-reset.
    func reset() {
        state = .idle
        stateConfig = nil
        let abandoned = waiters
        waiters.removeAll()
        abandoned.forEach { $0(.failure(.unreachable)) }
    }

    /// Drops an outcome that belongs to a configuration no longer being asked about. Keeping the
    /// stamped one for an equal configuration is **not** what decides whether a new exchange goes
    /// out: `resolve` moves `.failed` to `.resolving`, so a cached failure re-arms on an equal
    /// `configure` too, on both platforms. What an equal configuration really keeps is a cached
    /// *success*, which `configure` discards anyway on this platform by calling `reset()`
    /// unconditionally (§ 2.1).
    private func discardOutcomeFromAnotherConfiguration(_ config: FastoryConfig) {
        guard let stateConfig, stateConfig != config else { return }
        reset()
    }

    /// Re-arms a cached **failure** so the next resolution sends a new request — the fan pressing
    /// Retry on the error view, and nothing else (§ 9).
    ///
    /// The distinction this draws is the whole point. `whenResolved` hands a cached outcome straight
    /// back to every ordinary caller, which is what keeps a re-configure that changed nothing from
    /// paying for a round trip (§ 2.1); an explicit retry is the one caller that is asking for the
    /// opposite. Only `.failed` moves: a resolved workspace stays resolved, and an exchange already
    /// in flight is left to land, so a fan tapping Retry twice still sends one request.
    ///
    /// **And one refusal is never re-armed**, which is the difference between a button and a loop.
    /// `sdk_rate_limited` is the one code § 2.5 forbids presenting as transient, and its sanction
    /// escalates on the caller's *address* — shared by everyone behind one CGNAT or one stadium's
    /// wifi — until a third one blocks it with no expiry. A refusal answers in milliseconds, so the
    /// button is back under the fan's thumb at once: honouring the tap here is precisely how the SDK
    /// would become the looping client § 2.5 tells a host not to write. The error view stays and
    /// nothing leaves the device.
    func rearmAfterFailure() {
        guard case .failed(let error) = state, !error.forbidsRetry else { return }
        state = .idle
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
        request.timeoutInterval = Self.exchangeTimeout
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
