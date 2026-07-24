package com.fastory.sdk

import android.app.Activity
import android.content.Context
import android.content.MutableContextWrapper
import android.os.Handler
import android.os.Looper
import android.view.View
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONArray
import org.json.JSONTokener

/**
 * Preloads the hub's games into warm WebViews so tapping a tile presents an
 * already-rendered game, and rebuilds a fresh copy of a game right after it is played
 * so reopening is both instant and back on the start screen.
 *
 * How it works:
 * - When the hub finishes loading, the preloader reads the game list from the page's
 *   embedded SSR data (`__NEXT_DATA__`) with a read-only script — game URLs never appear
 *   in the DOM (tiles call `window.open` from JS), so this is the only reliable source.
 * - Games are loaded sequentially (one detached WebView at a time), never while a game
 *   sheet is presented, so preloading never competes with the hub or a live game.
 * - The first [LIVE_POOL_CAPACITY] games stay alive in the pool; the rest are loaded once
 *   and destroyed, which still warms WebView's disk cache and makes their cold open fast.
 * - The game the player closed last always outranks hub order: it is re-preloaded first
 *   and never evicted before untouched games.
 */
internal object GamePreloader {

    // 3 live game webviews keeps hub + host app headroom on low-end devices; 12 preloads
    // bounds background data usage on large hubs. Both flushed under memory pressure.
    private const val LIVE_POOL_CAPACITY = 3
    private const val MAX_PRELOAD_COUNT = 12
    private const val LOAD_TIMEOUT_MS = 30_000L

    private class CurrentLoad(val slug: String, val webView: WebView, val timeout: Runnable)

    private val handler = Handler(Looper.getMainLooper())

    /** Live prewarmed webviews keyed by game slug, never presented yet (fresh state). */
    private val pool = LinkedHashMap<String, WebView>()

    /** Games waiting for a background load (slug to load URL), most urgent first. */
    private val queue = ArrayDeque<Pair<String, String>>()

    /** Hub display order of the discovered games; drives pool eviction priority. */
    private var hubOrder: List<String> = emptyList()

    /** The game the player closed last — always the top preload priority. */
    private var lastClosedSlug: String? = null

    private var currentLoad: CurrentLoad? = null
    private var isGameSheetPresented = false
    private var appContext: Context? = null

    /** Seam for tests; production always performs the real load. */
    internal var loadStarter: (WebView, String) -> Unit = { webView, url -> webView.loadUrl(url) }

    // MARK: Hub hook

    /** Runs game discovery against a hub WebView that just finished a load. */
    fun onHubLoadFinished(hubWebView: WebView) {
        val config = Fastory.config ?: return
        if (appContext == null) {
            appContext = hubWebView.context.applicationContext
        }
        val script = discoveryScript(config.environment.storiesOrigin)
        hubWebView.evaluateJavascript(script) { result ->
            val games = parseDiscoveredGames(unquoteJsResult(result), config.baseUrl, MAX_PRELOAD_COUNT)
            schedule(games)
        }
    }

    // MARK: Game sheet hooks

    /**
     * Pool hit: hands the prewarmed WebView (loaded, or still loading — the sheet adopts
     * the in-flight navigation) to the game sheet, rebased on the activity. Miss: null.
     */
    fun takeWebView(activity: Activity, slug: String): WebView? {
        pool.remove(slug)?.let { return it.rebasedOn(activity) }
        val load = currentLoad
        if (load != null && load.slug == slug) {
            handler.removeCallbacks(load.timeout)
            currentLoad = null
            load.webView.webViewClient = WebViewClient()
            return load.webView.rebasedOn(activity)
        }
        return null
    }

    /** Suspends background loads while a game is being played. */
    fun gameSheetWillPresent() {
        isGameSheetPresented = true
    }

