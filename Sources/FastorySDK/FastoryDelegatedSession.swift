import Foundation

/// The fan session the SDK gets back when it resolves an identified fan — a host attestation
/// (`identify(.hostToken)`) or a system-browser login code (`identify(.fanId)`).
///
/// `token` is the embed JWT the games read over the bridge and the hub reads through the handoff;
/// `fanId` is the account's `oauthUserId`, stringified — the only identifier the exchange returns that
/// is present on the first sight of a delegated fan and stable across replays of the same subject
/// (SPEC § 2.6.2). The `fanzoneUser` the API also returns is `nil` until the fan has a fanzone
/// profile, so it cannot be the identifier a host is handed for every resolution.
struct FastoryDelegatedSession: Equatable {
    let token: String
    let fanId: String
}

/// Maps an identity-exchange outcome to the `identify` error a host branches on (SPEC § 5.4).
///
/// Pure and table-driven: iOS and Android map the same outcomes the same way, so a `token_malformed`
/// cannot come back `identify_rejected` on one platform and `identify_network_error` on the other.
/// Kept out of the network client so it is assertable without a request.
enum FastoryIdentityExchangeClassifier {
    struct Outcome: Equatable {
        let identifyCode: String
        let detailsCode: String?
    }

    /// A non-2xx answer is a refusal: the SDK never verifies the assertion itself (SPEC § 12), so the
    /// API's own `code` is what reaches the host, carried in `details.code`. An answer whose body
    /// named no code still refuses — `detailsCode` is then `nil`, never invented.
    static func classify(httpStatus: Int, apiCode: String?) -> Outcome {
        Outcome(identifyCode: rejectedCode, detailsCode: apiCode)
    }

    /// A failure class the request itself hit. `network`/`timeout` never reached a verdict — nothing
    /// was refused, so it is `identify_network_error` with no code. A `malformed` answer *did* arrive
    /// but could not be read: a refusal the SDK cannot name, so `identify_rejected` with no code.
    static func classifyNetwork(failureClass: String) -> Outcome {
        switch failureClass {
        case "network", "timeout":
            return Outcome(identifyCode: networkCode, detailsCode: nil)
        default:
            return Outcome(identifyCode: rejectedCode, detailsCode: nil)
        }
    }

    /// The typed error an `Outcome` becomes on the way back to the host.
    static func error(from outcome: Outcome) -> FastoryIdentifyError {
        outcome.identifyCode == networkCode ? .network : .rejected(code: outcome.detailsCode)
    }

    /// A bootstrap failure met while resolving the workspace the exchange needs. It is not a new class
    /// of error to the host: an unreachable API is the same `network` the exchange itself reports, and
    /// a refused key is a refusal carried on `details.code`, exactly like the exchange's own.
    static func error(from bootstrap: FastoryBootstrapError) -> FastoryIdentifyError {
        switch bootstrap {
        case .unreachable:
            return .network
        case .rejected(let code):
            return .rejected(code: code)
        case .malformedResponse:
            return .rejected(code: nil)
        }
    }

    static let rejectedCode = "identify_rejected"
    static let networkCode = "identify_network_error"
}

/// Exchanges a host attestation for a fan session, and mints the single-use token the hub needs to
/// adopt that session. No browser and no form: the partner already authenticated the fan, so the JWT
/// is forwarded for server-side verification (SPEC § 2.6, § 12) and the SDK never validates it.
///
/// Modelled on `FastoryWorkspaceResolver`: one injectable request seam, a 15 s budget shared with the
/// bootstrap exchange, and every completion delivered on the main thread so the caller in `Fastory`
/// need not hop again.
final class FastoryDelegatedSessionClient {
    static let shared = FastoryDelegatedSessionClient()

    /// Seam for unit tests: production performs the real request.
    var performRequest = FastoryDelegatedSessionClient.performLiveRequest

