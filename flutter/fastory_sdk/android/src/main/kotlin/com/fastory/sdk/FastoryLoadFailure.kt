package com.fastory.sdk

import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient

/** Which Fastory surface a load failure is about (SPEC § 9.1). */
enum class FastorySurface(val wireName: String) {
    HUB("hub"),
    GAME("game"),
}

/**
 * How a surface failed to load, as a host branches on it (SPEC § 9.1).
 *
 * Three cases rather than one per cause: the cause itself is in [FastoryLoadFailure.code] and
 * [FastoryLoadFailure.statusCode], and a host that only needs "was anything reachable at all" must
 * not have to enumerate every future API code to answer it.
 */
enum class FastoryLoadFailureReason(val wireName: String) {
    /**
     * Something answered and refused. `code` carries the API's machine-readable failure code when
     * the refusal came from the publishable-key exchange (§ 2.5); `statusCode` carries the HTTP
     * status when it came from the surface's own main document (§ 9).
     */
    REJECTED("rejected"),

    /** Nothing answered — no connection, DNS failure, timeout. Both `code` and `statusCode` null. */
    NETWORK("network"),

    /**
     * Something happened that the SDK cannot classify as either of the two above: a bootstrap
     * response in a shape it cannot read, or a platform error outside the transport family. The
     * escape hatch that keeps the other two cases meaning exactly what they say.
     */
    UNKNOWN("unknown"),
}

/**
 * A Fastory surface that did not load, reported to the host (SPEC § 9.1).
 *
 * [code] is the API's machine-readable failure code (`sdk_key_revoked`,
 * `sdk_application_not_allowed`, …), non-null only when the publishable-key exchange refused the
 * configuration (§ 2.5). [statusCode] is the HTTP status the surface's main document answered,
 * non-null only when one did (§ 9).
 */
data class FastoryLoadFailure(
    val surface: FastorySurface,
    val reason: FastoryLoadFailureReason,
    val code: String? = null,
    val statusCode: Int? = null,
)

/**
 * Why a publishable-key exchange did not resolve, carrying the resolver's own [code] (§ 2.5).
 *
 * Typed rather than an `IllegalStateException` whose message happens to be the code: the code is
 * what § 2.5 requires a host to branch on, so reading it back out of a message would make the one
 * value that matters the one nothing guarantees.
 */
internal class FastoryBootstrapException(val code: String) : Exception(code)

/**
 * Turns each platform's own failure vocabulary into the one the host reads (SPEC § 9.1).
 *
 * Pure, and mirrored case for case on iOS: both platforms run one shared truth table, so a
 * divergence fails a suite instead of surfacing as one platform reporting `network` where the other
 * reports `unknown`.
 */
internal object FastoryLoadFailureClassifier {

    /**
     * Codes [WorkspaceResolver] mints itself for outcomes the API never answers. They are internal
     * markers, not API codes — they name the *shape* of a non-answer — so they become a reason and
     * are never handed to a host as a code to branch on.
     */
    internal const val UNREACHABLE_CODE = "sdk_unreachable"
    internal const val MALFORMED_RESPONSE_CODE = "sdk_malformed_response"

    /**
     * Transport failures: nothing answered. Enumerated rather than "every error code", which also
     * carries refusals that did get an answer (an unsupported scheme, a blocked resource) — iOS
     * draws the same line, and a shared truth table keeps the two lists from drifting apart.
     */
    private val NETWORK_ERROR_CODES = setOf(
        WebViewClient.ERROR_HOST_LOOKUP,
        WebViewClient.ERROR_CONNECT,
        WebViewClient.ERROR_IO,
        WebViewClient.ERROR_TIMEOUT,
        WebViewClient.ERROR_FAILED_SSL_HANDSHAKE,
    )

    /** A publishable-key exchange that did not resolve (§ 2.5). */
    internal fun bootstrap(code: String): Pair<FastoryLoadFailureReason, String?> = when (code) {
        UNREACHABLE_CODE -> FastoryLoadFailureReason.NETWORK to null
        MALFORMED_RESPONSE_CODE -> FastoryLoadFailureReason.UNKNOWN to null
        else -> FastoryLoadFailureReason.REJECTED to code
    }

