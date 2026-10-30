package com.fastory.sdk

import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import java.lang.ref.WeakReference

/**
 * The session-change signal (SPEC § 13.9, since 0.5.0).
 *
 * When the standing bridge answer transitions — renewal, revocation, populate, logout, host
 * set/clear — the SDK evaluates [STATEMENT] in every game WebView it owns (presented sheet +
 * preloaded pages, never the hub). The page re-asks `fastory:user-token` and adopts the answer.
 *
 * The object keeps two responsibilities a game page cannot tell apart: [emitsSignal] is the pure
 * decision — a trigger name maps to whether the signal fires, with no I/O and no WebView — and
 * [broadcast] performs the one evaluation § 12.1's second exception licenses, on the live game
 * surfaces only. The evaluation is the whole of what the SDK ever runs at its own initiative, and
 * [STATEMENT] is a byte-for-byte constant so nothing the SDK holds can travel by it.
 */
internal object FastorySessionPush {

    /** The exact statement § 13.9.1 fixes — constant, no payload, no interpolation. */
    const val STATEMENT = "window.dispatchEvent(new Event('fastory:session-changed'))"

    /** The event name the statement dispatches (§ 13.9.1). */
    const val SESSION_CHANGED_EVENT = "fastory:session-changed"

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * The presented game sheet's WebView, held weakly so a dismissed sheet leaves no reference.
     * A preloaded page is reached through the preloader instead (§ 13.9.3).
     */
    private var presentedGameWebView: WeakReference<WebView>? = null

    fun setPresentedGameWebView(webView: WebView?) {
        presentedGameWebView = webView?.let { WeakReference(it) }
    }

    /**
     * Returns whether the signal fires for [trigger] (§ 13.9.2). The firing set is every transition
     * that changes the standing answer's value for a page; the rest re-assert what already stands.
     */
    fun emitsSignal(trigger: String): Boolean = when (trigger) {
        "session_renewed", "session_revoked", "logout",
        "identify_different_fan", "host_set", "host_clear" -> true
        "identify_same_fan", "configure_replace", "identify_preflight_rejected" -> false
        else -> false
    }

    /**
     * Dispatches the signal into every live game surface: the presented sheet and each preloaded
     * page (§ 13.9.3), never the hub. Best-effort (§ 13.9.4): each evaluation is fire-and-forget on
     * the main thread, a failure the WebView reports is traced and the page left alone — no retry,
     * nothing blocks.
     */
    fun broadcast() {
        val work = Runnable {
            val targets = LinkedHashSet<WebView>()
            presentedGameWebView?.get()?.let { targets.add(it) }
            targets.addAll(GamePreloader.liveGameWebViews())
            for (webView in targets) {
                webView.evaluateJavascript(STATEMENT) { /* best-effort: nothing to read back */ }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            work.run()
        } else {
            mainHandler.post(work)
        }
    }
}
