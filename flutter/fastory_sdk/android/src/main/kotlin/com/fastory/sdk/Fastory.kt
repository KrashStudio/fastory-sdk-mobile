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
import android.os.Handler
import android.os.Looper
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

    /**
     * A bridge message the web surface posted through the versioned envelope (SPEC §13). Only types
     * in the SDK's registry reach here; everything else is dropped.
     */
    fun onBridgeMessage(type: String, payload: Map<String, Any?>) {}

    fun onIdentityResolved(identity: FastoryResolvedIdentity) {}

    /**
     * A hub or a game that did not load (SPEC § 9.1). The host is the only party that can decide
     * what to do about it — log it, alert its team, offer the fan something else — so the SDK
     * reports and never retries on its own.
     */
    fun onSurfaceLoadFailed(failure: FastoryLoadFailure) {}
}

object Fastory {

    @Volatile
    internal var config: FastoryConfig? = null
        private set

    @Volatile
    private var listener: FastoryEventsListener? = null

    /**
     * The identity the SDK currently carries: null until the first successful [identify], and again
     * after [logout].
     */
    @Volatile
    var identity: FastoryResolvedIdentity? = null
        private set

    /**
     * Only ever read and written on the UI thread — from [configure]'s hop, from [openGames] and the
     * hop in [close], from the hub activity, and from the trim callbacks, which register on the main
     * looper. That confinement is why these are not `@Volatile` while [config] and [identity] are:
     * those two are written from whatever thread the host called [configure] on (SPEC § 2.7), these
     * are not written off it at all.
     *
     * [openGames] is the one writer that does not hop, and it does not need to: it is the single
     * method SPEC § 2.7 keeps main-thread-only, because it takes the host's own UI object. [close]
     * may be called from anywhere and writes only inside its hop — [hubLaunch] is the one field it
     * reads outside, and that one is `@Volatile`.
     */
    private var hubRef: WeakReference<Activity>? = null

    /**
     * Whether a hub is on screen **or on its way to it**.
     *
     * iOS presents synchronously and guards [openGames] on the view controller itself, so the
     * object it holds is the answer. `startActivity()` returns long before the Activity exists, so
     * [hubRef] answers "no hub" for the whole launch window — and that window is exactly where a
     * double tap lands. Reserving the hub at the *request* rather than at the arrival is what makes
     * the guarantee the same on both platforms (SPEC § 2.1).
     */
    private var hubIsPresentedOrLaunching = false

    /**
     * A [close] that arrived while the hub was still launching. There is no Activity to finish yet,
     * so the one on its way reads this in [claimHubPresentation] and finishes itself — otherwise a
     * hub the host asked to be rid of appears a frame after the request.
     */
    private var hubCloseRequestedWhileLaunching = false

    /**
     * Which launch the current reservation belongs to, bumped by every [openGames] that takes one.
     *
     * It exists so a decision taken about one hub cannot land on the next. [close] is callable from
     * any thread and therefore hops, and in the turns it waits the hub it meant to close can be
     * destroyed and another launch started — without this, that stale request would withdraw the
     * *new* launch and the fan's tap would silently open nothing. The lost-launch watchdog reads it
     * for the same reason, in the other direction.
     *
     * The one hub field that is `@Volatile`: [close] reads it before its hop, off whatever thread
     * the host called from. It is never reset, test seam included — a counter that went backwards
     * would let a stale decision match a future launch, which is the whole thing it prevents.
     */
    @Volatile
    private var hubLaunch = 0

    private const val LOST_LAUNCH_TIMEOUT_MS = 10_000L

