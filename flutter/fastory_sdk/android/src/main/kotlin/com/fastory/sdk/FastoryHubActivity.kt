package com.fastory.sdk

import android.annotation.SuppressLint
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import com.fastory.sdk.flutter.R

class FastoryHubActivity : AppCompatActivity() {

    private lateinit var config: FastoryConfig
    private lateinit var root: FrameLayout
    private lateinit var webView: WebView
    private lateinit var progressBar: ProgressBar
    private lateinit var errorView: LinearLayout
    private lateinit var closeButton: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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

        // Configured by publishable key, the fanzone is resolved from the API — the progress bar
        // covers that round trip, and a rejected key lands on the same native error view as a
        // failed page load rather than on a blank webview.
        Fastory.resolveHub { result ->
            result.fold(
                onSuccess = { (url, fanzoneSlug) ->
                    Fastory.notifyHubOpened(this, fanzoneSlug)
                    if (webView.url == null) {
                        webView.loadUrl(url)
                    }
                },
                onFailure = { showError() },
            )
        }
    }

    override fun onDestroy() {
        if (::webView.isInitialized) {
            // Keep the loaded hub warm for the next openGames() instead of reloading from scratch.
            Fastory.stashHubWebView(webView)
            Fastory.notifyHubClosed(this)
        }
        super.onDestroy()
    }

    private fun buildViews() {
        webView = Fastory.obtainHubWebView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }

        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            )
            max = 100
            isVisible = webView.progress < 100
        }

        errorView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            setBackgroundColor(Color.WHITE)
            isVisible = false

            addView(
                TextView(this@FastoryHubActivity).apply {
                    text = getString(R.string.fastory_sdk_error_message)
                    gravity = Gravity.CENTER
                },
            )
            addView(
                Button(this@FastoryHubActivity).apply {
                    text = getString(R.string.fastory_sdk_retry)
                    setOnClickListener { retry() }
                },
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
            setOnClickListener { finish() }
        }

        root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(webView)
            addView(errorView)
            addView(progressBar)
            addView(closeButton)
        }
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
                    NavigationDecision.ALLOW -> false
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
                    showError()
                }
            }

            override fun onPageFinished(view: WebView, url: String?) {
                // Discover and prewarm the hub's games on every completed load (including
                // retries), so tapping a tile presents an already-rendered game.
                GamePreloader.onHubLoadFinished(view)
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, newProgress: Int) {
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
        if (supportFragmentManager.findFragmentByTag(GameBottomSheet.TAG) != null) return
        GameBottomSheet.newInstance(UrlPolicy.embeddedGameUrl(url), slug)
            .show(supportFragmentManager, GameBottomSheet.TAG)
    }

    private fun handleBack() {
        val sheet = supportFragmentManager.findFragmentByTag(GameBottomSheet.TAG) as? GameBottomSheet
        when {
            sheet != null -> sheet.dismiss()
            webView.canGoBack() -> webView.goBack()
            else -> finish()
        }
    }

    private fun showError() {
        webView.isVisible = false
        errorView.isVisible = true
    }

    private fun retry() {
        errorView.isVisible = false
        webView.isVisible = true
        webView.reload()
    }
}
