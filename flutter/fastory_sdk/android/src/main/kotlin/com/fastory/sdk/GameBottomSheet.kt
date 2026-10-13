package com.fastory.sdk

import android.annotation.SuppressLint
import android.app.Dialog
import android.graphics.Color
import android.content.DialogInterface
import android.content.MutableContextWrapper
import android.os.Bundle
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import androidx.core.os.bundleOf
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isInvisible
import androidx.core.view.isVisible
import androidx.fragment.app.Fragment
import com.fastory.sdk.flutter.R
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.bottomsheet.BottomSheetDialogFragment

class GameBottomSheet : BottomSheetDialogFragment() {

    private var webView: WebView? = null
    private var errorView: LinearLayout? = null
    private var progressBar: ProgressBar? = null
    private var retryWait: FastoryErrorView.RetryWait? = null
    private var isPreloaded = false

    /**
     * The same gate the hub uses (SPEC § 9.1): `gameOpened` announces a game whose page loaded, and
     * a sheet that only ever showed the error view owes no `gameClosed`.
     */
    internal var load: FastorySurfaceLoad? = null

    /**
     * This sheet is the platform's rebuild of a game whose `gameOpened` the host has already heard.
     * The page announces itself again as it settles here, and that second opening is not passed on;
     * the closing it owes is.
     */
    private var openedBeforeRecreation = false

    /** Whose teardown the view's destruction is, for the dismissal DialogFragment delivers from it. */
    private var hostIsRebuilding = false

