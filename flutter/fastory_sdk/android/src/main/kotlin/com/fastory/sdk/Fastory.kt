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
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
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
     * the host called from. It is never reset — a counter that went backwards would let a stale
     * decision match a future launch, which is the whole thing it prevents.
     */
    @Volatile
    private var hubLaunch = 0

    /**
     * A presentation whose Activity the platform destroyed without dismissing it, and whether the
     * host has heard its `hubOpened` — and the `gameOpened` of a game sheet torn down with it. The
     * fan never saw the hub leave, so it stays reserved and nothing is emitted; the instance the
     * platform rebuilds resumes it, a [close] arriving before that instance exists ends it here, and
     * an [openGames] meanwhile asks for it again (SPEC § 5.3). A record that leaves its task with no
     * callback is only noticed by the next [openGames] or [close], which is when its `hubClosed` goes
     * out.
     */
    private var suspendedHub: SuspendedHub? = null

    private class SuspendedHub(val launch: Int, val opened: Boolean) {
        var gameOpened = false
    }

    private const val LOST_LAUNCH_TIMEOUT_MS = 10_000L

    private var identityGeneration = 0

    fun configure(context: Context, config: FastoryConfig, listener: FastoryEventsListener? = null) {
        val appContext = context.applicationContext
        WorkspaceResolver.applicationId = appContext.packageName
        applyConfiguration(config, listener) {
            registerTrimCallbacksOnce(appContext)
            warmUpHubOnceTheHostIsOnScreen(appContext)
        }
    }

    @Deprecated(
        "Configure with a Context: Fastory.configure(context, config, listener). The context-less " +
            "form keeps working for the whole 0.x window; it will be removed in 1.0.",
    )
    fun configure(config: FastoryConfig, listener: FastoryEventsListener? = null) {
        applyConfiguration(config, listener, prepare = null)
    }

    private fun applyConfiguration(
        config: FastoryConfig,
        listener: FastoryEventsListener?,
        prepare: (() -> Unit)?,
    ) {
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
            prepare?.invoke()
        }
    }

    /**
     * The fan asked again from the error view (SPEC § 9). Kept apart from [resolveHub] so that only
     * this caller can discard a remembered failure — [WorkspaceResolver.rearmAfterFailure] carries
     * why that separation matters. A no-op on the deprecated slug path, where nothing is exchanged.
     */
    internal fun retryHubResolution() {
        WorkspaceResolver.rearmAfterFailure()
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
        if (hubIsPresentedOrLaunching && suspendedHub == null) return
        WorkspaceResolver.applicationId = context.applicationContext.packageName
        WorkspaceResolver.resolve(config)
        val intent = Intent(context, FastoryHubActivity::class.java)
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (suspendedHub != null) {
            // The destroyed hub may never come back on its own — its record can leave the task with
            // no callback — so this asks for it rather than doing nothing. Still on top of its task,
            // singleTop rebuilds that record and it resumes its presentation; gone, a new instance
            // arrives with no saved state and claimHubPresentation ends the lost one first.
            context.startActivity(intent)
            return
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
            if (hubLaunch != launch || !hubIsPresentedOrLaunching || hubRef?.get() != null ||
                suspendedHub != null
            ) {
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
                // Destroyed by the platform and not rebuilt yet: there is no Activity to finish,
                // and the record that comes back will find its presentation over.
                suspendedHub?.launch == launch -> endSuspendedHubPresentation()
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
        identityGeneration++
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
     * already asked to close never renders. Returns null when [close] arrived during the launch,
     * which is the Activity's cue to finish itself; otherwise the launch this presentation answers
     * for, which the Activity hands back to [releaseHubPresentation] when it is over.
     *
     * A hub the platform rebuilds does not come through here: it carries the launch it continues
     * and goes through [resumeHubPresentation], since the reservation never left it.
     *
     * [hubRef] is taken here rather than at [notifyHubOpened] because a hub configured by key spends
     * the whole `/sdk/auth/bootstrap` round trip on screen before it opens — a `close()` in that
     * window used to find nothing to finish.
     */
    internal fun claimHubPresentation(activity: Activity): Int? {
        // A hub arriving with no saved state while another was suspended: the platform dropped the
        // record that would have resumed it, so that presentation is over before this one begins —
        // and gets a launch of its own, so a close() aimed at the lost one cannot reach it.
        if (suspendedHub != null) {
            endSuspendedHubPresentation()
            ++hubLaunch
        }
        if (hubCloseRequestedWhileLaunching) {
            hubCloseRequestedWhileLaunching = false
            hubIsPresentedOrLaunching = false
            return null
        }
        hubIsPresentedOrLaunching = true
        hubRef = WeakReference(activity)
        return hubLaunch
    }

    /**
     * Frees the slot [claimHubPresentation] took, so the next [openGames] is not a silent no-op.
     *
     * Keyed on the launch, not on the Activity. The hub gives its slot back the moment it is
     * dismissed, while the platform destroys it on its own schedule — seconds later when the host
     * beneath is slow to settle — and in between the fan may have asked for, and got, the next hub.
     * A release matched on the Activity instance could not tell that late destruction from the live
     * hub's own; one matched on the launch ignores it, because [openGames] has moved the counter on.
     */
    internal fun releaseHubPresentation(presentation: Int) {
        if (presentation != hubLaunch) return
        hubRef = null
        hubIsPresentedOrLaunching = false
    }

    internal fun suspendHubPresentation(presentation: Int, opened: Boolean) {
        if (presentation != hubLaunch) return
        hubRef = null
        suspendedHub = SuspendedHub(presentation, opened)
    }

    /**
     * A game sheet whose `gameOpened` the host has heard, torn down with a hub the platform is
     * rebuilding: its `gameClosed` is owed by that presentation now — the sheet restored with the hub
     * takes it back, anything that ends the presentation first emits it, ahead of `hubClosed`. False
     * when no presentation is suspended, and the sheet emits it itself.
     */
    internal fun suspendGamePresentation(): Boolean {
        val suspended = suspendedHub ?: return false
        suspended.gameOpened = true
        return true
    }

    /**
     * Hands a rebuilt hub the presentation its predecessor left: whether the host has already heard
     * it open, or null when that presentation is over and the instance must finish without a word.
     */
    internal fun resumeHubPresentation(activity: Activity, presentation: Int): Boolean? {
        val suspended = suspendedHub
        if (suspended == null || suspended.launch != presentation || presentation != hubLaunch) {
            return null
        }
        suspendedHub = null
        hubRef = WeakReference(activity)
        return suspended.opened
    }

    private fun endSuspendedHubPresentation() {
        val suspended = suspendedHub ?: return
        suspendedHub = null
        if (suspended.gameOpened) notifyGameClosed()
        if (suspended.opened) {
            notifyHubClosed(suspended.launch)
        } else {
            releaseHubPresentation(suspended.launch)
        }
    }

    /// [fanzoneSlug] is the resolved one: configured by key, it is only known once the API answers.
    internal fun notifyHubOpened(activity: Activity, fanzoneSlug: String) {
        hubRef = WeakReference(activity)
        listener?.onHubOpened(fanzoneSlug)
    }

    internal fun notifyHubClosed(presentation: Int) {
        releaseHubPresentation(presentation)
        listener?.onHubClosed()
    }

    internal fun resetHubPresentationForTesting() {
        hubRef = null
        suspendedHub = null
        hubIsPresentedOrLaunching = false
        hubCloseRequestedWhileLaunching = false
    }

    internal fun resetForTesting() {
        config = null
        listener = null
        identity = null
        identityGeneration = 0
        discardWarmHub()
        failedWarmHubWebViews.clear()
        resetHubPresentationForTesting()
        hostIsOnScreen = DEFAULT_HOST_IS_ON_SCREEN
        whenHostComesOnScreen = DEFAULT_WHEN_HOST_COMES_ON_SCREEN
        hostObserverArmed = false
        WorkspaceResolver.reset()
        WorkspaceResolver.performRequest = WorkspaceResolver.DEFAULT_PERFORM_REQUEST
        WorkspaceResolver.applicationId = null
        FastoryBridgeResponder.revokeAll()
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

    private var warmHubLoadStarted = false
    private var warmHubDidCommit = false

    private val failedWarmHubWebViews = mutableListOf<WebView>()
    private var trimCallbacksRegistered = false

    internal data class WarmHub(val webView: WebView, val hasCommitted: Boolean, val isLoading: Boolean)

    private val DEFAULT_HOST_IS_ON_SCREEN: () -> Boolean = {
        ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
    }

    private val DEFAULT_WHEN_HOST_COMES_ON_SCREEN: (() -> Unit) -> Unit = { callback ->
        val lifecycle = ProcessLifecycleOwner.get().lifecycle
        lifecycle.addObserver(object : LifecycleEventObserver {
            override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
                if (event != Lifecycle.Event.ON_START) return
                lifecycle.removeObserver(this)
                callback()
            }
        })
    }

    internal var hostIsOnScreen: () -> Boolean = DEFAULT_HOST_IS_ON_SCREEN

    internal var whenHostComesOnScreen: (() -> Unit) -> Unit = DEFAULT_WHEN_HOST_COMES_ON_SCREEN

    private var hostObserverArmed = false

    private fun warmUpHubOnceTheHostIsOnScreen(appContext: Context) {
        if (hostIsOnScreen()) {
            preloadHub(appContext)
            return
        }
        if (hostObserverArmed) return
        hostObserverArmed = true
        whenHostComesOnScreen {
            if (!hostObserverArmed) return@whenHostComesOnScreen
            hostObserverArmed = false
            preloadHub(appContext)
        }
    }

    internal fun preloadHub(context: Context) {
        val config = config ?: return
        if (hubIsPresentedOrLaunching || hubRef?.get() != null || warmHubWebView != null) return
        val appContext = context.applicationContext
        config.staticHubUrl?.let { hubUrl ->
            prepareWarmHub(appContext, hubUrl, config)
            return
        }
        val generation = identityGeneration
        WorkspaceResolver.whenResolved(config) { outcome ->
            val workspace = (outcome as? WorkspaceResolver.Outcome.Success)?.workspace
                ?: return@whenResolved
            warmUpHub(appContext, config.hubUrl(workspace.slug), config, generation)
        }
    }

    private fun warmUpHub(appContext: Context, hubUrl: String, config: FastoryConfig, generation: Int) {
        if (config != Fastory.config ||
            hubIsPresentedOrLaunching || hubRef?.get() != null ||
            warmHubWebView != null ||
            generation != identityGeneration
        ) {
            return
        }
        if (!hostIsOnScreen()) {
            warmUpHubOnceTheHostIsOnScreen(appContext)
            return
        }
        prepareWarmHub(appContext, hubUrl, config)
    }

    private fun prepareWarmHub(appContext: Context, hubUrl: String, config: FastoryConfig) {
        warmHubConfig = config
        val webView = createWebView(MutableContextWrapper(appContext))
        // Kicks off game discovery as soon as the warm hub has rendered, and drops the page when the
        // warm-up failed (SPEC § 9.1).
        webView.webViewClient = FastoryWarmUpClient()
        warmHubWebView = webView
        warmHubLoadStarted = true
        warmHubDidCommit = false
        webView.loadUrl(hubUrl)
    }

    internal fun obtainHubWebView(activity: Activity): WarmHub {
        // Nothing warm is not a mismatch. Discarding on an empty slot would flush the preloader on
        // every cold open, throwing away the games discovered from the very hub that is opening —
        // this runs on presentation, when the slot has just been emptied or was never filled.
        if (warmHubWebView != null && warmHubConfig != config) {
            // Rendered for another configuration: presenting it under the current one is the
            // whole defect, so it is dropped rather than handed over (SPEC § 2.1).
            discardWarmHub()
        }
        warmHubWebView?.let { webView ->
            val hasCommitted = warmHubDidCommit
            val isLoading = warmHubLoadStarted && !warmHubDidCommit
            warmHubWebView = null
            warmHubConfig = null
            warmHubLoadStarted = false
            warmHubDidCommit = false
            (webView.context as MutableContextWrapper).baseContext = activity
            webView.onResume()
            return WarmHub(webView, hasCommitted = hasCommitted, isLoading = isLoading)
        }
        return WarmHub(
            createWebView(MutableContextWrapper(activity)),
            hasCommitted = false,
            isLoading = false,
        )
    }

    /**
     * [presentation] is the launch the page was presented for. A hub is destroyed on the platform's
     * schedule, possibly after the fan has asked for — and got — the next one, and a page that late
     * must not enter the slot: it would replace what the newer hub put there, or be handed to the
     * one after it in place of a fresher page.
     */
    internal fun stashHubWebView(
        webView: WebView,
        config: FastoryConfig,
        presentation: Int,
        hasCommitted: Boolean,
    ) {
        if (presentation != hubLaunch) {
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView.destroy()
            return
        }
        stashHubWebView(webView, config, hasCommitted)
    }

    /**
     * [config] is the one the page was **loaded** under, which the caller holds and the SDK may no
     * longer have: an Activity destroyed after a re-configure is exactly the case this parameter
     * exists for, and reading [Fastory.config] here would bless the stale page instead of catching it.
     */
    internal fun stashHubWebView(webView: WebView, config: FastoryConfig, hasCommitted: Boolean) {
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
        warmHubLoadStarted = hasCommitted
        warmHubDidCommit = hasCommitted
    }

    internal fun discardWarmHub() {
        warmHubWebView?.destroy()
        emptyWarmHubSlot()
    }

    internal fun warmHubPageDidFail(webView: WebView) {
        if (warmHubWebView !== webView) return
        emptyWarmHubSlot()
        failedWarmHubWebViews.add(webView)
    }

    internal fun releaseFailedWarmHubWebView(webView: WebView) {
        if (failedWarmHubWebViews.remove(webView)) webView.destroy()
    }

    internal fun warmHubPageDidCommit(webView: WebView) {
        if (warmHubWebView !== webView) return
        warmHubDidCommit = true
    }

    private fun emptyWarmHubSlot() {
        warmHubWebView = null
        warmHubConfig = null
        warmHubLoadStarted = false
        warmHubDidCommit = false
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
