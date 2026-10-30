import Foundation
import WebKit

/// The session-change signal (SPEC § 13.9, since 0.5.0).
///
/// When the standing bridge answer transitions — renewal, revocation, populate, logout, host
/// set/clear — the SDK evaluates `statement` in every game WebView it owns (presented sheet +
/// preloaded pages, never the hub). The page re-asks `fastory:user-token` and adopts the answer.
///
/// The type keeps two responsibilities that a game page cannot tell apart: `emitsSignal(trigger:)`
/// is the pure decision — a trigger name maps to whether the signal fires, no I/O, no WebView — and
/// `broadcast()` performs the one evaluation § 12.1's second exception licenses, on the live game
/// surfaces only. The evaluation is the whole of what the SDK ever runs at its own initiative, and
/// `statement` is a byte-for-byte constant so nothing the SDK holds can travel by it.
enum FastorySessionPush {

    /// The exact statement § 13.9.1 fixes — constant, no payload, no interpolation.
    static let statement = "window.dispatchEvent(new Event('fastory:session-changed'))"

    /// The event name the statement dispatches (§ 13.9.1).
    static let sessionChangedEvent = "fastory:session-changed"

    /// The presented game sheet's WebView, held weakly so a dismissed sheet leaves no reference.
    /// A preloaded page is reached through the preloader instead (§ 13.9.3).
    static weak var presentedGameWebView: WKWebView?

    /// Returns whether the signal fires for `trigger` (§ 13.9.2). The firing set is every transition
    /// that changes the standing answer's value for a page; the rest re-assert what already stands.
    static func emitsSignal(trigger: String) -> Bool {
        switch trigger {
        case "session_renewed", "session_revoked", "logout",
             "identify_different_fan", "host_set", "host_clear":
            return true
        case "identify_same_fan", "configure_replace", "identify_preflight_rejected":
            return false
        default:
            return false
        }
    }

    /// Dispatches the signal into every live game surface: the presented sheet and each preloaded
    /// page (§ 13.9.3), never the hub. Best-effort (§ 13.9.4): each evaluation is fire-and-forget on
    /// the main thread, a failure is traced and the page left alone — no retry, nothing blocks.
    static func broadcast() {
        let evaluate: () -> Void = {
            var seen = Set<ObjectIdentifier>()
            var targets: [WKWebView] = []
            for webView in [presentedGameWebView].compactMap({ $0 })
                + FastoryGamePreloader.shared.liveGameWebViews
                where seen.insert(ObjectIdentifier(webView)).inserted {
                targets.append(webView)
            }
            for webView in targets {
                webView.evaluateJavaScript(statement) { _, error in
                    if let error {
                        FastoryBridgeLog.signalUndelivered("\(error)")
                    }
                }
            }
        }
        if Thread.isMainThread {
            evaluate()
        } else {
            DispatchQueue.main.async(execute: evaluate)
        }
    }
}
