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
import androidx.core.os.bundleOf
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import com.fastory.sdk.flutter.R
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.bottomsheet.BottomSheetDialogFragment

class GameBottomSheet : BottomSheetDialogFragment() {

    private var webView: WebView? = null
    private var errorView: LinearLayout? = null
    private var isPreloaded = false

    /**
     * The same gate the hub uses (SPEC § 9.1): `gameOpened` announces a game whose page loaded, and
     * a sheet that only ever showed the error view owes no `gameClosed`.
     */
    private var load: FastorySurfaceLoad? = null

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

        val closeButton = ImageButton(context).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setBackgroundResource(android.R.color.transparent)
            contentDescription = getString(R.string.fastory_sdk_close)
            setOnClickListener { dismiss() }
        }

        // Game WebView fills the sheet edge-to-edge (under the status bar); the close button is
        // overlaid top-right and inset below the system bars.
        return FrameLayout(context).apply {
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
        super.onDestroyView()
    }

    override fun onDismiss(dialog: DialogInterface) {
        super.onDismiss(dialog)
        // A game that never announced itself open owes no gameClosed — the pair brackets a session,
        // and a sheet that only showed the error view held none (SPEC § 5.3).
        if (load?.dismiss() == true) {
            Fastory.notifyGameClosed()
        }
    }

    private fun announce(announcement: FastorySurfaceLoad.Announcement?) {
        when (announcement) {
            null, is FastorySurfaceLoad.Announcement.Nothing -> Unit
            is FastorySurfaceLoad.Announcement.Opened ->
                Fastory.notifyGameOpened(requireArguments().getString(ARG_SLUG).orEmpty())
            is FastorySurfaceLoad.Announcement.Failed ->
                Fastory.notifySurfaceLoadFailed(announcement.failure)
        }
    }

    private fun showError(
        reason: FastoryLoadFailureReason,
        statusCode: Int? = null,
    ) {
        errorView?.isVisible = true
        webView?.isVisible = false
        announce(load?.fail(reason, statusCode = statusCode))
    }

    private fun retry() {
        errorView?.isVisible = false
        webView?.isVisible = true
        load?.restart()
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

        fun newInstance(url: String, slug: String): GameBottomSheet = GameBottomSheet().apply {
            arguments = bundleOf(ARG_URL to url, ARG_SLUG to slug)
        }
    }
}