    /**
     * The played WebView is destroyed by the sheet; queue a fresh copy of that game ahead
     * of everything else so reopening it is instant and starts from a clean state.
     */
    fun gameSheetDidClose(slug: String, url: String?) {
        isGameSheetPresented = false
        if (slug.isNotEmpty() && !url.isNullOrEmpty()) {
            lastClosedSlug = slug
            queue.removeAll { it.first == slug }
            queue.addFirst(slug to url)
        }
        startNextLoadIfIdle()
    }

    /** Drops every warm game and pending load (memory pressure, re-configure). */
    fun flush() {
        currentLoad?.let { load ->
            handler.removeCallbacks(load.timeout)
            load.webView.stopLoading()
            load.webView.destroy()
        }
        currentLoad = null
        pool.values.forEach(WebView::destroy)
        pool.clear()
        queue.clear()
        hubOrder = emptyList()
        lastClosedSlug = null
    }

    // MARK: Discovery

    /**
     * Read-only query of the fanzone's SSR payload: visible Experience tiles and Crusher
     * blocks of the active tab. Mirrors the web's own URL construction
     * (`{storiesOrigin}/s/{slug}?utm_source=fanzone`) so preloads hit the exact URL a tap
     * would navigate to. Must stay read-only — the SDK never alters page behavior.
     */
    fun discoveryScript(storiesOrigin: String?): String {
        val origin = storiesOrigin.orEmpty()
        return """
        (function () {
          try {
            var data = window.__NEXT_DATA__;
            var fanzone = data && data.props && data.props.pageProps && data.props.pageProps.fanzoneData;
            if (!fanzone) return "[]";
            var tabSlug = new URLSearchParams(window.location.search).get("tab");
            var tabs = fanzone.tabs || [];
            var activeTabId = null;
            if (tabSlug && tabSlug !== "default") {
              for (var i = 0; i < tabs.length; i++) {
                if (tabs[i] && tabs[i].slug === tabSlug) { activeTabId = tabs[i].id; break; }
              }
            }
            var origin = "$origin" || window.location.origin;
            var urls = [];
            var seen = {};
            var push = function (slug) {
              var parts = String(slug).split("/").filter(Boolean);
              var normalized = parts.length ? parts[parts.length - 1] : null;
              if (!normalized || seen[normalized]) return;
              seen[normalized] = true;
              urls.push(origin + "/s/" + normalized + "?utm_source=fanzone");
            };
            var components = fanzone.components || [];
            for (var j = 0; j < components.length; j++) {
              var component = components[j];
              if (!component || component.isHidden) continue;
              var hiddenByTab = component.tabId == null
                ? activeTabId != null
                : component.tabId !== activeTabId;
              if (hiddenByTab) continue;
              if (component.type === "Experience") {
                var experiences = (component.settings && component.settings.experiences) || [];
                for (var k = 0; k < experiences.length; k++) {
                  var experience = experiences[k];
                  if (experience && experience.visible && experience.slug) push(experience.slug);
                }
              } else if (component.type === "Crusher" && component.settings && component.settings.slug) {
                push(component.settings.slug);
              }
            }
            return JSON.stringify(urls);
          } catch (error) {
            return "[]";
          }
        })()
        """.trimIndent()
    }

    /**
     * `evaluateJavascript` reports the script's string result as a JSON-encoded value
     * (quoted and escaped); unwrap it back to the raw JSON array text.
     */
    fun unquoteJsResult(raw: String?): String {
        if (raw.isNullOrEmpty() || raw == "null") return "[]"
        return runCatching { JSONTokener(raw).nextValue() as? String }.getOrNull() ?: "[]"
    }

