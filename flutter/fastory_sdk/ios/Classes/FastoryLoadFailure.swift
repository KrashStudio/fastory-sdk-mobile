import Foundation
import WebKit

/// Which Fastory surface a load failure is about (SPEC § 9.1).
public enum FastorySurface: String, Equatable, Sendable {
    case hub
    case game
}

/// How a surface failed to load, as a host branches on it (SPEC § 9.1).
///
/// Three cases rather than one per cause: the cause itself is in `code` and `statusCode`, and a
/// host that only needs "was anything reachable at all" must not have to enumerate every future
/// API code to answer it.
public enum FastoryLoadFailureReason: String, Equatable, Sendable {
    /// Something answered and refused. `code` carries the API's machine-readable failure code when
    /// the refusal came from the publishable-key exchange (§ 2.5); `statusCode` carries the HTTP
    /// status when it came from the surface's own main document (§ 9).
    case rejected
    /// Nothing answered — no connection, DNS failure, timeout. Both `code` and `statusCode` are nil.
    case network
    /// Something happened that the SDK cannot classify as either of the two above: a bootstrap
    /// response in a shape it cannot read, or a platform error outside the transport family. The
    /// escape hatch that keeps the other two cases meaning exactly what they say.
    case unknown
}

/// A Fastory surface that did not load, reported to the host (SPEC § 9.1).
public struct FastoryLoadFailure: Equatable, Sendable {
    public let surface: FastorySurface
    public let reason: FastoryLoadFailureReason
    /// The API's machine-readable failure code (`sdk_key_revoked`, `sdk_application_not_allowed`, …),
    /// non-nil only when the publishable-key exchange refused the configuration (§ 2.5).
    public let code: String?
    /// The HTTP status the surface's main document answered, non-nil only when one did (§ 9).
    public let statusCode: Int?

    public init(
        surface: FastorySurface,
        reason: FastoryLoadFailureReason,
        code: String? = nil,
        statusCode: Int? = nil
    ) {
        self.surface = surface
        self.reason = reason
        self.code = code
        self.statusCode = statusCode
    }
}

/// Turns each platform's own failure vocabulary into the one the host reads (SPEC § 9.1).
///
/// Pure, and mirrored case for case on Android: both platforms run one shared truth table, so a
/// divergence fails a suite instead of surfacing as one platform reporting `network` where the other
/// reports `unknown`.
enum FastoryLoadFailureClassifier {
    /// Codes the resolvers mint themselves for outcomes the API never answers. They are internal
    /// markers, not API codes — they name the *shape* of a non-answer — so they become a reason and
    /// are never handed to a host as a code to branch on.
    static let unreachableCode = "sdk_unreachable"
    static let malformedResponseCode = "sdk_malformed_response"

    /// A publishable-key exchange that did not resolve (§ 2.5).
    static func bootstrap(code: String) -> (reason: FastoryLoadFailureReason, code: String?) {
        switch code {
        case unreachableCode:
            return (.network, nil)
        case malformedResponseCode:
            return (.unknown, nil)
        default:
            return (.rejected, code)
        }
    }

    /// Transport failures: nothing answered. Enumerated rather than taken as the whole of
    /// `NSURLErrorDomain`, which also carries refusals that did get an answer — Android's error set
    /// draws the same line, and a shared truth table keeps the two lists from drifting apart.
    private static let networkErrorCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorSecureConnectionFailed
    ]

    /// A WebKit navigation error. `nil` when it is benign — a navigation the SDK's own URL policy
    /// cancelled travels through the same callbacks and is not a load failure (§ 9).
    static func navigation(_ error: Error) -> FastoryLoadFailureReason? {
        guard !NavigationErrorClassifier.isBenign(error) else { return nil }
        let nsError = error as NSError
        let isNetwork = nsError.domain == NSURLErrorDomain
            && networkErrorCodes.contains(nsError.code)
        return isNetwork ? .network : .unknown
    }
}