    /// The live request, kept as a static so a suite that stubs `performRequest` can restore it —
    /// the stub is process-wide on the shared client, exactly like the resolver's seam.
    static let performLiveRequest: (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void = {
        request, completion in
        URLSession.shared.dataTask(with: request) { data, response, error in
            completion(data, response, error)
        }.resume()
    }

    /// Restores the live request seam. Called from `Fastory.resetForTesting`.
    func reset() {
        performRequest = Self.performLiveRequest
    }

    /// Exchanges the attestation against `origin` — the origin the returned session is bound to. It is
    /// the games' stories origin, because the games are the surface that reads this token over the
    /// bridge and the embed session provider re-mints anything whose `aud` is not its own. The hub
    /// takes the same session through a server-side handoff instead.
    func exchange(
        jwt: String,
        workspaceId: String,
        origin: String,
        environment: FastoryEnvironment,
        completion: @escaping (Result<FastoryDelegatedSession, FastoryIdentifyError>) -> Void
    ) {
        var request = URLRequest(url: environment.embedTokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = FastoryWorkspaceResolver.exchangeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "workspaceId": workspaceId,
            "token": jwt,
            "origin": origin,
        ])

        performRequest(request) { data, response, error in
            let result = Self.session(from: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Exchanges the system-browser login's single-use code for a fan session (`identify(.fanId)`).
    /// The caller is proven by the publishable key and the application identifier — the pair the code
    /// was minted for — and the PKCE verifier ties the exchange to the app that started the login.
    /// The session comes back bound to the games' stories origin, exactly like the attestation
    /// exchange above; a code replayed, expired or presented by another caller is refused.
    func exchangeLoginCode(
        code: String,
        codeVerifier: String,
        publishableKey: String,
        applicationId: String,
        environment: FastoryEnvironment,
        completion: @escaping (Result<FastoryDelegatedSession, FastoryIdentifyError>) -> Void
    ) {
        var request = URLRequest(url: environment.embedTokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = FastoryWorkspaceResolver.exchangeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": codeVerifier,
            "publishableKey": publishableKey,
            "applicationId": applicationId,
        ])

        performRequest(request) { data, response, error in
            let result = Self.session(from: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Renews the embed session before it expires, without involving the host: the session token is
    /// its own credential, and `origin` must be the one it is bound to (the API refuses a mismatch).
    /// A new token with a fresh TTL comes back. A non-2xx is a refusal — the caller then falls back to
    /// re-exchanging a fresh host assertion through the provider.
    func refresh(
        sessionToken: String,
        origin: String,
        environment: FastoryEnvironment,
        completion: @escaping (Result<String, FastoryIdentifyError>) -> Void
    ) {
        var request = URLRequest(url: environment.embedRefreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = FastoryWorkspaceResolver.exchangeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["origin": origin])

        performRequest(request) { data, response, error in
            let result = Self.refreshed(from: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The `exp` claim of an embed session token, read locally with no signature check. This is the
    /// SDK's *own* token, not the host's assertion: § 12 forbids inspecting the assertion, not reading
    /// when our session lapses. `nil` when the token is not a readable JWT — the caller then treats
    /// the session as already due for renewal rather than trusting an unknown lifetime.
    static func expiry(of token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payload = base64URLDecoded(String(segments[1])),
              let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let exp = json["exp"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func refreshed(
        from data: Data?,
        response: URLResponse?,
        error: Error?
    ) -> Result<String, FastoryIdentifyError> {
        if let error {
            let failureClass = (error as NSError).code == NSURLErrorTimedOut ? "timeout" : "network"
            return .failure(
                FastoryIdentityExchangeClassifier.error(
                    from: FastoryIdentityExchangeClassifier.classifyNetwork(failureClass: failureClass)
                )
            )
        }
        guard let http = response as? HTTPURLResponse, let data else {
            return .failure(.network)
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let apiCode = payload?["code"] as? String
            return .failure(
                FastoryIdentityExchangeClassifier.error(
                    from: FastoryIdentityExchangeClassifier.classify(
                        httpStatus: http.statusCode,
                        apiCode: apiCode
                    )
                )
            )
        }
        guard let token = payload?["token"] as? String, !token.isEmpty else {
            return .failure(
                FastoryIdentityExchangeClassifier.error(
                    from: FastoryIdentityExchangeClassifier.classifyNetwork(failureClass: "malformed")
                )
            )
        }
        return .success(token)
    }

    /// Mints the single-use handoff token the hub loads with (SPEC § 7 handoff). Authenticated by the
    /// embed session itself, so a host that is not identified has nothing to hand off. Failure is not
    /// fatal to the caller: the hub falls back to loading anonymously rather than not opening at all,
    /// which is why this answers `String?` rather than a typed error.
    func mintHandoff(
        sessionToken: String,
        environment: FastoryEnvironment,
        completion: @escaping (String?) -> Void
    ) {
        var request = URLRequest(url: environment.embedHandoffURL)
        request.httpMethod = "POST"
        request.timeoutInterval = FastoryWorkspaceResolver.exchangeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["surface": "hub"])

        performRequest(request) { data, response, _ in
            let token = Self.handoffToken(from: data, response: response)
            DispatchQueue.main.async { completion(token) }
        }
    }

    private static func session(
        from data: Data?,
        response: URLResponse?,
        error: Error?
    ) -> Result<FastoryDelegatedSession, FastoryIdentifyError> {
        if let error {
            let failureClass = (error as NSError).code == NSURLErrorTimedOut ? "timeout" : "network"
            return .failure(
                FastoryIdentityExchangeClassifier.error(
                    from: FastoryIdentityExchangeClassifier.classifyNetwork(failureClass: failureClass)
                )
            )
        }
        guard let http = response as? HTTPURLResponse, let data else {
            return .failure(.network)
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let apiCode = payload?["code"] as? String
            return .failure(
                FastoryIdentityExchangeClassifier.error(
                    from: FastoryIdentityExchangeClassifier.classify(
                        httpStatus: http.statusCode,
                        apiCode: apiCode
                    )
                )
            )
        }
        guard let payload,
              let token = payload["token"] as? String,
              let fanId = fanId(from: payload) else {
            // A 2xx the SDK cannot read is a refusal it cannot name (SPEC § 9.1's reason/code split
            // applied to identity): identify_rejected, never a session built on a guess.
            return .failure(
                FastoryIdentityExchangeClassifier.error(
                    from: FastoryIdentityExchangeClassifier.classifyNetwork(failureClass: "malformed")
                )
            )
        }
        return .success(FastoryDelegatedSession(token: token, fanId: fanId))
    }

    /// `oauthUserId` is a number in the response and a string on the identity surface. Accept either
    /// JSON shape so a serializer that quotes it does not read as a malformed session.
    private static func fanId(from payload: [String: Any]) -> String? {
        if let number = payload["oauthUserId"] as? NSNumber {
            return number.stringValue
        }
        if let string = payload["oauthUserId"] as? String, !string.isEmpty {
            return string
        }
        return nil
    }

    private static func handoffToken(from data: Data?, response: URLResponse?) -> String? {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let data,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = payload["token"] as? String, !token.isEmpty else {
            return nil
        }
        return token
    }
}

extension FastoryEnvironment {
    /// The API host, mirroring the fanzone host per environment. Development points at the
    /// integrator's own base URL, which is where their API lives too — same rule as the bootstrap
    /// exchange, which this shares a base with.
    var apiBaseURL: URL {
        switch self {
        case .production:
            return URL(string: "https://api.fastory.io")!
        case .staging:
            return URL(string: "https://api.staging.fastory.io")!
        case .development(let baseURL):
            return baseURL
        }
    }

    /// Exchanges a host attestation for a fan session (SPEC § 2.6 delegated identity).
    var embedTokenURL: URL {
        apiBaseURL.appendingPathComponent("embed/auth/token")
    }

    /// Mints a single-use session-handoff token for a surface to adopt the session with.
    var embedHandoffURL: URL {
        apiBaseURL.appendingPathComponent("embed/auth/handoff")
    }

    /// Renews an embed session before it expires, returning a token with a fresh TTL.
    var embedRefreshURL: URL {
        apiBaseURL.appendingPathComponent("embed/auth/refresh")
    }
}