    /** A `WebViewClient.onReceivedError` code on the main document (§ 9). */
    internal fun navigation(errorCode: Int): FastoryLoadFailureReason =
        if (errorCode in NETWORK_ERROR_CODES) {
            FastoryLoadFailureReason.NETWORK
        } else {
            FastoryLoadFailureReason.UNKNOWN
        }
}

/**
 * Watches a warm-up load so a page that failed never reaches the warm slot (SPEC § 9.1).
 *
 * The warm-up runs with no screen and no fan in front of it, so its failure is not something to
 * report — the presentation that follows loads cold and reports for itself. Keeping the page,
 * though, is worse than useless: an error **body** commits like any other document, so the slot ends
 * up holding the web's own "fanzone introuvable" page, and the next presentation reads a committed
 * page as a loaded hub and announces `hubOpened` on it. Observed on a simulator, not reasoned: the
 * placeholder slug answers 404 and rendered exactly that.
 *
 * Named rather than anonymous so a suite can drive it without a live warm-up, which needs a real
 * network load the runner cannot complete.
 */
internal class FastoryWarmUpClient : WebViewClient() {
    override fun onPageFinished(view: WebView, url: String?) {
        // Discovery still runs on a successful warm-up: the games are what the fan taps first.
        GamePreloader.onHubLoadFinished(view)
    }

    override fun onReceivedError(
        view: WebView,
        request: WebResourceRequest,
        error: WebResourceError,
    ) {
        if (request.isForMainFrame) Fastory.discardWarmHubLater(view)
    }

    override fun onReceivedHttpError(
        view: WebView,
        request: WebResourceRequest,
        errorResponse: WebResourceResponse,
    ) {
        if (request.isForMainFrame) Fastory.discardWarmHubLater(view)
    }
}

/**
 * The load state of one Fastory surface, as the host sees it (SPEC § 5.3, § 9.1).
 *
 * Pure — no WebView and no Activity — so the rule both surfaces obey is written once and assertable
 * without either: **an opening event never fires on a surface that has not loaded**, and a surface
 * that never opened owes no closing event.
 *
 * [hasCommitted] starts true for a page whose document committed before this surface existed: no
 * further commit callback is coming for it, so a gate that waited for one would never announce the
 * opening at all. [isIdentified] is false only for the hub, whose event carries a fanzone slug the
 * publishable-key path learns from the API (§ 2.5).
 */
internal class FastorySurfaceLoad(
    private val surface: FastorySurface,
    private var isIdentified: Boolean = true,
    private var hasCommitted: Boolean = false,
) {
    internal sealed interface Announcement {
        object Nothing : Announcement
        object Opened : Announcement
        data class Failed(val failure: FastoryLoadFailure) : Announcement
    }

    private var isPresented = false
    private var hasFailed = false
    private var didOpen = false

    /** Whether the opening event has been announced — and therefore whether a closing one is owed. */
    internal val isOpen: Boolean get() = didOpen

    /** The container reached the screen. */
    internal fun present(): Announcement {
        isPresented = true
        return settle()
    }

    /** What the surface will announce itself as is now known: the hub's resolved fanzone slug. */
    internal fun identify(): Announcement {
        isIdentified = true
        return settle()
    }

    /** The main document was accepted for display. */
    internal fun commit(): Announcement {
        hasCommitted = true
        return settle()
    }

    /**
     * Reported once per load attempt: a single failure reaches the SDK through several callbacks,
     * and a host counting failures would otherwise count one page twice.
     */
    internal fun fail(
        reason: FastoryLoadFailureReason,
        code: String? = null,
        statusCode: Int? = null,
    ): Announcement {
        if (hasFailed) return Announcement.Nothing
        hasFailed = true
        return Announcement.Failed(FastoryLoadFailure(surface, reason, code, statusCode))
    }

    /**
     * A retry, or an in-place navigation to another document: the surface may load — and open —
     * again. What it does not clear is [didOpen]: a hub that opened, then navigated to a page that
     * 404s, has not opened twice.
     */
    internal fun restart() {
        hasFailed = false
        hasCommitted = false
    }

    /**
     * The container left the screen. True when a closing event is owed, which it is only if the
     * surface ever announced itself open.
     */
    internal fun dismiss(): Boolean {
        val owed = didOpen
        didOpen = false
        return owed
    }

    private fun settle(): Announcement {
        if (didOpen || hasFailed || !isPresented || !isIdentified || !hasCommitted) {
            return Announcement.Nothing
        }
        didOpen = true
        return Announcement.Opened
    }
}