    /**
     * Parses the discovery result and keeps only URLs UrlPolicy would open in the game
     * sheet, mapped to their load URL (embed/consent params added, like a real tap).
     */
    fun parseDiscoveredGames(json: String, baseUrl: String, limit: Int): List<Pair<String, String>> {
        val array = runCatching { JSONArray(json) }.getOrNull() ?: return emptyList()
        val games = mutableListOf<Pair<String, String>>()
        val seen = mutableSetOf<String>()
        for (index in 0 until array.length()) {
            if (games.size >= limit) break
            val url = array.optString(index).takeIf { it.isNotEmpty() } ?: continue
            if (UrlPolicy.decide(url, baseUrl) != NavigationDecision.OPEN_GAME_SHEET) continue
            val slug = UrlPolicy.gameSlug(url) ?: continue
            if (!seen.add(slug)) continue
            games.add(slug to UrlPolicy.embeddedGameUrl(url))
        }
        return games
    }

    // MARK: Sequential loading

    private fun schedule(games: List<Pair<String, String>>) {
        if (games.isEmpty()) return
        hubOrder = games.map { it.first }
        queue.clear()
        games.filterTo(queue) { !pool.containsKey(it.first) && it.first != currentLoad?.slug }
        lastClosedSlug?.let { last ->
            val index = queue.indexOfFirst { it.first == last }
            if (index > 0) {
                queue.addFirst(queue.removeAt(index))
            }
        }
        startNextLoadIfIdle()
    }

    private fun startNextLoadIfIdle() {
        val context = appContext ?: return
        if (currentLoad != null || isGameSheetPresented || queue.isEmpty()) return
        val (slug, url) = queue.removeFirst()
        if (pool.containsKey(slug)) {
            startNextLoadIfIdle()
            return
        }
        val webView = Fastory.createWebView(MutableContextWrapper(context))
        sizeToDisplay(webView, context)
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) {
                finishCurrentLoad(view, success = true)
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) {
                    finishCurrentLoad(view, success = false)
                }
            }
        }
        val timeout = Runnable {
            currentLoad?.let { if (it.webView == webView) finishCurrentLoad(webView, success = false) }
        }
        currentLoad = CurrentLoad(slug, webView, timeout)
        handler.postDelayed(timeout, LOAD_TIMEOUT_MS)
        loadStarter(webView, url)
    }

    private fun finishCurrentLoad(webView: WebView, success: Boolean) {
        val load = currentLoad ?: return
        if (load.webView != webView) return
        handler.removeCallbacks(load.timeout)
        currentLoad = null
        // Placeholder client keeps any late redirects in place while the WebView is pooled.
        webView.webViewClient = WebViewClient()
        if (success) {
            insertIntoPool(load.slug, webView)
        } else {
            webView.stopLoading()
            webView.destroy()
        }
        startNextLoadIfIdle()
    }

    /**
     * Keeps the WebView live when the pool has room or the new game outranks a pooled one;
     * otherwise destroys it — the load still warmed WebView's disk cache.
     */
    private fun insertIntoPool(slug: String, webView: WebView) {
        if (pool.size < LIVE_POOL_CAPACITY) {
            pool[slug] = webView
            return
        }
        val evictable = pool.keys.maxByOrNull { rank(it) }
        if (evictable == null || rank(evictable) <= rank(slug)) {
            webView.destroy()
            return
        }
        pool.remove(evictable)?.destroy()
        pool[slug] = webView
    }

    /** Lower is more valuable: last-closed game first, then hub display order. */
    private fun rank(slug: String): Int {
        if (slug == lastClosedSlug) return -1
        val index = hubOrder.indexOf(slug)
        return if (index == -1) Int.MAX_VALUE else index
    }

    private fun WebView.rebasedOn(activity: Activity): WebView {
        (context as? MutableContextWrapper)?.baseContext = activity
        return this
    }

    /** Detached WebViews otherwise measure 0×0, which canvas-based games mis-initialize on. */
    private fun sizeToDisplay(webView: WebView, context: Context) {
        val metrics = context.resources.displayMetrics
        webView.measure(
            View.MeasureSpec.makeMeasureSpec(metrics.widthPixels, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(metrics.heightPixels, View.MeasureSpec.EXACTLY),
        )
        webView.layout(0, 0, metrics.widthPixels, metrics.heightPixels)
    }
}
