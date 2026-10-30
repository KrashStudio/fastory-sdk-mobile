import AppAuth
import Foundation
import UIKit

/// What the system-browser leg of `identify(.fanId)` needs to start: where to send the fan, which
/// publishable key is asking, and where the browser must hand control back. The token endpoint is
/// carried for the OpenID service configuration even though the SDK performs the code exchange with
/// its own client — the exchange proves the caller with the publishable key and the application
/// identifier, which a generic token request does not carry.
struct FastoryFanLoginRequest: Equatable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let clientId: String
    let redirectURI: URL
}

/// The browser leg's successful outcome: the single-use authorization code and the PKCE verifier
/// that must accompany it on the exchange. The code alone is worthless by design.
struct FastoryFanLoginSuccess: Equatable {
    let code: String
    let codeVerifier: String
}

enum FastoryFanLoginFailure: Error, Equatable {
    /// The fan dismissed the browser sheet or refused to continue — `login_cancelled` (§ 5.4).
    case cancelled
    /// The browser leg could not run or did not complete: no window to present from, a malformed
    /// callback, or a session error. Nothing was refused by the API.
    case failed
}

/// Drives the system-browser login through AppAuth, the platform's reference OpenID client:
/// `ASWebAuthenticationSession` under the hood, with the state parameter and PKCE generated and
/// validated by the library rather than by hand (§ 2.6). No credential ever transits a WebView.
final class FastoryFanLoginController {
    static let shared = FastoryFanLoginController()

    /// Seam for unit tests: production presents the real browser session.
    var performLogin: (
        FastoryFanLoginRequest,
        @escaping (Result<FastoryFanLoginSuccess, FastoryFanLoginFailure>) -> Void
    ) -> Void = FastoryFanLoginController.performLiveLogin

    /// Where the browser sheet is anchored. Derived rather than taken as a parameter because
    /// `identify` is callable from any thread and carries no UI object by contract (§ 2.6, § 2.7).
    var presentationAnchor: () -> UIViewController? = FastoryFanLoginController.topViewController

    /// The in-flight AppAuth session. Retained on purpose: dropping it dismisses the browser.
    private var currentSession: OIDExternalUserAgentSession?

    /// Restores the live seams and abandons any in-flight browser session.
    func reset() {
        performLogin = Self.performLiveLogin
        presentationAnchor = Self.topViewController
        currentSession?.cancel()
        currentSession = nil
    }

    /// Cancels a login still in the browser. `logout()` calls it so a sign-out wins over a login in
    /// flight: cancelling the session drives its completion to `.cancelled`, so the pending
    /// `identify(.fanId)` lands anonymous rather than re-identifying the fan just signed out.
    func cancelInFlight() {
        currentSession?.cancel()
        currentSession = nil
    }

    static let performLiveLogin: (
        FastoryFanLoginRequest,
        @escaping (Result<FastoryFanLoginSuccess, FastoryFanLoginFailure>) -> Void
    ) -> Void = { request, completion in
        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: request.authorizationEndpoint,
            tokenEndpoint: request.tokenEndpoint
        )
        // This initializer generates the state and the S256 PKCE pair — the parts one never writes
        // by hand. AppAuth validates the returned state before handing the response back.
        let authorizationRequest = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: request.clientId,
            scopes: nil,
            redirectURL: request.redirectURI,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil
        )
        guard let presenter = shared.presentationAnchor() else {
            completion(.failure(.failed))
            return
        }
        // A second identify(.fanId) while one is still in the browser supersedes it: cancel the
        // previous session before presenting, or its sheet is orphaned when its reference is dropped.
        shared.currentSession?.cancel()
        shared.currentSession = OIDAuthorizationService.present(
            authorizationRequest,
            presenting: presenter
        ) { response, error in
            shared.currentSession = nil
            if let code = response?.authorizationCode,
               let verifier = authorizationRequest.codeVerifier {
                completion(.success(FastoryFanLoginSuccess(code: code, codeVerifier: verifier)))
                return
            }
            completion(.failure(isCancellation(error) ? .cancelled : .failed))
        }
    }

    /// A dismissal is a decision, not a failure: it maps to `login_cancelled` so a host can tell a
    /// fan who changed their mind from a flow that broke.
    private static func isCancellation(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == OIDGeneralErrorDomain
            && (error.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue
                || error.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue)
    }

    /// The topmost view controller of the key window — the only anchor available to a method whose
    /// frozen signature takes no UI object. A host with no window on screen gets `.failed`, never a
    /// crash.
    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard var top = keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