/// Watches a warm-up load so a page that failed never reaches the warm slot (SPEC § 9.1).
///
/// The warm-up runs with no view and no fan in front of it, so its failure is not something to
/// report — the presentation that follows loads cold and reports for itself. Keeping the page,
/// though, is worse than useless: an error **body** commits like any other document, so the slot
/// ends up holding the web's own "fanzone introuvable" page, and the next presentation reads a
/// committed page as a loaded hub and announces `hubOpened` on it. Observed on a simulator, not
/// reasoned: the placeholder slug answers 404 and rendered exactly that.
final class FastoryWarmUpObserver: NSObject, WKNavigationDelegate {
    /// The only place the warm-up's commit can be seen. `WKWebView.url` cannot answer it: it is the
    /// active URL, set the instant `load()` is called.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Fastory.warmHubPageDidCommit()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse,
              response.statusCode >= 400 else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        discard(webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard !NavigationErrorClassifier.isBenign(error) else { return }
        discard(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !NavigationErrorClassifier.isBenign(error) else { return }
        discard(webView)
    }

    /// Where the deferred discard is handed off. A seam, and the deferral is the whole point of it:
    /// production must not release a WebView from inside that WebView's own delegate callback, and a
    /// suite must be able to observe that the discard was *scheduled* — then run it — instead of
    /// waiting a wall-clock delay for a main-queue turn it does not control.
    static var scheduleDiscard: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.async(execute: work)
    }

    /// A turn later, so the WebView is not released from inside its own delegate callback — and only
    /// if the slot still holds it, since a presentation that took it inside that turn owns it now and
    /// discarding would flush the games discovered for the hub that is opening.
    private func discard(_ webView: WKWebView) {
        Self.scheduleDiscard { Fastory.discardWarmHub(ifStillHolding: webView) }
    }
}

/// The load state of one Fastory surface, as the host sees it (SPEC § 5.3, § 9.1).
///
/// Pure — no WebView and no view controller — so the rule both surfaces obey is written once and
/// assertable without either: **an opening event never fires on a surface that has not loaded**, and
/// a surface that never opened owes no closing event.
struct FastorySurfaceLoad {
    enum Announcement: Equatable {
        case nothing
        case opened
        case failed(FastoryLoadFailure)
    }

    private let surface: FastorySurface
    private var isPresented = false
    private var isIdentified: Bool
    private var hasCommitted: Bool
    private var hasFailed = false
    private var didOpen = false

    /// `hasCommitted` starts true for a page whose document committed before this surface existed:
    /// no further commit callback is coming for it, so a gate that waited for one would never
    /// announce the opening at all. `isIdentified` is false only for the hub, whose event carries a
    /// fanzone slug the publishable-key path learns from the API (§ 2.5).
    init(surface: FastorySurface, isIdentified: Bool = true, hasCommitted: Bool = false) {
        self.surface = surface
        self.isIdentified = isIdentified
        self.hasCommitted = hasCommitted
    }

    /// Whether the opening event has been announced — and therefore whether a closing one is owed.
    var isOpen: Bool { didOpen }

    /// Whether the surface's document has committed. Read when a page goes back into the warm slot:
    /// the next presentation cannot work it out from the WebView.
    var hasCommittedPage: Bool { hasCommitted }

    /// The container reached the screen.
    mutating func present() -> Announcement {
        isPresented = true
        return settle()
    }

    /// What the surface will announce itself as is now known: the hub's resolved fanzone slug.
    mutating func identify() -> Announcement {
        isIdentified = true
        return settle()
    }

    /// The main document was accepted for display.
    mutating func commit() -> Announcement {
        hasCommitted = true
        return settle()
    }

    /// Reported once per load attempt: a single failure reaches the SDK through several callbacks
    /// (a cancelled response, then the cancellation itself), and a host counting failures would
    /// otherwise count one page twice.
    mutating func fail(
        reason: FastoryLoadFailureReason,
        code: String? = nil,
        statusCode: Int? = nil
    ) -> Announcement {
        guard !hasFailed else { return .nothing }
        hasFailed = true
        return .failed(
            FastoryLoadFailure(surface: surface, reason: reason, code: code, statusCode: statusCode)
        )
    }

    /// A retry, or an in-place navigation to another document: the surface may load — and open —
    /// again. What it does not clear is `didOpen`: a hub that opened, then navigated to a page that
    /// 404s, has not opened twice.
    mutating func restart() {
        hasFailed = false
        hasCommitted = false
    }

    /// The container left the screen. True when a closing event is owed, which it is only if the
    /// surface ever announced itself open.
    mutating func dismiss() -> Bool {
        defer { didOpen = false }
        return didOpen
    }

    private mutating func settle() -> Announcement {
        guard !didOpen, !hasFailed, isPresented, isIdentified, hasCommitted else { return .nothing }
        didOpen = true
        return .opened
    }
}
