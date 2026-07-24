package com.fastory.sdk

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.MutableContextWrapper
import android.content.res.Configuration
import android.net.Uri
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import java.lang.ref.WeakReference

interface FastoryEventsListener {
    fun onHubOpened(fanzoneSlug: String) {}
    fun onHubClosed() {}
    fun onGameOpened(slug: String) {}
    fun onGameClosed() {}
    fun onExternalLink(url: String) {}
}

object Fastory {

    @Volatile
    internal var config: FastoryConfig? = null
        private set

    @Volatile
    private var listener: FastoryEventsListener? = null

    private var hubRef: WeakReference<Activity>? = null

    fun configure(config: FastoryConfig, listener: FastoryEventsListener? = null) {
        val hubUrlChanged = this.config?.hubUrl != config.hubUrl
        this.config = config
        this.listener = listener
        if (hubUrlChanged) {
            discardWarmHub()
        }
    }

    fun openGames(context: Context) {
        checkNotNull(config) { "Fastory.configure() must be called before openGames()" }
        val intent = Intent(context, FastoryHubActivity::class.java)
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    fun close() {
        hubRef?.get()?.finish()
    }

    internal fun notifyHubOpened(activity: Activity) {
        hubRef = WeakReference(activity)
        listener?.onHubOpened(config?.fanzoneSlug.orEmpty())
    }

    internal fun notifyHubClosed(activity: Activity) {
        if (hubRef?.get() === activity) {
            hubRef = null
        }
        listener?.onHubClosed()
    }

    internal fun notifyGameOpened(slug: String) {
        listener?.onGameOpened(slug)
    }

    internal fun notifyGameClosed() {
        listener?.onGameClosed()
    }

    internal fun openExternalBrowser(context: Context, url: String) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            listener?.onExternalLink(url)
        } catch (_: ActivityNotFoundException) {
        }
    }

    // Hub keep-alive: the hub WebView is created on a MutableContextWrapper and retained across
    // sessions, so openGames() re-attaches an already-rendered page instead of reloading every
    // time. preloadHub() (called by host bridges that own a Context, e.g. the Flutter plugin)
    // additionally warms it up right after configure(). Dropped when the hub URL changes and
    // under memory pressure.

    private var warmHubWebView: WebView? = null
    private var trimCallbacksRegistered = false

    internal fun preloadHub(context: Context) {
        val config = config ?: return
        if (hubRef?.get() != null || warmHubWebView != null) return
        registerTrimCallbacksOnce(context.applicationContext)
        val webView = createWebView(MutableContextWrapper(context.applicationContext))
        // Kick off game discovery as soon as the warm hub has rendered, so games are
        // already prewarmed when the user first opens the hub.
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) {
                GamePreloader.onHubLoadFinished(view)
            }
        }
        webView.loadUrl(config.hubUrl)
        warmHubWebView = webView
    }

    internal fun obtainHubWebView(activity: Activity): WebView {
        warmHubWebView?.let { webView ->
            warmHubWebView = null
            (webView.context as MutableContextWrapper).baseContext = activity
            webView.onResume()
            return webView
        }
        return createWebView(MutableContextWrapper(activity))
    }

    internal fun stashHubWebView(webView: WebView) {
        val wrapper = webView.context as? MutableContextWrapper ?: run {
            webView.destroy()
            return
        }
        (webView.parent as? ViewGroup)?.removeView(webView)
        // Drop the activity-bound clients so the stashed WebView cannot leak the Activity.
        webView.webViewClient = WebViewClient()
        webView.webChromeClient = null
        wrapper.baseContext = wrapper.baseContext.applicationContext
        webView.onPause()
        warmHubWebView = webView
    }

    internal fun discardWarmHub() {
        warmHubWebView?.destroy()
        warmHubWebView = null
        GamePreloader.flush()
    }

    // Warm game webviews live in GamePreloader: games are preloaded from the hub's own
    // game list, and a played game is rebuilt fresh right after its sheet closes.

    @SuppressLint("SetJavaScriptEnabled")
    internal fun createWebView(wrapper: MutableContextWrapper): WebView {
        val webView = WebView(wrapper)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            javaScriptCanOpenWindowsAutomatically = true
            setSupportMultipleWindows(true)
        }
        // Placeholder client keeps redirects in place while detached; the hub activity
        // installs the UrlPolicy-aware clients when it attaches the WebView.
        webView.webViewClient = WebViewClient()
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }
        return webView
    }

    private fun registerTrimCallbacksOnce(appContext: Context) {
        if (trimCallbacksRegistered) return
        trimCallbacksRegistered = true
        appContext.registerComponentCallbacks(object : ComponentCallbacks2 {
            override fun onTrimMemory(level: Int) {
                if (level >= ComponentCallbacks2.TRIM_MEMORY_MODERATE) {
                    discardWarmHub()
                }
            }

            override fun onConfigurationChanged(newConfig: Configuration) {}

            @Deprecated("Deprecated in ComponentCallbacks")
            override fun onLowMemory() {
                discardWarmHub()
            }
        })
    }
}
