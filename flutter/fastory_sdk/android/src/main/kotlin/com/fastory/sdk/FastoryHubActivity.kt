package com.fastory.sdk

import android.annotation.SuppressLint
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
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

class FastoryHubActivity : AppCompatActivity() {

    private lateinit var config: FastoryConfig
    private lateinit var root: FrameLayout
    private lateinit var webView: WebView
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

    /** The fanzone `hubOpened` names, known up front on the slug path and from the API on the key one. */
    internal var resolvedFanzoneSlug: String? = null

    private var hasStartedLoad = false

    /**
     * The launch this hub answers for, handed out by [Fastory.claimHubPresentation] — or carried in
     * the saved state of the instance it replaces, for a hub the platform rebuilt: null until then,
     * then fixed for the Activity's life — its destruction still needs it once the
     * presentation has ended, to tell a page worth keeping warm from one that is out of date.
     */
    private var launch: Int? = null

    private var presentationEnded = false

    /**
     * This instance is the platform's rebuild of a hub whose `hubOpened` the host has already heard.
     * The page announces itself again as it settles here, and that second opening is not passed on;
     * the closing it owes is.
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
        openHub()
    }

    /**
     * Configured by publishable key, the fanzone is resolved from the API — the progress bar covers
     * that round trip, and a rejected key lands on the same native error view as a failed page load
     * rather than on a blank webview. A warm page is never reloaded here: that is the whole point of
     * the warm-up.
     */
    private fun openHub() {
        Fastory.resolveHub { result ->
            result.fold(
                onSuccess = { (url, fanzoneSlug) ->
                    resolvedFanzoneSlug = fanzoneSlug
                    announce(load.identify())
                    if (!hasStartedLoad) {
                        hasStartedLoad = true
                        webView.loadUrl(url)
                    }
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
     * True when this hub holds the reservation, false when it was asked to close before it existed.
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
     * Every way out of the hub ends here — the host's `close()`, the close button, the back gesture —
     * and this is where the presentation is over for the host and for the next `openGames()`.
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
            // Keep the loaded hub warm for the next openGames() instead of reloading from scratch.
            // `config`, not the SDK's current one: a re-configure may have happened while this hub
            // was on screen, and this page still holds the fanzone it was built for.
            Fastory.stashHubWebView(webView, config, launch, hasCommitted = load.hasCommittedPage)
        }
        // Destroyed while finishing without passing through finish() — a task the platform tore
        // down — the presentation ends here. Destroyed without finishing, the platform is rebuilding
        // the hub the fan is still looking at, and the presentation outlives this instance.
        if (isFinishing) endPresentation() else suspendPresentation()
        super.onDestroy()
    }

    private fun suspendPresentation() {
        val launch = launch ?: return
        if (presentationEnded) return
        presentationEnded = true
        Fastory.suspendHubPresentation(launch, opened = owesHubClosed())
    }

    /**
     * Once per presentation. A hub that never announced itself open owes no hubClosed: the pair
     * brackets a session, and a close with no open in front of it reports a session that did not
     * happen (SPEC § 5.3). The reservation comes back either way — from a hub that finished before
     * it built anything too, or openGames() is dead for good.
     */
    private fun endPresentation() {
        val launch = launch ?: return
        if (presentationEnded) return
        presentationEnded = true
        if (owesHubClosed()) {
            Fastory.notifyHubClosed(launch)
        } else {
            Fastory.releaseHubPresentation(launch)
        }
    }

    private fun owesHubClosed(): Boolean =
        (::load.isInitialized && load.dismiss()) || openedBeforeRecreation

    /** Emits what the load state decided, so the two events and the failure leave through one place. */
    internal fun announce(announcement: FastorySurfaceLoad.Announcement) {
        // A page still settling inside a hub already dismissed announces nothing: its hubClosed has
        // gone out, and an opening or a failure after it would report on a session that is over.
        if (presentationEnded) return
        when (announcement) {
            is FastorySurfaceLoad.Announcement.Nothing -> Unit
            is FastorySurfaceLoad.Announcement.Opened ->
                if (!openedBeforeRecreation) {
                    resolvedFanzoneSlug?.let { Fastory.notifyHubOpened(this, it) }
                }
            is FastorySurfaceLoad.Announcement.Failed ->
                Fastory.notifySurfaceLoadFailed(announcement.failure)
        }
    }

    private fun buildViews() {
        val warm = Fastory.obtainHubWebView(this)
        webView = warm.webView.apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        hasStartedLoad = warm.hasCommitted || warm.isLoading
        load = FastorySurfaceLoad(
            surface = FastorySurface.HUB,
            isIdentified = false,
            hasCommitted = warm.hasCommitted,
        )

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
             * The document has been accepted for display, which is what makes the hub genuinely
             * open. A page that 404s or never connects never reaches here, which is precisely what
             * keeps `hubOpened` off it (SPEC § 9.1).
             */
            override fun onPageCommitVisible(view: WebView, url: String?) {
                announce(load.commit())
            }

            override fun onPageFinished(view: WebView, url: String?) {
                announce(load.commit())
                retryWait.succeed()
                // Discover and prewarm the hub's games on every completed load (including
                // retries), so tapping a tile presents an already-rendered game.
                GamePreloader.onHubLoadFinished(view)
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
                progressBar.isIndeterminate = false
                progressBar.progress = newProgress
                progressBar.isVisible = newProgress < 100
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
        GameBottomSheet.newInstance(UrlPolicy.embeddedGameUrl(url), slug)
            .show(supportFragmentManager, GameBottomSheet.TAG)
    }

    private fun presentedGameSheet(): DialogFragment? =
        supportFragmentManager.findFragmentByTag(GameBottomSheet.TAG) as? DialogFragment

    private fun handleBack() {
        val sheet = presentedGameSheet()
        when {
            sheet != null -> sheet.dismiss()
            webView.canGoBack() -> webView.goBack()
            else -> finish()
        }
    }

    private fun showError(
        reason: FastoryLoadFailureReason,
        code: String? = null,
        statusCode: Int? = null,
    ) {
        webView.isVisible = false
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
            openHub()
        } else {
            webView.reload()
        }
    }

    private companion object {
        const val STATE_LAUNCH = "com.fastory.sdk.hub.launch"
        const val STATE_PROCESS = "com.fastory.sdk.hub.process"

        /** Tells this process's saved state from a previous one's, whose launch numbers mean nothing here. */
        val PROCESS: String = java.util.UUID.randomUUID().toString()
    }
}