    /**
     * Callable from any thread (SPEC § 2.7), and it returns without doing the work that would make
     * that a lie: the configuration is stored on the calling thread, and the work Android restricts
     * to the UI thread is hopped there.
     *
     * The order matters and is not cosmetic. Storing the configuration synchronously is what keeps
     * `configure(); openGames()` legal — `openGames` throws on a null configuration, so a deferred
     * store would turn a correct sequence into a crash. Revoking the standing bridge answer
     * synchronously is what keeps § 13.8.6 airtight: deferred, it would leave a window in which the
     * previous configuration's credential is still handed out.
     */
    fun configure(config: FastoryConfig, listener: FastoryEventsListener? = null) {
        val previous = this.config
        val configChanged = previous != config
        this.config = config
        this.listener = listener
        // A configure that *replaces* a configuration invalidates what the previous one justified:
        // the standing bridge answer was minted for its environment and its workspace, so serving it
        // under the next one hands a production token to a staging page (SPEC § 13.8.6). Nothing to
        // invalidate on the first call — and a host may legitimately set the answer before
        // configuring, so revoking there would drop a value it never got to use.
        if (previous != null && configChanged) {
            FastoryBridgeResponder.revokeAll()
        }
        // On the UI thread, all of it. discardWarmHub() calls WebView.destroy() and flushes the
        // preloader, which Android answers with `A WebView method was called on thread …` off the UI
        // thread; and the resolver's waiter list is mutated here and again from its own callback,
        // which lands on the main looper. Confining both to one thread is the synchronisation.
        onMainThread {
            // Discarding before preparing anything new is SPEC § 2.1: the warm hub renders the
            // previous fanzone, so keeping it makes the next openGames() present the old
            // configuration's page under the new one. This is the half iOS did not have until
            // 0.4.0 — wider than the revocation above only because it is a no-op on the first
            // configure.
            if (configChanged) {
                discardWarmHub()
                WorkspaceResolver.reset()
            }
            // Configured by key, the fanzone to open is only known once the API answers. Start the
            // exchange now so openGames() usually finds it already resolved.
            WorkspaceResolver.resolve(config)
        }
    }

    /**
     * Resolves the hub URL and the fanzone slug — [FastoryEventsListener.onHubOpened] carries it.
     * Immediate on the deprecated slug path; on the publishable key path it waits for
     * `/sdk/auth/bootstrap`, which [configure] already started.
     */
    internal fun resolveHub(callback: (Result<Pair<String, String>>) -> Unit) {
        val config = config
        if (config == null) {
            callback(Result.failure(IllegalStateException("not configured")))
            return
        }
        config.staticHubUrl?.let { url ->
            @Suppress("DEPRECATION")
            callback(Result.success(url to config.fanzoneSlug!!))
            return
        }
        WorkspaceResolver.whenResolved(config) { outcome ->
            when (outcome) {
                is WorkspaceResolver.Outcome.Success ->
                    callback(
                        Result.success(
                            config.hubUrl(outcome.workspace.slug) to outcome.workspace.slug
                        )
                    )
                is WorkspaceResolver.Outcome.Failure ->
                    callback(Result.failure(FastoryBootstrapException(outcome.code)))
            }
        }
    }

    /**
     * The one method that MUST be called on the UI thread (SPEC § 2.7), and the only one that can say
     * so honestly: it takes the host's own [Context] to start an Activity from, so a caller holding
     * one is already in UI code.
     */
    fun openGames(context: Context) {
        val config = checkNotNull(config) { "Fastory.configure() must be called before openGames()" }
        // Idempotent, as on iOS: asking for the games while a hub is already up — or already on its
        // way up — does nothing at all. Without it a double tap on the host's own tab bar stacks two
        // Activities, close() finishes only the one on top, and the page each stashes on its way out
        // overwrites the other in the warm slot.
        if (hubIsPresentedOrLaunching) return
        // The key only bootstraps for the applications it was created with. configure() has no
        // Context on the standalone SDK, so this is the first point where the package name is
        // available — the hub activity's resolveHub() then starts the exchange.
        WorkspaceResolver.applicationId = context.applicationContext.packageName
        WorkspaceResolver.resolve(config)
        val intent = Intent(context, FastoryHubActivity::class.java)
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        hubIsPresentedOrLaunching = true
        val launch = ++hubLaunch
        try {
            context.startActivity(intent)
        } catch (error: RuntimeException) {
            // A reservation outliving a launch that never happened would turn every later
            // openGames() into a silent no-op — a worse failure than the one being reported.
            hubIsPresentedOrLaunching = false
            throw error
        }
        releaseTheReservationIfTheLaunchIsLost(launch)
    }

