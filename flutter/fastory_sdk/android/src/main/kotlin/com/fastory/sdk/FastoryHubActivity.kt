package com.fastory.sdk

import android.annotation.SuppressLint
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.AccessibilityDelegateCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.core.view.isVisible
import androidx.fragment.app.DialogFragment
import com.fastory.sdk.flutter.R

/**
 * The SDK's full-screen container, for either of the surfaces it presents: the games hub, and the
 * workspace's membership panel (SPEC § 3.2, § 3.5).
 *
 * One container rather than two, because everything around the page is the same — the close control,
 * the loading and error views, the four URL policy rules, the back behaviour of § 6. What the
 * surface decides is the address that is loaded, the warm slot the page is read from and put back
 * into, and which pair of events is announced.
 */
class FastoryHubActivity : AppCompatActivity() {

    /**
     * The configuration this presentation was built under — stamped on the page it puts back, so a
     * re-configure while it was on screen cannot bless a stale page. Internal rather than private so
     * a presentation's exits can be driven without its views having been built.
     */
    internal lateinit var config: FastoryConfig
    private lateinit var root: FrameLayout

    /** Internal rather than private so a presentation can be driven without its views having been built. */
    internal lateinit var webView: WebView
    private lateinit var coverView: View
    private lateinit var progressBar: ProgressBar
    private lateinit var errorView: LinearLayout
    private lateinit var closeButton: TextView
    private lateinit var retryWait: FastoryErrorView.RetryWait

    /**
     * The one gate on `hubOpened` and `hubClosed`, shared with the game sheet (SPEC § 9.1). Built in
     * [buildViews], once the WebView is known: a page the warm-up already loaded starts committed,
     * since no further commit callback is coming for it. Internal rather than private so the gate
     * can be driven without the views having been built.
     */
    internal lateinit var load: FastorySurfaceLoad

    /**
     * Which surface this container stands on, read from the Intent that started it. Internal rather
     * than private so a panel's exits can be driven without its views having been built.
     */
    internal var surface: FastorySurface = FastorySurface.HUB

    /**
     * The fanzone `hubOpened` names, known up front on the slug path and from the API on the key one.
     * Null on the panel, which announces itself with no identifier of its own.
     */
    internal var resolvedFanzoneSlug: String? = null

    /**
     * The page the warm slot handed over, and the address it carries. Kept rather than settled in
     * [buildViews]: whether that page is the document this container is asking for cannot be known
     * before the address is resolved. Internal rather than private so the resolution can be driven
     * without the views having been built.
     */
    internal lateinit var warmPage: Fastory.WarmSurfacePage

    /**
     * The address this presentation asked for, known once the resolution answers. It is what goes
     * back into the warm slot on the way out — never [WebView.getUrl], which is wherever the fan's
     * own navigation left the page, and which the next opening would never recognise.
     */
    private var requestedUrl: String? = null

    /**
     * The latest resolution has answered. Not [requestedUrl], which a reload after an identity change
     * keeps from the previous resolution while the new one is still minting its handoff: until this
     * one answers, what commits or finishes in the page is the outgoing document.
     */
    private var addressSettled = false

    private var hasStartedLoad = false

    /**
     * Counts the resolutions this container started, so only the latest one loads its answer. A
     * reload after an identity change can start while an earlier resolution is still minting a
     * handoff for the previous fan; landing after it, that answer would put the previous fan back.
     */
    private var resolutionCount = 0

    /**
     * The address this presentation loaded into a page that may still carry an earlier
     * presentation's history, which back would otherwise walk into (SPEC § 6); null once spent.
     * `clearHistory` keeps only the current entry, so it waits for the history update whose current
     * entry was asked for at this address — called with the load, it keeps the outgoing document,
     * and spent on any update, it can land on the outgoing document's own `replaceState`. Compared
     * with the entry's original URL, which a server redirect does not change. Spent once, so the
     * page's own navigation after that stays within reach of back.
     */
    private var clearsHistoryOnCommitOf: String? = null

