import Foundation

/// Why a publishable key could not be exchanged for a workspace. `code` carries the API's
/// machine-readable failure code (`sdk_key_revoked`, `sdk_application_not_allowed`, …) so hosts
/// branch on it instead of on a message.
public enum FastoryBootstrapError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreachable
    case rejected(code: String)
    case malformedResponse
    case workspaceMismatch(expected: String, resolved: String)

    public var description: String {
        switch self {
        case .unreachable:
            return "could not reach the Fastory API to resolve the publishable key"
        case .rejected(let code):
            return "publishable key rejected: \(code)"
        case .malformedResponse:
            return "unexpected response from the Fastory API"
        case .workspaceMismatch(let expected, let resolved):
            return "publishable key belongs to workspace \(resolved), not \(expected)"
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
        waiters.removeAll()
    }

    /// Starts the exchange if it has not run for this configuration yet.
    func resolve(config: FastoryConfig) {
        guard let key = config.publishableKey else { return }
        switch state {
        case .resolving, .resolved:
            return
        case .idle, .failed:
            state = .resolving
        }

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
                self.handle(data: data, response: response, expecting: config.workspaceId)
            }
        }
    }

    /// Hands over the resolved workspace, waiting if the exchange is still in flight.
    func whenResolved(
        config: FastoryConfig,
        _ completion: @escaping (Result<FastoryWorkspace, FastoryBootstrapError>) -> Void
    ) {
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

    private func handle(data: Data?, response: URLResponse?, expecting workspaceId: String?) {
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
        if let workspaceId, workspaceId != id {
            finish(.failure(.workspaceMismatch(expected: workspaceId, resolved: id)))
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