    /** What the last saved state told the sheet the platform will restore: whether it had opened. */
    private var savedOpened = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        restorePresentation(savedInstanceState)
    }

    override fun onCreateDialog(savedInstanceState: Bundle?): Dialog {
        val dialog = super.onCreateDialog(savedInstanceState) as BottomSheetDialog
        dialog.behavior.state = BottomSheetBehavior.STATE_EXPANDED
        dialog.behavior.skipCollapsed = true
        dialog.window?.let { window ->
            WindowCompat.setDecorFitsSystemWindows(window, false)
            window.statusBarColor = Color.TRANSPARENT
            window.navigationBarColor = Color.TRANSPARENT
        }
        return dialog
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View {
        val context = requireContext()

        val slug = requireArguments().getString(ARG_SLUG).orEmpty()
        val preloaded = GamePreloader.takeWebView(requireActivity(), slug)
        isPreloaded = preloaded != null
        val gameWebView = (preloaded ?: Fastory.createWebView(MutableContextWrapper(requireActivity())))
            .also { configureWebView(it) }
        webView = gameWebView
        // `getUrl()` lags to the *committed* page, so a non-null one here means the preloader's
        // page committed and a prewarmed game announces itself the instant the sheet appears. iOS
        // cannot read this: `WKWebView.url` is the active URL, so its preloader hands the state over
        // explicitly instead.
        load = FastorySurfaceLoad(
            surface = FastorySurface.GAME,
            hasCommitted = gameWebView.url != null,
        )

        val strings = FastoryErrorView.localizedContext(context)
        val loading = strings.getString(R.string.fastory_sdk_loading)
        val closeButton = ImageButton(context).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setBackgroundResource(android.R.color.transparent)
            contentDescription = strings.getString(R.string.fastory_sdk_close)
            setOnClickListener { dismiss() }
        }
        // Shown only for the wait Retry opens: a game opening for the first time is preloaded or
        // presented, and TalkBack announces the dialog itself. During that wait it is what TalkBack
        // lands on, so it carries the hub progress bar's label. Invisible rather than gone, so it
        // is already laid out when Retry asks TalkBack to land on it in the same frame.
        val indicator = ProgressBar(context).apply {
            isIndeterminate = true
            isInvisible = true
            contentDescription = loading
        }.also { progressBar = it }

        // Game WebView fills the sheet edge-to-edge (under the status bar); the close button is
        // overlaid top-right and inset below the system bars.
        val root = FrameLayout(context).apply {
            setBackgroundColor(Color.BLACK)
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            addView(
                gameWebView,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
            addView(
                buildErrorView().also { errorView = it },
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
            addView(
                indicator,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    Gravity.CENTER,
                ),
            )
            val margin = (8 * resources.displayMetrics.density).toInt()
            addView(
                closeButton,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    Gravity.TOP or Gravity.END,
                ).apply {
                    topMargin = margin
                    marginEnd = margin
                },
            )
            ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
                val top = insets.getInsets(WindowInsetsCompat.Type.systemBars()).top
                (closeButton.layoutParams as FrameLayout.LayoutParams).topMargin = top + margin
                closeButton.requestLayout()
                insets
            }
        }
        retryWait = FastoryErrorView.RetryWait(
            host = root,
            loading = loading,
            loaded = strings.getString(R.string.fastory_sdk_loaded),
        )
        return root
    }

    /**
     * The game sheet's own native error view (SPEC § 9). Without it a failed game is a black sheet,
     * which the fan cannot tell from a slow one. The sheet's own close button stays overlaid on top
     * of it, so § 9's "the fan keeps a way out" needs no second affordance here.
     */
    private fun buildErrorView(): LinearLayout =
        FastoryErrorView.build(requireContext()) { retry() }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        val url = requireArguments().getString(ARG_URL) ?: run {
            dismiss()
            return
        }
        GamePreloader.gameSheetWillPresent()
        // A preloaded WebView is already rendering the game (or finishing its load) on a
        // fresh state — present it as-is. Only cold opens need a load here.
        if (!isPreloaded) {
            webView?.loadUrl(url)
        }
        announce(load?.present())
    }

    override fun onStart() {
        super.onStart()
        dialog
            ?.findViewById<View>(com.google.android.material.R.id.design_bottom_sheet)
            ?.let { sheet ->
                sheet.layoutParams = sheet.layoutParams.apply {
                    height = ViewGroup.LayoutParams.MATCH_PARENT
                }
                sheet.setBackgroundColor(Color.BLACK)
                ViewCompat.setOnApplyWindowInsetsListener(sheet) { v, insets ->
                    v.setPadding(0, 0, 0, 0)
                    insets
                }
            }
    }

    override fun onDestroyView() {
        // A dialog nobody dismissed is dismissed by super.onDestroyView(), and that is the only
        // dismissal a rebuild of the hub delivers, so the rebuild is read here, before that call.
        hostIsRebuilding = isTornDownForRebuild()
        // Closing must actually end the game: destroy the played WebView — its page
        // (timers, audio, state) dies with it. The preloader immediately rebuilds a fresh
        // copy so reopening stays instant.
        webView?.let { playedWebView ->
            playedWebView.stopLoading()
            (playedWebView.parent as? ViewGroup)?.removeView(playedWebView)
            playedWebView.destroy()
            GamePreloader.gameSheetDidClose(
                requireArguments().getString(ARG_SLUG).orEmpty(),
                requireArguments().getString(ARG_URL),
            )
        }
        webView = null
        errorView = null
        progressBar = null
        retryWait = null
        super.onDestroyView()
    }

    override fun onDismiss(dialog: DialogInterface) {
        super.onDismiss(dialog)
        endPresentation(hostIsRebuilding = hostIsRebuilding)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        savePresentation(outState)
    }

    internal fun savePresentation(outState: Bundle) {
        savedOpened = load?.isOpen == true || openedBeforeRecreation
        outState.putBoolean(STATE_OPENED, savedOpened)
        outState.putString(STATE_PROCESS, PROCESS)
    }

    /** A state saved by another process describes a game whose host heard nothing from this one. */
    internal fun restorePresentation(savedInstanceState: Bundle?) {
        openedBeforeRecreation = savedInstanceState
            ?.takeIf { it.getString(STATE_PROCESS) == PROCESS }
            ?.getBoolean(STATE_OPENED) == true
    }

    /**
     * A game that never announced itself open owes no gameClosed — the pair brackets a session, and
     * a sheet that only showed the error view held none (SPEC § 5.3). Torn down with a hub the
     * platform is rebuilding, the game never left the fan's screen: its closing is handed to the
     * hub's suspended presentation, which the sheet restored with it takes back — provided the state
     * it is restored from says so. A game that opened after that state was saved would announce
     * itself a second time, so its closing goes out now and the restored sheet opens a new pair.
     */
    internal fun endPresentation(hostIsRebuilding: Boolean) {
        val owed = load?.dismiss() == true || openedBeforeRecreation
        openedBeforeRecreation = false
        if (!owed) return
        if (hostIsRebuilding && savedOpened && Fastory.suspendGamePresentation()) return
        Fastory.notifyGameClosed()
    }

    internal fun announce(announcement: FastorySurfaceLoad.Announcement?) {
        when (announcement) {
            null, is FastorySurfaceLoad.Announcement.Nothing -> Unit
            is FastorySurfaceLoad.Announcement.Opened ->
                if (!openedBeforeRecreation) {
                    Fastory.notifyGameOpened(requireArguments().getString(ARG_SLUG).orEmpty())
                }
            is FastorySurfaceLoad.Announcement.Failed ->
                Fastory.notifySurfaceLoadFailed(announcement.failure)
        }
    }

    private fun showError(
        reason: FastoryLoadFailureReason,
        statusCode: Int? = null,
    ) {
        webView?.isVisible = false
        retryWait?.fail()
        // Nothing is loading any more, and an indicator left over the error view reads as one that is.
        progressBar?.isInvisible = true
        errorView?.let { FastoryErrorView.show(it, reason) }
        announce(load?.fail(reason, statusCode = statusCode))
    }

    /**
     * The indicator comes up before TalkBack is asked to land on it — a focus request on a hidden
     * view is refused — and both happen before the reload, so a failure reported for it is
     * announced second.
     */
    private fun retry() {
        errorView?.isVisible = false
        webView?.isVisible = true
        load?.restart()
        progressBar?.let { indicator ->
            indicator.isInvisible = false
            retryWait?.begin(indicator)
        }
        webView?.reload()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView(webView: WebView) {
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
                val baseUrl = Fastory.config?.baseUrl ?: return false
                val url = request.url.toString()
                return when (UrlPolicy.decide(url, baseUrl)) {
                    NavigationDecision.ALLOW,
                    NavigationDecision.OPEN_GAME_SHEET,
                    -> {
                        // A new main-frame document may fail on its own account, and a failure
                        // reported for the previous one must not swallow that.
                        if (request.isForMainFrame) load?.restart()
                        false
                    }
                    NavigationDecision.OPEN_EXTERNAL_BROWSER -> {
                        Fastory.openExternalBrowser(requireContext(), url)
                        true
                    }
                }
            }

            /**
             * Without the three callbacks below there is no point in the sheet's code where a
             * failure can be seen at all, and a game that 404s renders a blank sheet (SPEC § 9.1).
             */
            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) {
                    showError(FastoryLoadFailureClassifier.navigation(error.errorCode))
                }
            }

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

            override fun onPageCommitVisible(view: WebView, url: String?) {
                announce(load?.commit())
            }

            override fun onPageFinished(view: WebView, url: String?) {
                progressBar?.isInvisible = true
                retryWait?.succeed()
            }
        }

        webView.webChromeClient = object : android.webkit.WebChromeClient() {
            override fun onCreateWindow(
                view: WebView,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: android.os.Message,
            ): Boolean {
                // A game inside the sheet may call window.open; capture the target and route it
                // through UrlPolicy instead of letting it escape to the system browser.
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
        val baseUrl = Fastory.config?.baseUrl ?: return
        when (UrlPolicy.decide(url, baseUrl)) {
            NavigationDecision.ALLOW,
            NavigationDecision.OPEN_GAME_SHEET,
            -> {
                load?.restart()
                webView?.loadUrl(url)
            }
            NavigationDecision.OPEN_EXTERNAL_BROWSER ->
                Fastory.openExternalBrowser(requireContext(), url)
        }
    }

    companion object {
        const val TAG = "FastoryGameBottomSheet"
        private const val ARG_URL = "url"
        private const val ARG_SLUG = "slug"
        private const val STATE_OPENED = "com.fastory.sdk.game.opened"
        private const val STATE_PROCESS = "com.fastory.sdk.game.process"

        /** Tells this process's saved state from a previous one's. */
        private val PROCESS: String = java.util.UUID.randomUUID().toString()

        fun newInstance(url: String, slug: String): GameBottomSheet = GameBottomSheet().apply {
            arguments = bundleOf(ARG_URL to url, ARG_SLUG to slug)
        }
    }
}

/**
 * The platform is rebuilding this fragment's Activity — a configuration change outside the manifest's
 * list, or *Don't keep activities* — rather than removing the fragment or finishing its host: the
 * test the hub applies to itself, `isFinishing`, read from the fragment.
 */
internal fun Fragment.isTornDownForRebuild(): Boolean = !isRemoving && activity?.isFinishing == false