    /**
     * The page is hiding what an earlier presentation left on it (SPEC § 9): from the start of an
     * opening on a page that already carries a document until that page is reused as it stands, a
     * document loaded in its place can be shown, or the load fails. Internal rather than private so
     * it can be read without the views having been built.
     */
    internal var coversOutgoingDocument = false
        private set

    /**
     * Bumped each time the cover goes up or down, so a paint wait started for one cover can neither
     * lift the one that replaced it nor touch a page already handed on. Internal rather than private
     * so a wait can be answered without the page.
     */
    internal var coverGeneration = 0
        private set

    private var awaitsFirstPaint = false

    /** The paint wait's main-thread timers: a probe every [FIRST_PAINT_POLL_MS], a deadline. */
    private val paintWait = Handler(Looper.getMainLooper())

    /**
     * The launch this container answers for, handed out by [Fastory.claimHubPresentation] — or
     * carried in the saved state of the instance it replaces, for one the platform rebuilt: null
     * until then, then fixed for the Activity's life — its destruction still needs it once the
     * presentation has ended, to tell a page worth keeping warm from one that is out of date.
     */
    private var launch: Int? = null

    private var presentationEnded = false

    /**
     * This instance is the platform's rebuild of a surface whose opening event the host has already
     * heard. The page announces itself again as it settles here, and that second opening is not
     * passed on; the closing it owes is.
     */
    private var openedBeforeRecreation = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Before anything is built, so a hub the host already asked to close never renders: the
        // reservation openGames() made is claimed here, or refused because close() got in first.
        if (!claimPresentation(savedInstanceState)) {
            finish()
            return
        }
        val currentConfig = Fastory.config
        if (currentConfig == null) {
            finish()
            return
        }
        config = currentConfig
        surface = surfaceFromIntent()

