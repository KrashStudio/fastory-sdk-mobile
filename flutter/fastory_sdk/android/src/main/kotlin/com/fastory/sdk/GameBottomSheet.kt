package com.fastory.sdk

import android.annotation.SuppressLint
import android.app.Dialog
import android.graphics.Color
import android.content.DialogInterface
import android.os.Bundle
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import androidx.core.os.bundleOf
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import com.fastory.sdk.flutter.R
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.bottomsheet.BottomSheetDialogFragment

class GameBottomSheet : BottomSheetDialogFragment() {

    private var webView: WebView? = null
    private var warmLoadedSlug: String? = null

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

        val (obtained, loadedSlug) = Fastory.obtainGameWebView(requireActivity())
        warmLoadedSlug = loadedSlug
        webView = obtained.also { configureWebView(it) }

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
                webView,
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

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        val url = requireArguments().getString(ARG_URL) ?: run {
            dismiss()
            return
        }
        val slug = requireArguments().getString(ARG_SLUG).orEmpty()
        // Reopening the game that is still warm: show it as-is, state preserved, no reload.
        if (warmLoadedSlug != slug || webView?.url == null) {
            webView?.loadUrl(url)
        }
        Fastory.notifyGameOpened(slug)
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
        // Keep the loaded game warm: reopening the same game is instant, another game reuses
        // the webview and its warm renderer process.
        webView?.let {
            Fastory.stashGameWebView(it, requireArguments().getString(ARG_SLUG).orEmpty())
        }
        webView = null
        super.onDestroyView()
    }

    override fun onDismiss(dialog: DialogInterface) {
        super.onDismiss(dialog)
        Fastory.notifyGameClosed()
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
                    -> false
                    NavigationDecision.OPEN_EXTERNAL_BROWSER -> {
                        Fastory.openExternalBrowser(requireContext(), url)
                        true
                    }
                }
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
            -> webView?.loadUrl(url)
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