    /**
     * Gives the reservation back when the Activity never arrives.
     *
     * `startActivity` is not a promise and the `catch` above cannot make it one: since Android 10 a
     * start from the background is refused with a logcat line and **no exception**, and this entry
     * point takes a plain [Context] precisely so a native host can call it from one. Left alone that
     * reservation outlives a launch that never happened, and every later `openGames()` is a silent
     * no-op for the life of the process — a worse failure than the stacking the reservation exists
     * to prevent, and an unrecoverable one, since only an Activity that was created can release it.
     *
     * The window is deliberately far longer than any launch: an Activity that has not reached
     * `onCreate` in ten seconds is not coming, while the double tap this all exists for lands three
     * orders of magnitude inside it. [hubLaunch] is what keeps a late watchdog off a hub that is
     * genuinely up — it only ever frees the launch it was armed for.
     */
    private fun releaseTheReservationIfTheLaunchIsLost(launch: Int) {
        Handler(Looper.getMainLooper()).postDelayed({
            if (hubLaunch != launch || !hubIsPresentedOrLaunching || hubRef?.get() != null) {
                return@postDelayed
            }
            hubIsPresentedOrLaunching = false
            hubCloseRequestedWhileLaunching = false
        }, LOST_LAUNCH_TIMEOUT_MS)
    }

    fun close() {
        // Read before the hop, on the caller's own thread: by the time the block below runs, the hub
        // this call was aimed at may already be gone and another one launching. Withdrawing that one
        // would turn a stale close() into a tap that opens nothing.
        val launch = hubLaunch
        // Callable from any thread, unlike `openGames`: a host closing the hub is often doing it from
        // a callback it does not control the thread of, and the hub state is UI-thread-confined.
        onMainThread {
            val hub = hubRef?.get()
            when {
                hub != null -> hub.finish()
                // Nothing to finish yet: the Activity is still on its way. Swallowing the request
                // here is how a hub ends up appearing after the host asked for it to be gone — but
                // only for the launch this call was actually aimed at.
                hubIsPresentedOrLaunching && hubLaunch == launch ->
                    hubCloseRequestedWhileLaunching = true
            }
        }
    }

    /**
     * Binds the host app's user to a Fastory fan. See `SPEC.md` § 2.6.
     *
     * Non-blocking: every outcome arrives in [callback], on the main thread. Only
     * [FastoryIdentity.Anonymous] resolves in this version; the two identified modes are reserved
     * signatures that fail with `identify_mode_unavailable`.
     *
     * Called before [configure] it throws the same [IllegalStateException] as [openGames], not a
     * new error shape.
     */
    fun identify(
        identity: FastoryIdentity,
        callback: ((Result<FastoryResolvedIdentity>) -> Unit)? = null,
    ) {
        checkNotNull(config) { "Fastory.configure() must be called before identify()" }
        onMainThread {
            val config = Fastory.config ?: return@onMainThread
            val transition = FastoryIdentityRules.transition(identity, Fastory.identity)
            val errorCode = transition.errorCode
            if (errorCode != null) {
                callback?.invoke(Result.failure(FastoryIdentifyException(errorCode)))
                return@onMainThread
            }
            val resolved = transition.resolved ?: return@onMainThread
            applyTransition(transition, config)
            // Set before notifying, so a listener reading Fastory.identity sees the new fan.
            Fastory.identity = resolved
            if (transition.emitsIdentityResolved) {
                listener?.onIdentityResolved(resolved)
            }
            callback?.invoke(Result.success(resolved))
        }
    }

    /**
     * Signs the fan out of Fastory only — the host application's own session is never touched.
     * Idempotent, and needs no network call.
     */
    fun logout(callback: (() -> Unit)? = null) {
        onMainThread {
            val transition = FastoryIdentityRules.logout(Fastory.identity)
            // Not `config?.let`: an unconfigured SDK still has a standing answer to revoke, and
            // gating the whole transition on a configuration is what let logout() keep it.
            applyTransition(transition, config)
            Fastory.identity = null
            callback?.invoke()
        }
    }