        buildViews()
        setContentView(root)
        applyWindowInsets()
        configureCookies()
        configureWebView()

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    handleBack()
                }
            },
        )

        // The Activity is on screen the moment it is created; whether the hub is *open* is the
        // page's business, not the container's (SPEC § 9.1).
        announce(load.present())
        openSurface(mayReusePrewarmedPage = true)
    }

    /** The hub by default: it is the surface every host on the 0.x line opens. */
    private fun surfaceFromIntent(): FastorySurface {
        val wireName = intent?.getStringExtra(EXTRA_SURFACE) ?: return FastorySurface.HUB
        return FastorySurface.values().firstOrNull { it.wireName == wireName }
            ?: FastorySurface.HUB
    }

    /**
     * The page's history has changed — the first time after [openSurface] loaded a document, that
     * is the document committing. Internal rather than private so it can be driven without the
     * views having been built.
     */
    internal fun onVisitedHistoryUpdated() {
        val address = clearsHistoryOnCommitOf ?: return
        if (webView.copyBackForwardList().currentItem?.originalUrl != address) return
        clearsHistoryOnCommitOf = null
        webView.clearHistory()
    }

    /**
     * The page's document can be shown. Before this presentation knows its address, though, the
     * document is the outgoing one finishing a load of its own, and the cover stays. Shown is not
     * drawn either: the browser keeps the previous page's last frame on screen until the new one
     * paints content. So the cover waits for that first contentful paint, asking the page whether its
     * Paint Timing holds the entry — a read-only constant, the bounded exception of SPEC § 12.1 —
     * and goes when it does, or at a native deadline of [FIRST_PAINT_WAIT_MS] whatever the page
     * answers. Internal rather than private so it can be driven without the views having been built.
     */
    internal fun onDocumentShown() {
        if (!addressSettled || !coversOutgoingDocument || awaitsFirstPaint) return
        awaitsFirstPaint = true
        val generation = coverGeneration
        paintWait.postDelayed({ liftCoverOnceDrawn(generation) }, FIRST_PAINT_WAIT_MS)
        probeFirstPaint(generation)
    }

    private fun probeFirstPaint(generation: Int) {
        webView.evaluateJavascript(FIRST_CONTENTFUL_PAINT_PROBE) { painted ->
            onFirstPaintProbed(generation, painted == "true")
        }
    }

    /** Internal rather than private so a probe can be answered without the page. */
    internal fun onFirstPaintProbed(generation: Int, painted: Boolean) {
        if (generation != coverGeneration || !awaitsFirstPaint) return
        if (painted) {
            liftCoverOnceDrawn(generation)
        } else {
            paintWait.postDelayed({
                if (generation == coverGeneration) probeFirstPaint(generation)
            }, FIRST_PAINT_POLL_MS)
        }
    }

    /**
     * The new document is on screen, or the deadline passed: the cover goes, and only then is the
     * wait a Retry announced over — announced earlier, it would send a screen reader to a page
     * still hidden from it.
     */
    private fun liftCoverOnceDrawn(generation: Int) {
        if (generation != coverGeneration || !awaitsFirstPaint) return
        liftCover()
        if (::retryWait.isInitialized) retryWait.succeed()
    }

    /**
     * A main-frame load finished. An outgoing load this presentation's own interrupted reports here
     * too, as an aborted main frame, so until the document asked for has committed a finish is not
     * its: it neither shows the page nor counts as its commit — counted, the page would go back to
     * the warm slot as committed and the next opening would present it before it is. Internal
     * rather than private so it can be driven without the views having been built.
     */
    internal fun onLoadFinished() {
        if (clearsHistoryOnCommitOf != null) return
        onDocumentShown()
        announce(load.commit())
    }

    /** Internal rather than private so it can be driven without the views having been built. */
    internal fun liftCover() = setCover(false)

    private fun setCover(covered: Boolean) {
        coverGeneration++
        awaitsFirstPaint = false
        paintWait.removeCallbacksAndMessages(null)
        coversOutgoingDocument = covered
        // Covered, the outgoing screen is still in the page, and a screen reader would read it.
        webView.importantForAccessibility = if (covered) {
            View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        } else {
            View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        }
        if (::coverView.isInitialized) coverView.isVisible = covered
        // A cover with nothing moving over it reads as a blank screen while it waits: the bar stays
        // over it, even past a progress of 100, until it goes.
        if (::progressBar.isInitialized) {
            if (covered) {
                progressBar.isIndeterminate = true
                progressBar.isVisible = true
            } else if (webView.progress >= 100) {
                progressBar.isVisible = false
            }
        }
    }

    /**
     * Configured by publishable key, the address is resolved from the API — the progress bar covers
     * that round trip, and a rejected key lands on the same native error view as a failed page load
     * rather than on a blank webview.
     *
     * [mayReusePrewarmedPage] is this presentation's own first attempt, the only one a page prepared
     * ahead of it can stand in for — Retry is asking for a document again and always loads one.
     *
     * Internal rather than private so the resolution can be driven without the views having been
     * built.
     */
    internal fun openSurface(mayReusePrewarmedPage: Boolean = false) {
        // Before resolving rather than with the load: an identified hub learns its address over a
        // round trip, and the page would show the previous opening for all of it. Only over a
        // document the page committed: one still on its first load shows nothing yet.
        if (webView.copyBackForwardList().currentItem != null) setCover(true)
        addressSettled = false
        val resolution = ++resolutionCount
        resolveSurface { result ->
            if (resolution != resolutionCount) return@resolveSurface
            result.fold(
                onSuccess = { (url, fanzoneSlug) ->
                    resolvedFanzoneSlug = fanzoneSlug
                    requestedUrl = url
                    addressSettled = true
                    if (!(mayReusePrewarmedPage && warmPage.isReusableFor(url))) {
                        // The page in hand is another document, so what it already committed must
                        // not announce this presentation open before the new one arrives (§ 9.1) —
                        // which is why this runs before identify(): settling on the resolved
                        // address must never read the outgoing document's own commit.
                        load.restart()
                        clearsHistoryOnCommitOf = url
                        webView.loadUrl(url)
                    } else if (load.hasCommittedPage) {
                        // Reused as it stands. One reused while it still loads over an earlier
                        // document stays covered: until it commits, that document is what it draws.
                        liftCover()
                        if (::progressBar.isInitialized) {
                            progressBar.isIndeterminate = webView.progress == 0
                            progressBar.isVisible = webView.progress < 100
                        }
                    }
                    announce(load.identify())
                    hasStartedLoad = true
                },
                onFailure = { error ->
                    // The exchange's own code is what § 2.5 requires a host to branch on, and it was
                    // reaching neither the host nor the screen: a revoked key, an application the
                    // workspace never declared and a phone in a tunnel all produced this one view.
                    val code = (error as? FastoryBootstrapException)?.code
                        ?: FastoryLoadFailureClassifier.UNREACHABLE_CODE
                    val (reason, surfaced) = FastoryLoadFailureClassifier.bootstrap(code)
                    showError(reason, code = surfaced)
                },
            )
        }
    }

    /**
     * Loads the hub again under the session now in force, after an identity transition changed the
     * identified fan (SPEC § 7). Not a new presentation: the load state keeps its opening, so no
     * second opening event is announced, and a reload that fails is reported like any failure after
     * the surface opened. The panel is never reloaded. A container that has not built its page yet
     * has nothing to reload: its first resolution has not run, and it will read the new session.
     */
    internal fun reloadAfterIdentityChange() {
        if (surface != FastorySurface.HUB || presentationEnded || !::load.isInitialized) return
        // A hub standing on its error view loads its page again, as a Retry would.
        if (::errorView.isInitialized) {
            errorView.isVisible = false
            webView.isVisible = true
        }
        openSurface()
    }

    /**
     * The sequence is read off the Intent here rather than kept in a field: this is the one place it
     * is used, and reading it at the source is what keeps a container the platform recreated on the
     * sequence it was launched for. Internal rather than private so the resolution can be driven
     * without the views having been built.
     */
    internal fun resolveSurface(callback: (Result<Pair<String, String?>>) -> Unit) {
        if (surface == FastorySurface.MEMBERSHIP) {
            Fastory.resolveMembership(intent?.getStringExtra(EXTRA_SEQUENCE), callback)
        } else {
            Fastory.resolveHub(callback)
        }
    }

    /**
     * True when this container holds the reservation, false when it was asked to close before it
     * existed.
     *
     * Rebuilt by the platform — a configuration change outside the manifest's list, or *Don't keep
     * activities* — this instance carries the launch its predecessor saved and continues that
     * presentation rather than claiming a new one. A state saved by another process names a launch
     * this one never made, so it is claimed afresh, as before.
     */
    internal fun claimPresentation(savedInstanceState: Bundle? = null): Boolean {
        val recreated = savedInstanceState
            ?.takeIf { it.getString(STATE_PROCESS) == PROCESS && it.containsKey(STATE_LAUNCH) }
            ?.getInt(STATE_LAUNCH)
        if (recreated != null) {
            val opened = Fastory.resumeHubPresentation(this, recreated) ?: return false
            launch = recreated
            openedBeforeRecreation = opened
            return true
        }
        launch = Fastory.claimHubPresentation(this)
        return launch != null
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        savePresentation(outState)
    }

    internal fun savePresentation(outState: Bundle) {
        val launch = launch ?: return
        outState.putInt(STATE_LAUNCH, launch)
        outState.putString(STATE_PROCESS, PROCESS)
    }

    /**
     * Every way out ends here — the host's `close()`, the close button, the back gesture — and this
     * is where the presentation is over for the host and for the next opening.
     * Android destroys a finishing Activity only once the one beneath it has settled, which can take
     * seconds, and a reservation held until then makes an `openGames()` in that gap a silent no-op:
     * the fan closes the games, changes their mind, and their tap does nothing.
     *
     * `super.finish()` precedes `endPresentation()`, and the order is load-bearing: a host that
     * calls `openGames()` from its `hubClosed` callback must find this instance already finishing,
     * or the manifest's `singleTop` routes that start to it and no hub opens.
     */
    override fun finish() {
        // The sheet goes first, or the host hears hubClosed before gameClosed: left to the platform,
        // a sheet still up is dismissed with the Activity's destruction, after this presentation has
        // ended (SPEC § 5.3). State loss is allowed because a host may close a hub it has already
        // stopped, and a sheet on its way out has no state worth keeping.
        presentedGameSheet()?.dismissAllowingStateLoss()
        super.finish()
        endPresentation()
    }

    override fun onDestroy() {
        val launch = launch
        if (launch != null && ::webView.isInitialized) {
            if (load.hasFailedAttempt) {
                // A page whose last attempt failed is not kept: its error document committed, so
                // the slot would count it as loaded, and the error view left it hidden — the next
                // opening, or the instance rebuilt in this one's place, would present it as it
                // stands and announce the surface over a blank screen instead of loading the
                // address again (SPEC § 9.1). A retry that loaded cleared the failure, so the page
                // it healed is kept below like any other.
                (webView.parent as? ViewGroup)?.removeView(webView)
                webView.destroy()
            } else {
                // Keep the page warm for the next opening instead of reloading from scratch —
                // presented as it stands only once it loaded, loaded again if it was still on its
                // way — and in its own surface's slot: stashed over the other's it would open
                // under the wrong entry point. `config`, not the SDK's current one: a re-configure
                // may have happened while this surface was on screen, and this page still holds
                // the workspace it was built for.
                // A cover still up was this presentation's: the page goes back readable, but not
                // as one to present as it stands — it may not have drawn its document yet.
                val stillCovered = coversOutgoingDocument
                liftCover()
                Fastory.stashWebView(
                    webView,
                    surface,
                    requestedUrl,
                    config,
                    launch,
                    hasCommitted = load.hasCommittedPage && !stillCovered,
                )
            }
        }
        // Destroyed while finishing without passing through finish() — a task the platform tore
        // down — the presentation ends here. Destroyed without finishing, the platform is rebuilding
        // the surface the fan is still looking at, and the presentation outlives this instance.
        if (isFinishing) endPresentation() else suspendPresentation()
        super.onDestroy()
    }

    private fun suspendPresentation() {
        val launch = launch ?: return
        if (presentationEnded) return
        presentationEnded = true
        Fastory.suspendHubPresentation(launch, surface, opened = owesClosingEvent())
    }

    /**
     * Once per presentation. A surface that never announced itself open owes no closing event: the
     * pair brackets a session, and a close with no open in front of it reports a session that did
     * not happen (SPEC § 5.3). The reservation comes back either way — from a container that
     * finished before it built anything too, or every later opening is dead for good.
     */
    private fun endPresentation() {
        val launch = launch ?: return
        if (presentationEnded) return
        presentationEnded = true
        if (owesClosingEvent()) {
            if (surface == FastorySurface.MEMBERSHIP) {
                Fastory.notifyMembershipClosed(launch)
            } else {
                Fastory.notifyHubClosed(launch)
            }
        } else {
            Fastory.releaseHubPresentation(launch)
        }
    }

    private fun owesClosingEvent(): Boolean =
        (::load.isInitialized && load.dismiss()) || openedBeforeRecreation

    /** Emits what the load state decided, so the two events and the failure leave through one place. */
    internal fun announce(announcement: FastorySurfaceLoad.Announcement) {
        // A page still settling inside a container already dismissed announces nothing: its closing
        // event has gone out, and an opening or a failure after it would report on a session that is
        // over.
        if (presentationEnded) return
        when (announcement) {
            is FastorySurfaceLoad.Announcement.Nothing -> Unit
            is FastorySurfaceLoad.Announcement.Opened ->
                when {
                    openedBeforeRecreation -> Unit
                    surface == FastorySurface.MEMBERSHIP -> Fastory.notifyMembershipOpened(this)
                    else -> resolvedFanzoneSlug?.let { Fastory.notifyHubOpened(this, it) }
                }
            is FastorySurfaceLoad.Announcement.Failed ->
                Fastory.notifySurfaceLoadFailed(announcement.failure)
        }
    }

    private fun buildViews() {
        warmPage = Fastory.obtainWebView(surface, this)
        webView = warmPage.webView.apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        load = FastorySurfaceLoad(
            surface = surface,
            // Neither surface can announce itself sight unseen: the hub's event carries the
            // fanzone slug the key exchange returns, and the panel's own resolved address can
            // differ from whatever a warm page already committed. identify() is what learns it,
            // for both, once openSurface() knows.
            isIdentified = false,
            hasCommitted = warmPage.hasCommitted,
        )

        // A sibling over the page rather than the page hidden: a WebView taken off screen may hold
        // back its own drawing, and with it the callback that says the new document can be shown.
        // White, like a WebView that has not drawn anything yet.
        coverView = View(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            setBackgroundColor(Color.WHITE)
            // Taps meant for the new page must not reach the outgoing one underneath.
            isClickable = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            isVisible = coversOutgoingDocument
        }

        val strings = FastoryErrorView.localizedContext(this)
        val loading = strings.getString(R.string.fastory_sdk_loading)
        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            )
            max = 100
            isVisible = webView.progress < 100
            // Nothing has reported progress yet on a cold open, and the exchange is a round trip
            // before there is any document to report it — the same state Retry lands in.
            isIndeterminate = webView.progress == 0
            contentDescription = loading
        }

        errorView = FastoryErrorView.build(this) { retry() }.apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }

        closeButton = TextView(this).apply {
            text = "✕"
            textSize = 16f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(150, 0, 0, 0))
            }
            val density = resources.displayMetrics.density
            val size = (36 * density).toInt()
            val margin = (12 * density).toInt()
            layoutParams = FrameLayout.LayoutParams(size, size, Gravity.TOP or Gravity.END).apply {
                topMargin = margin
                marginEnd = margin
            }
            contentDescription = strings.getString(R.string.fastory_sdk_close)
            // The glyph is drawn as text; the role is what a screen reader says after the label.
            ViewCompat.setAccessibilityDelegate(
                this,
                object : AccessibilityDelegateCompat() {
                    override fun onInitializeAccessibilityNodeInfo(
                        host: View,
                        info: AccessibilityNodeInfoCompat,
                    ) {
                        super.onInitializeAccessibilityNodeInfo(host, info)
                        info.className = Button::class.java.name
                    }
                },
            )
            setOnClickListener { finish() }
        }

        root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(webView)
            addView(coverView)
            addView(errorView)
            addView(progressBar)
            addView(closeButton)
        }
        retryWait = FastoryErrorView.RetryWait(
            host = root,
            loading = loading,
            loaded = strings.getString(R.string.fastory_sdk_loaded),
        )
    }

    private fun applyWindowInsets() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or
                    WindowInsetsCompat.Type.displayCutout(),
            )
            // WebView A stays edge-to-edge — the chromeless Fanzone pads its own content via
            // env(safe-area-inset-*); only the native close button is inset below the system bars.
            val margin = (12 * resources.displayMetrics.density).toInt()
            (closeButton.layoutParams as FrameLayout.LayoutParams).apply {
                topMargin = bars.top + margin
                marginEnd = bars.right + margin
            }
            closeButton.requestLayout()
            // Under the status bar, the bar was never seen — and over a cover it is all that moves.
            (progressBar.layoutParams as FrameLayout.LayoutParams).topMargin = bars.top
            progressBar.requestLayout()
            WindowInsetsCompat.CONSUMED
        }
    }

    private fun configureCookies() {
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView() {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            javaScriptCanOpenWindowsAutomatically = true
            setSupportMultipleWindows(true)
        }

        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest,
            ): Boolean {
                val url = request.url.toString()
                return when (UrlPolicy.decide(url, config.baseUrl)) {
                    NavigationDecision.ALLOW -> {
                        // A new main-frame document: it may fail on its own account, and a failure
                        // already reported for the previous one must not swallow that. Never a
                        // second hubOpened — the state machine keeps that to one per presentation.
                        if (request.isForMainFrame) load.restart()
                        false
                    }
                    NavigationDecision.OPEN_GAME_SHEET -> {
                        openGameSheet(url)
                        true
                    }
                    NavigationDecision.OPEN_EXTERNAL_BROWSER -> {
                        Fastory.openExternalBrowser(this@FastoryHubActivity, url)
                        true
                    }
                }
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) {
                    showError(FastoryLoadFailureClassifier.navigation(error.errorCode))
                }
            }

            /**
             * `onReceivedError` never fires for an HTTP failure, so without this a 404 fanzone
             * renders the server's error body and the fan sees neither the error view § 9 promises
             * nor the status.
             */
            override fun onReceivedHttpError(
                view: WebView,
                request: WebResourceRequest,
                errorResponse: WebResourceResponse,
            ) {
                if (request.isForMainFrame) {
                    showError(
                        FastoryLoadFailureReason.REJECTED,
                        statusCode = errorResponse.statusCode,
                    )
                }
            }

            /**
             * The document has been accepted for display, which is what makes the surface open.
             * A commit alone proves nothing, though: an error document reaches here like any other
             * — the server's body for a 404, the WebView's own page for a connection that never
             * came up. What keeps the opening event off such a page is the failure the two
             * callbacks above record (SPEC § 9.1).
             */
            override fun onPageCommitVisible(view: WebView, url: String?) {
                // What this callback exists for: the moment a reused WebView can be shown without
                // drawing what it held before.
                onDocumentShown()
                announce(load.commit())
            }

            override fun doUpdateVisitedHistory(view: WebView, url: String?, isReload: Boolean) {
                onVisitedHistoryUpdated()
            }

            override fun onPageFinished(view: WebView, url: String?) {
                onLoadFinished()
                // Under a cover the wait ends with the paint, which announces it then.
                if (!coversOutgoingDocument) retryWait.succeed()
                // Discover and prewarm the hub's games on every completed load (including
                // retries), so tapping a tile presents an already-rendered game. The games are
                // listed by the hub's page and by no other, so no other surface discovers.
                if (surface == FastorySurface.HUB) GamePreloader.onHubLoadFinished(view, config)
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                // Loaded but still covered, a full bar would read as done: it keeps moving instead.
                progressBar.isIndeterminate = newProgress >= 100 && coversOutgoingDocument
                progressBar.progress = newProgress
                progressBar.isVisible = newProgress < 100 || coversOutgoingDocument
            }

            override fun onCreateWindow(
                view: WebView,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: android.os.Message,
            ): Boolean {
                // The hub opens games via window.open; without intercepting the new-window
                // request it escapes to the system browser. Capture the target URL through a
                // throwaway WebView and route it through UrlPolicy like a main-frame navigation.
                val popup = WebView(view.context)
                popup.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(
                        popupView: WebView,
                        request: WebResourceRequest,
                    ): Boolean {
                        routePopupUrl(request.url.toString())
                        popup.destroy()
                        return true
                    }
                }
                (resultMsg.obj as WebView.WebViewTransport).webView = popup
                resultMsg.sendToTarget()
                return true
            }
        }
    }

    private fun routePopupUrl(url: String) {
        when (UrlPolicy.decide(url, config.baseUrl)) {
            NavigationDecision.ALLOW -> webView.loadUrl(url)
            NavigationDecision.OPEN_GAME_SHEET -> openGameSheet(url)
            NavigationDecision.OPEN_EXTERNAL_BROWSER ->
                Fastory.openExternalBrowser(this, url)
        }
    }

    private fun openGameSheet(url: String) {
        val slug = UrlPolicy.gameSlug(url) ?: return
        if (presentedGameSheet() != null) return
        GameBottomSheet.newInstance(gameSheetUrl(url), slug)
            .show(supportFragmentManager, GameBottomSheet.TAG)
    }

    /** Internal rather than private: the taps that reach it come through the WebView, which the tests cannot drive. */
    internal fun gameSheetUrl(url: String): String = UrlPolicy.embeddedGameUrl(url, config.gamePresentationQuery.toList())

    private fun presentedGameSheet(): DialogFragment? =
        supportFragmentManager.findFragmentByTag(GameBottomSheet.TAG) as? DialogFragment

    /**
     * SPEC § 6's three steps. Until the document this presentation loaded has committed, whatever
     * the page could go back to belongs to an earlier one, so back closes rather than walk into it.
     * Internal rather than private so back can be driven without the views having been built.
     */
    internal fun handleBack() {
        val sheet = presentedGameSheet()
        when {
            sheet != null -> sheet.dismiss()
            webView.canGoBack() && clearsHistoryOnCommitOf == null -> webView.goBack()
            else -> finish()
        }
    }

    private fun showError(
        reason: FastoryLoadFailureReason,
        code: String? = null,
        statusCode: Int? = null,
    ) {
        webView.isVisible = false
        liftCover()
        retryWait.fail()
        FastoryErrorView.show(errorView, reason)
        // Nothing is loading any more, and a bar left over the error view reads as one that is.
        progressBar.isVisible = false
        announce(load.fail(reason, code = code, statusCode = statusCode))
    }

    /**
     * A retry may open the hub the first load could not, so the failure it follows is cleared —
     * otherwise the surface stays permanently unable to announce itself.
     *
     * Configured by key there is no loaded URL to reload, so what has to run again is the exchange
     * (SPEC § 9) — and it does not restart on its own: [WorkspaceResolver.rearmAfterFailure] carries
     * why, and which refusals it declines to re-arm.
     *
     * The progress bar comes up first, indeterminate — no document reports progress yet, and
     * `onProgressChanged` takes it back the moment one does — because the screen reader's wait needs
     * something to land on, and because the resolution can fail on the spot: a refusal the resolver
     * declined to re-arm answers synchronously, and the error view's announcement has to come second.
     */
    private fun retry() {
        errorView.isVisible = false
        webView.isVisible = true
        load.restart()
        progressBar.isIndeterminate = true
        progressBar.isVisible = true
        retryWait.begin(progressBar)
        // `reload()` on a WebView that never got a URL does nothing at all, so this is also where a
        // refused exchange lands.
        if (!hasStartedLoad) {
            Fastory.retryHubResolution()
            openSurface()
        } else {
            webView.reload()
        }
    }

    companion object {
        /**
         * True once the page has drawn content: Paint Timing records the entry at its first contentful
         * paint.
         */
        private const val FIRST_CONTENTFUL_PAINT_PROBE =
            "performance.getEntriesByName('first-contentful-paint').length > 0"
        private const val FIRST_PAINT_POLL_MS = 50L

        /** A page that never reports a paint is shown anyway, rather than left under the cover. */
        private const val FIRST_PAINT_WAIT_MS = 2_000L

        /**
         * Which surface the container presents, as its wire name. Absent means the hub: it is the
         * surface the container was built for, and the one every host on the 0.x line opens.
         */
        internal const val EXTRA_SURFACE = "com.fastory.sdk.surface"

        /**
         * Which of the workspace's sequences the panel opens on, as the host named it. Absent means
         * the panel's default screen.
         */
        internal const val EXTRA_SEQUENCE = "com.fastory.sdk.sequence"

        private const val STATE_LAUNCH = "com.fastory.sdk.hub.launch"
        private const val STATE_PROCESS = "com.fastory.sdk.hub.process"

        /** Tells this process's saved state from a previous one's, whose launch numbers mean nothing here. */
        private val PROCESS: String = java.util.UUID.randomUUID().toString()
    }
}