    private fun applyTransition(transition: FastoryIdentityTransition, config: FastoryConfig?) {
        // Before the erasure and outside its guard: revocation needs no configuration and no store,
        // and `logout()` revokes even when it has no session to erase (SPEC § 13.8.2).
        if (transition.revokesBridgeReplies) {
            FastoryBridgeResponder.revokeAll()
        }
        if (!transition.erasesStorage || config == null) return
        // Both were built before this transition, so they hold the previous fan's rendered page.
        discardWarmHub()
        FastoryWebsiteDataEraser.erase(FastoryIdentityStorage.origins(config))
    }

    private fun onMainThread(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            Handler(Looper.getMainLooper()).post(block)
        }
    }

    /**
     * Called by the hub Activity as it is created, before it builds anything — so a hub the host has
     * already asked to close never renders. Returns false when [close] arrived during the launch,
     * which is the Activity's cue to finish itself.
     *
     * It is also what re-arms the reservation across a system-driven recreation: the outgoing
     * instance releases it on its way out, and the incoming one is the same hub, still on screen.
     *
     * [hubRef] is taken here rather than at [notifyHubOpened] because a hub configured by key spends
     * the whole `/sdk/auth/bootstrap` round trip on screen before it opens — a `close()` in that
     * window used to find nothing to finish.
     */
    internal fun claimHubPresentation(activity: Activity): Boolean {
        if (hubCloseRequestedWhileLaunching) {
            hubCloseRequestedWhileLaunching = false
            hubIsPresentedOrLaunching = false
            return false
        }
        hubIsPresentedOrLaunching = true
        hubRef = WeakReference(activity)
        return true
    }

    /** Frees the slot [claimHubPresentation] took, so the next [openGames] is not a silent no-op. */
    internal fun releaseHubPresentation(activity: Activity) {
        if (hubRef?.get() !== activity) return
        hubRef = null
        hubIsPresentedOrLaunching = false
    }

    /// [fanzoneSlug] is the resolved one: configured by key, it is only known once the API answers.
    internal fun notifyHubOpened(activity: Activity, fanzoneSlug: String) {
        hubRef = WeakReference(activity)
        listener?.onHubOpened(fanzoneSlug)
    }

    internal fun notifyHubClosed(activity: Activity) {
        releaseHubPresentation(activity)
        listener?.onHubClosed()
    }

    /**
     * Hands the next case a hub-free SDK. This object is process-wide and the public contract has no
     * way to withdraw a presentation — deliberately — so a case that left a reservation behind would
     * make every later `openGames()` a silent no-op. iOS's `resetForTesting` exists for this reason.
     */
    internal fun resetHubPresentationForTesting() {
        hubRef = null
        hubIsPresentedOrLaunching = false
        hubCloseRequestedWhileLaunching = false
    }

    internal fun notifyGameOpened(slug: String) {
        listener?.onGameOpened(slug)
    }

    internal fun notifyGameClosed() {
        listener?.onGameClosed()
    }

    internal fun notifyBridgeMessage(type: String, payload: Map<String, Any?>) {
        listener?.onBridgeMessage(type, payload)
    }

    internal fun notifySurfaceLoadFailed(failure: FastoryLoadFailure) {
        listener?.onSurfaceLoadFailed(failure)
    }

    /**
     * What the SDK answers the next time a web surface asks for [type] over the bridge (SPEC §13.8) —
     * the fan token a game requests from its host page, in the place of the host page it does not have.
     *
     * Standing rather than resolved on demand: the game asks while it boots, so an answer that had to
     * be fetched would stall its first paint, and §13.5 forbids network or disk on this path anyway.
     * Set it before opening a game; null clears it, and a cleared type is answered with an explicit
     * failure rather than with silence.
     *
     * A payload that cannot be encoded as JSON is refused and the current answer left as it was —
     * non-throwing, and traced at debug level.
     */
    fun setBridgeReply(type: FastoryBridgeRequestType, payload: Map<String, Any?>?) {
        FastoryBridgeResponder.setReply(type, payload)
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

    // All three UI-thread-confined, like `hubRef` above and for the same reason.
    private var warmHubWebView: WebView? = null

    /**
     * The configuration [warmHubWebView]'s page was loaded under — never the current one.
     *
     * A teardown at [configure] time cannot be enough on its own: the hub can be **re-stashed after
     * it ran**, by an Activity destroyed after a re-configure, and it comes back holding the previous
     * fanzone. The stamp is what makes the check total — a page is reusable only for the
     * configuration it was rendered for, whenever it was put there.
     */
    private var warmHubConfig: FastoryConfig? = null
    private var trimCallbacksRegistered = false

    internal fun preloadHub(context: Context) {
        val config = config ?: return
        WorkspaceResolver.applicationId = context.applicationContext.packageName
        WorkspaceResolver.resolve(config)
        if (hubRef?.get() != null || warmHubWebView != null) return
        // Only the slug path can warm up synchronously. On the key path the hub activity resolves
        // and loads on presentation — warming a webview for an unknown URL is pointless.
        val hubUrl = config.staticHubUrl ?: return
        registerTrimCallbacksOnce(context.applicationContext)
        warmHubConfig = config
        val webView = createWebView(MutableContextWrapper(context.applicationContext))
        // Kicks off game discovery as soon as the warm hub has rendered, and drops the page when the
        // warm-up failed (SPEC § 9.1).
        webView.webViewClient = FastoryWarmUpClient()
        webView.loadUrl(hubUrl)
        warmHubWebView = webView
    }

    internal fun obtainHubWebView(activity: Activity): WebView {
        // Nothing warm is not a mismatch. Discarding on an empty slot would flush the preloader on
        // every cold open, throwing away the games discovered from the very hub that is opening —
        // this runs on presentation, when the slot has just been emptied or was never filled.
        if (warmHubWebView != null && warmHubConfig != config) {
            // Rendered for another configuration: presenting it under the current one is the
            // whole defect, so it is dropped rather than handed over (SPEC § 2.1).
            discardWarmHub()
        }
        warmHubWebView?.let { webView ->
            warmHubWebView = null
            warmHubConfig = null
            (webView.context as MutableContextWrapper).baseContext = activity
            webView.onResume()
            return webView
        }
        return createWebView(MutableContextWrapper(activity))
    }

    /**
     * [config] is the one the page was **loaded** under, which the caller holds and the SDK may no
     * longer have: an Activity destroyed after a re-configure is exactly the case this parameter
     * exists for, and reading [Fastory.config] here would bless the stale page instead of catching it.
     */
    internal fun stashHubWebView(webView: WebView, config: FastoryConfig) {
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
        // A page pushed out of the slot is unreachable the instant the field moves, and it keeps its
        // renderer process alive until destroy() — Swift's ARC releases the iOS equivalent for free,
        // which is why only this platform has ever leaked one here.
        if (warmHubWebView !== webView) warmHubWebView?.destroy()
        warmHubWebView = webView
        warmHubConfig = config
    }

    internal fun discardWarmHub() {
        warmHubWebView?.destroy()
        warmHubWebView = null
        warmHubConfig = null
        GamePreloader.flush()
    }

    /**
     * A looper turn later, because [discardWarmHub] calls `WebView.destroy()` and this is reached
     * from inside that WebView's own client — destroying it there is what Android's own
     * documentation forbids. And only if the slot still holds [webView]: a presentation can take the
     * page inside that turn, and discarding then would destroy a WebView the hub is about to attach
     * and flush the games discovered for it.
     */
    internal fun discardWarmHubLater(webView: WebView) {
        Handler(Looper.getMainLooper()).post {
            if (warmHubWebView === webView) discardWarmHub()
        }
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
        // Every SDK WebView speaks the bridge — hub, game sheet and preloaded games alike, since
        // all three are built here. Receive-only: it adds a channel, it changes no navigation.
        FastoryBridge.attach(webView)
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
