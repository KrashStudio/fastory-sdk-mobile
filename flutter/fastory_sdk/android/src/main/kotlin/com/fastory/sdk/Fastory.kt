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
import java.net.URLEncoder

interface FastoryEventsListener {
    fun onHubOpened(fanzoneSlug: String) {}
    fun onHubClosed() {}
    fun onGameOpened(slug: String) {}
    fun onGameClosed() {}
    fun onExternalLink(url: String) {}

    /**
     * A bridge message the web surface posted through the versioned envelope (SPEC §13). Only types
     * in the SDK's registry reach here; everything else is dropped.
     *
     * `fastory:login-requested` (empty payload) means a fan tapped a sign-in entry on a page. It is
     * posted only when [FastoryConfig.handlesLoginRequests] is declared: sign the fan in your own
     * way, then call [Fastory.identify], and the hub on screen reloads signed in. Any frame of a page
     * can post it, so never treat it as proof of who tapped: offer a sign-in, never grant one.
     */
    fun onBridgeMessage(type: String, payload: Map<String, Any?>) {}

    fun onIdentityResolved(identity: FastoryResolvedIdentity) {}

    /**
     * The SDK dropped a delegated identity **on its own** (SPEC § 5.3): a session that expired with
     * no way to renew, or a background re-exchange the API refused. The fan is now anonymous. The
     * host learns why through [FastoryIdentityRevocation.reason] so it can re-`identify` with a fresh
     * token or let the fan continue anonymously — never a blank panel. A host-driven `logout()` is
     * not a revocation and never fires this.
     */
    fun onIdentityRevoked(revocation: FastoryIdentityRevocation) {}

    /**
     * The membership panel is presented on a page that loaded (SPEC § 5.3). It carries nothing: the
     * panel opens the one page the workspace's publishable key resolves, so there is no identifier
     * the host could not already know.
     */
    fun onMembershipOpened() {}

    /**
     * The membership panel is dismissed. Owed exactly once per panel that opened, and never for one
     * whose page did not load (SPEC § 9.1).
     */
    fun onMembershipClosed() {}

    /**
     * A surface that did not load (SPEC § 9.1). The host is the only party that can decide what to
     * do about it — log it, alert its team, offer the fan something else — so the SDK reports and
     * never retries on its own.
     */
    fun onSurfaceLoadFailed(failure: FastoryLoadFailure) {}
}

/**
 * Hands the SDK a fresh host assertion when it needs to renew a delegated session. Registered with
 * [Fastory.setHostTokenProvider], called on the main thread, and answered through `completion` — with
 * a new JWT, or null when the host cannot supply one (the session then lapses to anonymous).
 * Asynchronous on purpose: fetching a token may itself be a round trip, and blocking the SDK on it
 * would violate § 2.7.
 */
fun interface FastoryHostTokenProvider {
    fun provideHostToken(completion: (String?) -> Unit)
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
     * The embed session the last [identify] with [FastoryIdentity.HostToken] resolved, kept so the
     * hub can mint a fresh single-use handoff from it at load time. Cleared whenever the fan behind
     * it goes (logout, `identify(Anonymous)`, a failed resolution, a configuration that is replaced).
     * `@Volatile` like [identity]: written on the caller's thread, read on the UI thread when the hub
     * resolves.
     */
    @Volatile
    internal var delegatedSessionToken: String? = null
        private set

    /**
     * The origin the current delegated session is bound to. Renewal (`/embed/auth/refresh`) must
     * present the same one, and it is not recoverable from the token, so it is kept beside it.
     */
    @Volatile
    private var delegatedOrigin: String? = null

    /** Registered by [setHostTokenProvider]. `@Volatile` — a host may set it from any thread (§ 2.7). */
    @Volatile
    private var hostTokenProvider: FastoryHostTokenProvider? = null

    /** Which delegated session the armed renewal belongs to, bumped on every adopt so a stale timer cannot fire against a newer session. UI-thread-confined. */
    private var renewalGeneration = 0

    /**
     * How long before a session's `exp` the SDK renews it, so the fan never meets a dead session in
     * the middle of a game or a purchase. A functional lead time, not a performance budget.
     */
    private const val RENEWAL_LEAD_MS = 120_000L

    /**
     * How long to wait before retrying a renewal that failed on the network (not a refusal). A fixed
     * backoff rather than `exp`-based, so a lost connection retries steadily instead of spinning on an
     * already-expired token.
     */
    private const val RENEWAL_RETRY_MS = 30_000L

    /** Schedules the renewal work. Seam for tests: a suite replaces it so no timer fires mid-run. */
    internal var renewalSchedule: (Long, Runnable) -> Unit = { delayMs, work ->
        Handler(Looper.getMainLooper()).postDelayed(work, delayMs)
    }

    /**
     * Registers the closure the SDK calls to obtain a fresh host assertion when a delegated session
     * must be renewed (SPEC § 2.6.3). Callable from any thread; null clears it. Setting it does not
     * itself renew anything — it is consulted the next time a session nears expiry or a refresh is
     * refused.
     */
    fun setHostTokenProvider(provider: FastoryHostTokenProvider?) {
        hostTokenProvider = provider
    }

    /**
     * Only ever read and written on the UI thread — from [configure]'s hop, from the two openings
     * and the hop in [close], from the container Activity, and from the trim callbacks, which
     * register on the main looper. That confinement is why these are not `@Volatile` while [config]
     * and [identity] are: those two are written from whatever thread the host called [configure] on
     * (SPEC § 2.7), these are not written off it at all.
     *
     * The two openings are the writers that do not hop, and they do not need to: they are the
     * methods SPEC § 2.7 keeps main-thread-only, because they take the host's own UI object. [close]
     * may be called from anywhere and writes only inside its hop — [surfaceLaunch] is the one field
     * it reads outside, and that one is `@Volatile`.
     *
     * One reference rather than one per kind: what both openings have to answer is "is anything of
     * the SDK's up?", and the container itself carries which surface it stands on.
     */
    private var presentedSurfaceRef: WeakReference<Activity>? = null

    /**
     * Whether a surface is on screen **or on its way to it**, whichever of the two it is.
     *
     * iOS presents synchronously and guards its openings on the view controller itself, so the
     * object it holds is the answer. `startActivity()` returns long before the Activity exists, so
     * [presentedSurfaceRef] answers "nothing up" for the whole launch window — and that window is
     * exactly where a double tap lands. Reserving at the *request* rather than at the arrival is
     * what makes the guarantee the same on both platforms (SPEC § 2.1).
     *
     * Read across both surfaces rather than per kind: one stacked over the other would give the host
     * two openings for one screen, and leave [close] returning the fan to the surface underneath
     * instead of to the application.
     */
    private var surfaceIsPresentedOrLaunching = false

    /**
     * A [close] that arrived while a surface was still launching. There is no Activity to finish
     * yet, so the one on its way reads this in [claimHubPresentation] and finishes itself —
     * otherwise a surface the host asked to be rid of appears a frame after the request.
     */
    private var closeRequestedWhileLaunching = false

    /**
     * Which launch the current reservation belongs to, bumped by every opening that takes one.
     *
     * It exists so a decision taken about one presentation cannot land on the next. [close] is
     * callable from any thread and therefore hops, and in the turns it waits the surface it meant to
     * close can be destroyed and another launch started — without this, that stale request would
     * withdraw the *new* launch and the fan's tap would silently open nothing. The lost-launch
     * watchdog reads it for the same reason, in the other direction.
     *
     * The one presentation field that is `@Volatile`: [close] reads it before its hop, off whatever
     * thread the host called from. It is never reset — a counter that went backwards would let a
     * stale decision match a future launch, which is the whole thing it prevents.
     */
    @Volatile
    private var surfaceLaunch = 0

    /**
     * The launch that last opened each surface — what [stashWebView] reads, never [surfaceLaunch].
     * The reservation is shared, the warm slots are not: opening the games moves the counter while
     * the panel's page is still waiting for the platform to destroy its Activity, and reading the
     * shared counter there threw away a page nothing had replaced. Never reset, for the same reason
     * the counter is not.
     */
    private val latestLaunchBySurface = mutableMapOf<FastorySurface, Int>()

    /**
     * A presentation whose Activity the platform destroyed without dismissing it, which surface it
     * stood on, and whether the host has heard its opening event — and the `gameOpened` of a game
     * sheet torn down with it. The fan never saw the surface leave, so it stays reserved and nothing
     * is emitted; the instance the platform rebuilds resumes it, a [close] arriving before that
     * instance exists ends it here, and an opening meanwhile asks for it again (SPEC § 5.3). A record
     * that leaves its task with no callback is only noticed by the next opening or [close], which is
     * when its closing event goes out.
     */
    private var suspendedPresentation: SuspendedPresentation? = null

    private class SuspendedPresentation(
        val launch: Int,
        val surface: FastorySurface,
        val opened: Boolean,
    ) {
        var gameOpened = false
    }

    private const val LOST_LAUNCH_TIMEOUT_MS = 10_000L

    private var identityGeneration = 0

    internal var eraseWebsiteData: (List<String>, () -> Unit) -> Unit = FastoryWebsiteDataEraser::erase

    fun configure(context: Context, config: FastoryConfig, listener: FastoryEventsListener? = null) {
        val appContext = context.applicationContext
        WorkspaceResolver.applicationId = appContext.packageName
        applyConfiguration(config, listener) {
            registerTrimCallbacksOnce(appContext)
            // configure(context) is the Flutter channel's warm-up entry and owns a Context, so this
            // is where a persisted delegated fan is restored before the hub renders (SPEC § 2.6.3). A
            // replacing configure purged persistence just above, so it self-no-ops there.
            rehydratePersistedIdentity(context)
            warmUpOnceTheHostIsOnScreen(appContext)
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
            // The session was minted against the previous environment and workspace, so it must not
            // survive into the next one — same reason the standing answer it fed is revoked here. The
            // persisted identity was stamped under the previous configuration too, so it goes with it.
            identity = null
            delegatedSessionToken = null
            delegatedOrigin = null
            FastoryIdentityPersistence.purge()
        }
        // On the UI thread, all of it. discardWarmPages() calls WebView.destroy() and flushes the
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
                discardWarmPages()
                WorkspaceResolver.reset()
            }
            // Configured by key, neither the fanzone nor the workspace is known until the API
            // answers. Start the exchange now so a presentation usually finds it already resolved.
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
    internal fun resolveHub(callback: (Result<Pair<String, String?>>) -> Unit) {
        val config = config
        if (config == null) {
            callback(Result.failure(IllegalStateException("not configured")))
            return
        }
        // A resolved slug becomes the hub URL, then adopts the fan's session through a handoff when
        // one exists. The slug path never carries a session — HostToken needs a publishable key — so
        // it is the plain hub URL, exactly as before.
        fun deliver(slug: String) {
            hubUrlAdoptingSession(config.hubUrl(slug), config) { finalUrl ->
                callback(Result.success(finalUrl to slug))
            }
        }
        @Suppress("DEPRECATION")
        val slug = config.fanzoneSlug
        if (slug != null) {
            deliver(slug)
            return
        }
        WorkspaceResolver.whenResolved(config) { outcome ->
            when (outcome) {
                is WorkspaceResolver.Outcome.Success -> deliver(outcome.workspace.slug)
                is WorkspaceResolver.Outcome.Failure ->
                    callback(Result.failure(FastoryBootstrapException(outcome.code)))
            }
        }
    }

    /**
     * Turns a plain hub URL into one that adopts the current delegated session, by minting a
     * single-use handoff token at load time (its window is short, so it is minted now, not at
     * [identify]). A failed mint falls back to the plain URL: an anonymous hub is better than a hub
     * that does not open. No session means the URL is unchanged.
     */
    private fun hubUrlAdoptingSession(
        hubUrl: String,
        config: FastoryConfig,
        callback: (String) -> Unit,
    ) {
        val sessionToken = delegatedSessionToken
        if (sessionToken == null) {
            callback(hubUrl)
            return
        }
        DelegatedSessionClient.mintHandoff(sessionToken, config) { handoff ->
            if (handoff == null) callback(hubUrl) else callback(handoffUrl(config.baseUrl, handoff, hubUrl))
        }
    }

    /**
     * Resolves the membership panel's address (SPEC § 3.5). It is built on the workspace identifier
     * the key exchange already returned, so this waits on that exchange and sends nothing of its
     * own; the deprecated slug path resolves no workspace and therefore no panel.
     *
     * The panel announces itself with no identifier of its own, hence the null slug.
     */
    internal fun resolveMembership(
        sequenceId: String?,
        callback: (Result<Pair<String, String?>>) -> Unit,
    ) {
        val config = config
        if (config?.publishableKey == null) {
            callback(Result.failure(IllegalStateException("not configured")))
            return
        }
        WorkspaceResolver.whenResolved(config) { outcome ->
            when (outcome) {
                is WorkspaceResolver.Outcome.Success ->
                    callback(
                        Result.success(
                            config.membershipUrl(outcome.workspace.id, sequenceId) to null
                        )
                    )
                is WorkspaceResolver.Outcome.Failure ->
                    callback(Result.failure(FastoryBootstrapException(outcome.code)))
            }
        }
    }

    /**
     * The handoff URL a hub loads to adopt a session: `/auth/handoff` on the fanzone origin, carrying
     * the single-use token and the hub path to land on once the session cookie is set. `callbackUrl`
     * is kept relative — the route resolves it against its own origin and refuses anything that is
     * not same-origin.
     */
    internal fun handoffUrl(base: String, handoff: String, callback: String): String {
        val origin = base.trimEnd('/')
        val relative = if (callback.startsWith(origin)) {
            callback.substring(origin.length).ifEmpty { "/" }
        } else {
            callback
        }
        val token = URLEncoder.encode(handoff, "UTF-8")
        val callbackUrl = URLEncoder.encode(relative, "UTF-8")
        return "$origin/auth/handoff?token=$token&callbackUrl=$callbackUrl"
    }

    /**
     * The one method that MUST be called on the UI thread (SPEC § 2.7), and the only one that can say
     * so honestly: it takes the host's own [Context] to start an Activity from, so a caller holding
     * one is already in UI code.
     */
    fun openGames(context: Context) {
        val config = checkNotNull(config) { "Fastory.configure() must be called before openGames()" }
        // Idempotent, as on iOS: asking for the games while a surface is already up — or already on
        // its way up — does nothing at all. Without it a double tap on the host's own tab bar stacks
        // two Activities, close() finishes only the one on top, and the page each stashes on its way
        // out overwrites the other in the warm slot.
        if (surfaceIsPresentedOrLaunching && suspendedPresentation == null) return
        WorkspaceResolver.applicationId = context.applicationContext.packageName
        FastoryAppContext.application = context.applicationContext
        WorkspaceResolver.resolve(config)
        // First point a standalone host hands the SDK a Context: restore a persisted fan so the hub
        // opens already identified, then confirm it in the background (SPEC § 2.6.3).
        rehydratePersistedIdentity(context)
        present(context, FastorySurface.HUB)
    }

    /**
     * Presents the workspace's membership panel — its bot, full-screen, with the host owning
     * dismissal (SPEC § 3.5). UI thread, for the reason [openGames] is.
     *
     * Two call sites have nothing to open and are programmer errors, so each throws: an unconfigured
     * SDK, and one configured with the deprecated fanzone slug, which names a fanzone and never the
     * workspace this page is addressed by. A surface already presented is neither — it returns
     * silently, which is the guarantee [openGames] carries, read across both surfaces rather than
     * per kind, since a double tap on a tab bar is the ordinary way to reach it.
     *
     * [sequenceId] opens the panel on one of the workspace's sequences; naming none, or naming a
     * blank one, opens it on its default screen.
     */
    fun openMembership(context: Context, sequenceId: String? = null) {
        val config = checkNotNull(config) {
            "Fastory.configure() must be called before openMembership()"
        }
        checkNotNull(config.publishableKey) {
            "openMembership() needs a publishable key: a fanzone slug names a fanzone, never the " +
                "workspace this surface is addressed by"
        }
        if (surfaceIsPresentedOrLaunching && suspendedPresentation == null) return
        WorkspaceResolver.applicationId = context.applicationContext.packageName
        FastoryAppContext.application = context.applicationContext
        WorkspaceResolver.resolve(config)
        // A membership-only host hands the SDK a Context here first, so this is where its persisted
        // fan is restored — the panel opens identified, then a background re-exchange confirms it.
        rehydratePersistedIdentity(context)
        present(context, FastorySurface.MEMBERSHIP, sequenceId)
    }

    /**
     * Takes the reservation and starts the shared container on [surface].
     *
     * The container is what resolves the address, so [sequenceId] travels with the launch rather
     * than being held here — a container the platform recreates reads it back from the same Intent.
     */
    private fun present(context: Context, surface: FastorySurface, sequenceId: String? = null) {
        val intent = Intent(context, FastoryHubActivity::class.java)
            .putExtra(FastoryHubActivity.EXTRA_SURFACE, surface.wireName)
        sequenceId?.let { intent.putExtra(FastoryHubActivity.EXTRA_SEQUENCE, it) }
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (suspendedPresentation != null) {
            // The destroyed surface may never come back on its own — its record can leave the task
            // with no callback — so this asks for it rather than doing nothing. Still on top of its
            // task, singleTop rebuilds that record and it resumes its presentation; gone, a new
            // instance arrives with no saved state and claimHubPresentation ends the lost one first.
            context.startActivity(intent)
            return
        }
        surfaceIsPresentedOrLaunching = true
        val launch = ++surfaceLaunch
        try {
            context.startActivity(intent)
        } catch (error: RuntimeException) {
            // A reservation outliving a launch that never happened would turn every later opening
            // into a silent no-op — a worse failure than the one being reported.
            surfaceIsPresentedOrLaunching = false
            throw error
        }
        latestLaunchBySurface[surface] = launch
        releaseTheReservationIfTheLaunchIsLost(launch)
    }

    /**
     * Gives the reservation back when the Activity never arrives.
     *
     * `startActivity` is not a promise and the `catch` above cannot make it one: since Android 10 a
     * start from the background is refused with a logcat line and **no exception**, and the two
     * entry points take a plain [Context] precisely so a native host can call them from one. Left
     * alone that reservation outlives a launch that never happened, and every later opening is a
     * silent no-op for the life of the process — a worse failure than the stacking the reservation
     * exists to prevent, and an unrecoverable one, since only an Activity that was created can
     * release it.
     *
     * The window is deliberately far longer than any launch: an Activity that has not reached
     * `onCreate` in ten seconds is not coming, while the double tap this all exists for lands three
     * orders of magnitude inside it. [surfaceLaunch] is what keeps a late watchdog off a surface
     * that is genuinely up — it only ever frees the launch it was armed for.
     */
    private fun releaseTheReservationIfTheLaunchIsLost(launch: Int) {
        Handler(Looper.getMainLooper()).postDelayed({
            if (surfaceLaunch != launch ||
                !surfaceIsPresentedOrLaunching ||
                presentedSurfaceRef?.get() != null ||
                suspendedPresentation != null
            ) {
                return@postDelayed
            }
            surfaceIsPresentedOrLaunching = false
            closeRequestedWhileLaunching = false
        }, LOST_LAUNCH_TIMEOUT_MS)
    }

    /** Ends whichever of the two surfaces is presented. */
    fun close() {
        // Read before the hop, on the caller's own thread: by the time the block below runs, the
        // surface this call was aimed at may already be gone and another one launching. Withdrawing
        // that one would turn a stale close() into a tap that opens nothing.
        val launch = surfaceLaunch
        // Callable from any thread, unlike the two openings: a host closing a surface is often doing
        // it from a callback it does not control the thread of, and the presentation state is
        // UI-thread-confined.
        onMainThread {
            val presented = presentedSurfaceRef?.get()
            when {
                presented != null -> presented.finish()
                // Destroyed by the platform and not rebuilt yet: there is no Activity to finish,
                // and the record that comes back will find its presentation over.
                suspendedPresentation?.launch == launch -> endSuspendedPresentation()
                // Nothing to finish yet: the Activity is still on its way. Swallowing the request
                // here is how a surface ends up appearing after the host asked for it to be gone —
                // but only for the launch this call was actually aimed at.
                surfaceIsPresentedOrLaunching && surfaceLaunch == launch ->
                    closeRequestedWhileLaunching = true
            }
        }
    }

    /**
     * Binds the host app's user to a Fastory fan. See `SPEC.md` § 2.6.
     *
     * Non-blocking: every outcome arrives in [callback], on the main thread.
     * [FastoryIdentity.Anonymous] resolves synchronously, [FastoryIdentity.HostToken] resolves
     * through a server-side exchange with no browser and no form, and [FastoryIdentity.FanId] signs
     * the fan in through the system browser — never a WebView — then exchanges the returned code for
     * the same session (SPEC § 2.6).
     *
     * [FastoryIdentity.Anonymous] over an identified fan drops that fan the way [logout] does —
     * session, renewal, and the identity kept across launches — and a hub on screen reloads
     * anonymous (SPEC § 7). Over an SDK already anonymous it does nothing.
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
            if (identity is FastoryIdentity.HostToken) {
                identifyHostToken(identity.jwt, config, callback)
                return@onMainThread
            }
            if (identity is FastoryIdentity.FanId) {
                identifyFanId(config, callback)
                return@onMainThread
            }
            val transition = FastoryIdentityRules.transition(identity, Fastory.identity)
            val errorCode = transition.errorCode
            if (errorCode != null) {
                callback?.invoke(Result.failure(FastoryIdentifyException(errorCode)))
                return@onMainThread
            }
            val resolved = transition.resolved ?: return@onMainThread
            applyTransition(transition, config) {
                // Set before notifying, so a listener reading Fastory.identity sees the new fan.
                Fastory.identity = resolved
                // A resolved change that revokes the standing answer — `identify(anonymous)` over a
                // delegated fan — is a different identity, so a live game re-asks and gets
                // `unavailable` (SPEC § 13.9.2). An idempotent same-identity call does not revoke and
                // stays silent.
                if (transition.revokesBridgeReplies) {
                    FastorySessionPush.broadcast()
                }
                if (transition.emitsIdentityResolved) {
                    listener?.onIdentityResolved(resolved)
                }
                callback?.invoke(Result.success(resolved))
            }
        }
    }

    /**
     * Resolves [identify] with [FastoryIdentity.HostToken] — the partner already authenticated the
     * fan, so the JWT is forwarded for server-side verification and nothing is typed or opened
     * (SPEC § 2.6, § 12).
     *
     * Two pre-flight rejections come first and leave the current identity untouched (SPEC § 2.6.1): a
     * blank JWT, and a slug configuration, which carries no workspace to exchange against — the mode
     * is unavailable until the host configures by publishable key. Everything after the exchange is a
     * resolution outcome, so a failure lands the SDK on anonymous rather than on the previous fan.
     */
    private fun identifyHostToken(
        jwt: String,
        config: FastoryConfig,
        callback: ((Result<FastoryResolvedIdentity>) -> Unit)?,
    ) {
        if (jwt.isBlank()) {
            callback?.invoke(
                Result.failure(FastoryIdentifyException(FastoryIdentifyException.INVALID_HOST_TOKEN)),
            )
            return
        }
        if (config.publishableKey == null) {
            callback?.invoke(
                Result.failure(FastoryIdentifyException(FastoryIdentifyException.MODE_UNAVAILABLE)),
            )
            return
        }
        // The session is bound to the games' origin, because the games are what read this token over
        // the bridge; the hub adopts the same session through a handoff instead. Development has no
        // stories origin, so it falls back to the base URL exactly as game-URL construction does.
        val origin = config.environment.storiesOrigin ?: config.baseUrl
        WorkspaceResolver.whenResolved(config) { outcome ->
            when (outcome) {
                is WorkspaceResolver.Outcome.Failure ->
                    failIdentifiedResolution(
                        FastoryIdentityExchangeClassifier.error(outcome.code),
                        config,
                        callback,
                    )
                is WorkspaceResolver.Outcome.Success ->
                    DelegatedSessionClient.exchange(
                        jwt = jwt,
                        workspaceId = outcome.workspace.id,
                        origin = origin,
                        config = config,
                    ) { result ->
                        result.fold(
                            onSuccess = { session ->
                                resolveIdentifiedFan(
                                    session,
                                    FastoryIdentityMode.HOST_TOKEN,
                                    origin,
                                    config,
                                    callback,
                                )
                            },
                            onFailure = { error ->
                                failIdentifiedResolution(error as FastoryIdentifyException, config, callback)
                            },
                        )
                    }
            }
        }
    }

    /**
     * Resolves [identify] with [FastoryIdentity.FanId] — the fan signs in to Fastory in the
     * **system browser** (SPEC § 2.6): the platform's reference OpenID client opens the login in a
     * Custom Tab, and the returned single-use code is exchanged server-side for the same session
     * `HostToken` gets. Nothing renders in a WebView, which is also the only path that reaches the
     * device's password manager.
     *
     * The pre-flight is the same as `HostToken`: a slug configuration carries no publishable key to
     * prove the caller with, so the mode is unavailable (SPEC § 2.6.1, identity untouched). The
     * workspace is resolved first so a refused key fails before any browser opens. A dismissed
     * browser is `login_cancelled`; like every resolution failure, it lands the SDK on anonymous.
     */
    private fun identifyFanId(
        config: FastoryConfig,
        callback: ((Result<FastoryResolvedIdentity>) -> Unit)?,
    ) {
        val publishableKey = config.publishableKey
        if (publishableKey == null) {
            callback?.invoke(
                Result.failure(FastoryIdentifyException(FastoryIdentifyException.MODE_UNAVAILABLE)),
            )
            return
        }
        val origin = config.environment.storiesOrigin ?: config.baseUrl
        WorkspaceResolver.whenResolved(config) { outcome ->
            when (outcome) {
                is WorkspaceResolver.Outcome.Failure ->
                    failIdentifiedResolution(
                        FastoryIdentityExchangeClassifier.error(outcome.code),
                        config,
                        callback,
                    )
                is WorkspaceResolver.Outcome.Success -> {
                    val applicationId = WorkspaceResolver.applicationId
                    if (applicationId.isNullOrBlank()) {
                        // The exchange would be refused without the identifier, so refuse in its
                        // place — the same code the key exchange uses for the same absence (§ 2.5).
                        failIdentifiedResolution(
                            FastoryIdentifyException(
                                FastoryIdentifyException.REJECTED,
                                detailsCode = "sdk_application_id_required",
                            ),
                            config,
                            callback,
                        )
                        return@whenResolved
                    }
                    FanLoginClient.performLogin(
                        FanLoginClient.request(config, applicationId),
                    ) { login ->
                        onMainThread {
                            login.fold(
                                onSuccess = { granted ->
                                    DelegatedSessionClient.exchangeLoginCode(
                                        code = granted.code,
                                        codeVerifier = granted.codeVerifier,
                                        publishableKey = publishableKey,
                                        applicationId = applicationId,
                                        config = config,
                                    ) { result ->
                                        result.fold(
                                            onSuccess = { session ->
                                                resolveIdentifiedFan(
                                                    session,
                                                    FastoryIdentityMode.FAN_ID,
                                                    origin,
                                                    config,
                                                    callback,
                                                )
                                            },
                                            onFailure = { error ->
                                                failIdentifiedResolution(
                                                    error as FastoryIdentifyException,
                                                    config,
                                                    callback,
                                                )
                                            },
                                        )
                                    }
                                },
                                onFailure = { failure ->
                                    val cancelled = (failure as? FanLoginException)?.cancelled == true
                                    failIdentifiedResolution(
                                        FastoryIdentifyException(
                                            if (cancelled) {
                                                FastoryIdentifyException.LOGIN_CANCELLED
                                            } else {
                                                FastoryIdentifyException.NETWORK_ERROR
                                            },
                                        ),
                                        config,
                                        callback,
                                    )
                                },
                            )
                        }
                    }
                }
            }
        }
    }

    private fun resolveIdentifiedFan(
        session: FastoryDelegatedSession,
        mode: FastoryIdentityMode,
        origin: String,
        config: FastoryConfig,
        callback: ((Result<FastoryResolvedIdentity>) -> Unit)?,
    ) {
        val resolved = FastoryResolvedIdentity(mode, session.fanId)
        val transition = FastoryIdentityRules.afterResolution(resolved, Fastory.identity)
        // applyTransition revokes the previous fan's standing answer when the fan changed; the fresh
        // token is set right after, so a different fan is revoke-then-populate and the same fan is a
        // refresh.
        applyTransition(transition, config) {
            Fastory.identity = resolved
            adoptDelegatedSession(session, origin, config)
            if (transition.emitsIdentityResolved) {
                // A different fan now stands behind the answer; a same-fan re-identify is idempotent
                // and stays observable as nothing, this channel included (SPEC § 13.9.2).
                FastorySessionPush.broadcast()
                listener?.onIdentityResolved(resolved)
            }
            callback?.invoke(Result.success(resolved))
        }
    }

    /**
     * Records a freshly minted delegated session and everything that hangs off it: the token the hub
     * hands off and the games read over the bridge, the identity kept across launches, and the renewal
     * armed to fire before it expires. The one place all four are set, so a renewal and a first
     * resolution leave the SDK in the same state.
     */
    private fun adoptDelegatedSession(
        session: FastoryDelegatedSession,
        origin: String,
        config: FastoryConfig,
    ) {
        delegatedSessionToken = session.token
        delegatedOrigin = origin
        FastoryBridgeResponder.setReply(
            FastoryBridgeRequestType.USER_TOKEN,
            mapOf("token" to session.token),
        )
        Fastory.identity?.let { FastoryIdentityPersistence.save(it, config) }
        armDelegatedRenewal(session.token)
    }

    private fun failIdentifiedResolution(
        error: FastoryIdentifyException,
        config: FastoryConfig,
        callback: ((Result<FastoryResolvedIdentity>) -> Unit)?,
    ) {
        val transition = FastoryIdentityRules.afterResolutionFailure(Fastory.identity)
        applyTransition(transition, config) {
            Fastory.identity = null
            callback?.invoke(Result.failure(error))
        }
    }

    // Host-token lifecycle (SPEC § 2.6.3, § 5.3)

    /**
     * Arms renewal to fire [RENEWAL_LEAD_MS] before the session's `exp`. A token with no readable
     * `exp` is treated as due now rather than trusted for an unknown lifetime. The generation stamp
     * keeps a stale timer — armed for a session already replaced — from firing against the new one.
     */
    private fun armDelegatedRenewal(token: String) {
        val generation = ++renewalGeneration
        val expiry = DelegatedSessionClient.expiryEpochMillis(token) ?: System.currentTimeMillis()
        val delay = (expiry - RENEWAL_LEAD_MS - System.currentTimeMillis()).coerceAtLeast(0)
        renewalSchedule(delay) {
            if (renewalGeneration == generation) renewDelegatedSessionNow(null)
        }
    }

    /**
     * Re-arms a renewal after [RENEWAL_RETRY_MS] when the last attempt failed on the network. The
     * generation stamp keeps a stale retry off a session already replaced, and `renewDelegatedSessionNow`
     * no-ops once the session is gone — so this is safe even after a logout in the meantime.
     */
    private fun armDelegatedRenewalRetry() {
        val generation = ++renewalGeneration
        renewalSchedule(RENEWAL_RETRY_MS) {
            if (renewalGeneration == generation) renewDelegatedSessionNow(null)
        }
    }

    /**
     * Renews the current delegated session once (SPEC § 2.6.3). Tries the cheap path first —
     * `/embed/auth/refresh`, involving no one — and falls back to a fresh host assertion from the
     * provider only when the refresh is refused.
     */
    internal fun renewDelegatedSessionNow(onDone: (() -> Unit)?) {
        val token = delegatedSessionToken
        val origin = delegatedOrigin
        val config = config
        if (token == null || origin == null || config == null) {
            onDone?.invoke()
            return
        }
        DelegatedSessionClient.refresh(token, origin, config) { result ->
            result.fold(
                onSuccess = { renewed ->
                    // The same session extended: identity and persistence untouched, only the token
                    // the games read is swapped and the renewal re-armed (fixture: session_expiring).
                    delegatedSessionToken = renewed
                    FastoryBridgeResponder.setReply(
                        FastoryBridgeRequestType.USER_TOKEN,
                        mapOf("token" to renewed),
                    )
                    // The standing answer changed under a live game — tell it to re-read (SPEC § 13.9).
                    FastorySessionPush.broadcast()
                    armDelegatedRenewal(renewed)
                    onDone?.invoke()
                },
                onFailure = { reexchangeThroughProvider(config, onDone) },
            )
        }
    }

    /**
     * The refresh was refused, so the session itself is no longer renewable. Ask the host for a fresh
     * assertion and re-exchange it (fixture: refresh_refused). No provider, or a provider that hands
     * back nothing, means the session lapses — revoked with `reason: expired`.
     */
    private fun reexchangeThroughProvider(config: FastoryConfig, onDone: (() -> Unit)?) {
        val provider = hostTokenProvider
        if (provider == null) {
            revokeDelegatedSession(FastoryIdentityRevocation(FastoryRevocationReason.EXPIRED), config)
            onDone?.invoke()
            return
        }
        provider.provideHostToken { freshToken ->
            onMainThread {
                val jwt = freshToken?.trim()
                if (jwt.isNullOrEmpty()) {
                    revokeDelegatedSession(FastoryIdentityRevocation(FastoryRevocationReason.EXPIRED), config)
                    onDone?.invoke()
                    return@onMainThread
                }
                val origin = config.environment.storiesOrigin ?: config.baseUrl
                WorkspaceResolver.whenResolved(config) { outcome ->
                    when (outcome) {
                        is WorkspaceResolver.Outcome.Failure -> {
                            finishReexchange(
                                Result.failure(FastoryIdentityExchangeClassifier.error(outcome.code)),
                                origin, config, onDone,
                            )
                        }
                        is WorkspaceResolver.Outcome.Success ->
                            DelegatedSessionClient.exchange(jwt, outcome.workspace.id, origin, config) { result ->
                                finishReexchange(result, origin, config, onDone)
                            }
                    }
                }
            }
        }
    }

    private fun finishReexchange(
        result: Result<FastoryDelegatedSession>,
        origin: String,
        config: FastoryConfig,
        onDone: (() -> Unit)?,
    ) {
        result.fold(
            onSuccess = { session ->
                val resolved = FastoryResolvedIdentity(FastoryIdentityMode.HOST_TOKEN, session.fanId)
                val transition = FastoryIdentityRules.afterResolution(resolved, Fastory.identity)
                applyTransition(transition, config) {
                    Fastory.identity = resolved
                    adoptDelegatedSession(session, origin, config)
                    // A re-exchange is a renewal: the session behind the standing answer is fresh
                    // whether or not the fan changed, so the live game re-reads it unconditionally
                    // (SPEC § 13.9).
                    FastorySessionPush.broadcast()
                    if (transition.emitsIdentityResolved) {
                        listener?.onIdentityResolved(resolved)
                    }
                    onDone?.invoke()
                }
            },
            onFailure = { error ->
                // A refusal drops the fan and tells the host why. A network failure did not refuse
                // anything, so it keeps the identity and re-arms a bounded retry rather than signing a
                // fan out over a lost connection — the timer that fired this renewal is spent, so
                // without this the session would stay identified but never renew again.
                val exception = error as FastoryIdentifyException
                if (exception.code == FastoryIdentifyException.REJECTED) {
                    revokeDelegatedSession(
                        FastoryIdentityRevocation(FastoryRevocationReason.REJECTED, exception.detailsCode),
                        config,
                    )
                } else {
                    armDelegatedRenewalRetry()
                }
                onDone?.invoke()
            },
        )
    }

    /**
     * Drops a delegated session the SDK could not keep (SPEC § 5.3): erase, revoke the standing
     * answer, purge the persisted identity, land on anonymous, and tell the host why. The one path
     * that emits `onIdentityRevoked` — a host-driven `logout` never comes through here.
     */
    private fun revokeDelegatedSession(revocation: FastoryIdentityRevocation, config: FastoryConfig) {
        val transition = FastoryIdentityRules.afterResolutionFailure(Fastory.identity)
        applyTransition(transition, config) {
            Fastory.identity = null
            // The standing answer was revoked, so a live game must re-ask and get `unavailable`,
            // which is how it learns the fan is gone (SPEC § 13.9).
            FastorySessionPush.broadcast()
            listener?.onIdentityRevoked(revocation)
        }
    }

    /** Forgets everything tied to a delegated session and disarms its renewal. */
    private fun clearDelegatedSession() {
        delegatedSessionToken = null
        delegatedOrigin = null
        FastoryIdentityPersistence.purge()
        // Bumping the generation is the disarm: the pending timer's guard no longer matches.
        renewalGeneration++
    }

    /**
     * Restores a persisted delegated identity for this configuration once a [Context] is available
     * (the SDK's `configure` has none), then re-establishes the session behind it in the background.
     * Called from [openGames] and the hub warm-up. No `onIdentityResolved` from the cache: it
     * announces a resolution, and this is a restoration.
     */
    internal fun rehydratePersistedIdentity(context: Context) {
        FastoryIdentityPersistence.attach(context)
        val config = config ?: return
        if (identity == null) {
            val persisted = FastoryIdentityPersistence.load(config) ?: return
            identity = persisted
        }
        // Confirm the rehydrated identity by re-exchanging a fresh assertion, so the games get a live
        // token. With no provider the identity stays shown but the first game is anonymous until the
        // host identifies again.
        if (identity?.mode == FastoryIdentityMode.HOST_TOKEN &&
            delegatedSessionToken == null &&
            hostTokenProvider != null
        ) {
            reexchangeThroughProvider(config, null)
        }
    }

    /**
     * Signs the fan out of Fastory only — the host application's own session is never touched.
     * Idempotent, and needs no network call.
     */
    fun logout(callback: (() -> Unit)? = null) {
        onMainThread {
            val transition = FastoryIdentityRules.logout(Fastory.identity)
            // A sign-out wins over a fanId login still in the system browser: answer it cancelled so
            // it cannot re-identify the fan after this logout has run.
            FanLoginClient.cancelPending()
            // Not `config?.let`: an unconfigured SDK still has a standing answer to revoke, and
            // gating the whole transition on a configuration is what let logout() keep it.
            applyTransition(transition, config) {
                Fastory.identity = null
                // logout() revoked the standing answer — a live game re-asks and gets `unavailable`
                // (SPEC § 13.9). The host gets no event: it made the call and already knows.
                FastorySessionPush.broadcast()
                callback?.invoke()
            }
        }
    }

    /**
     * [then] stores what the transition lands on — the identity, and the session the hub hands off.
     * The hub on screen reloads once [then] has run and the erasure has completed, so it loads under
     * that session, never under the previous fan's cookies (SPEC § 7).
     */
    private fun applyTransition(
        transition: FastoryIdentityTransition,
        config: FastoryConfig?,
        then: () -> Unit,
    ) {
        // Before the erasure and outside its guard: revocation needs no configuration and no store,
        // and `logout()` revokes even when it has no session to erase (SPEC § 13.8.2).
        if (transition.revokesBridgeReplies) {
            FastoryBridgeResponder.revokeAll()
            clearDelegatedSession()
        }
        val fanBefore = identity?.fanId
        var pending = 1
        fun settle() {
            if (--pending == 0) reloadPresentedHubIfTheFanChanged(fanBefore)
        }
        if (transition.erasesStorage && config != null) {
            identityGeneration++
            // All of them were built before this transition, so they hold the previous fan's
            // rendered page.
            discardWarmPages()
            pending++
            eraseWebsiteData(FastoryIdentityStorage.origins(config)) { settle() }
        }
        then()
        settle()
    }

    /**
     * A hub on screen follows the identified fan (SPEC § 2.6.1, § 7): it reloads, through the session
     * handoff [resolveHub] mints, when the transition changed *which* fan is identified, and only
     * then. Anonymous and not identified both carry no `fanId`, so moving between them reloads
     * nothing, and neither does the same fan identified again or renewed. The panel is not reloaded,
     * and a game learns the change from the session-change signal.
     */
    private fun reloadPresentedHubIfTheFanChanged(fanBefore: String?) {
        if (identity?.fanId == fanBefore) return
        (presentedSurfaceRef?.get() as? FastoryHubActivity)?.reloadAfterIdentityChange()
    }

    private fun onMainThread(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            Handler(Looper.getMainLooper()).post(block)
        }
    }

    /**
     * Called by the container Activity as it is created, before it builds anything — so a surface
     * the host has already asked to close never renders. Returns null when [close] arrived during
     * the launch, which is the Activity's cue to finish itself; otherwise the launch this
     * presentation answers for, which the Activity hands back to [releaseHubPresentation] when it is
     * over.
     *
     * A container the platform rebuilds does not come through here: it carries the launch it
     * continues and goes through [resumeHubPresentation], since the reservation never left it.
     *
     * [presentedSurfaceRef] is taken here rather than at [notifyHubOpened] because a surface
     * configured by key spends the whole `/sdk/auth/bootstrap` round trip on screen before it
     * opens — a `close()` in that window used to find nothing to finish.
     */
    internal fun claimHubPresentation(activity: Activity): Int? {
        // A container arriving with no saved state while another was suspended: the platform
        // dropped the record that would have resumed it, so that presentation is over before this
        // one begins — and gets a launch of its own, so a close() aimed at the lost one cannot reach
        // it.
        if (suspendedPresentation != null) {
            endSuspendedPresentation()
            ++surfaceLaunch
        }
        if (closeRequestedWhileLaunching) {
            closeRequestedWhileLaunching = false
            surfaceIsPresentedOrLaunching = false
            return null
        }
        surfaceIsPresentedOrLaunching = true
        presentedSurfaceRef = WeakReference(activity)
        return surfaceLaunch
    }

    /**
     * Frees the slot [claimHubPresentation] took, so the next opening is not a silent no-op.
     *
     * Keyed on the launch, not on the Activity. A surface gives its slot back the moment it is
     * dismissed, while the platform destroys it on its own schedule — seconds later when the host
     * beneath is slow to settle — and in between the fan may have asked for, and got, the next one.
     * A release matched on the Activity instance could not tell that late destruction from the live
     * surface's own; one matched on the launch ignores it, because the opening has moved the counter
     * on.
     */
    internal fun releaseHubPresentation(presentation: Int) {
        if (presentation != surfaceLaunch) return
        presentedSurfaceRef = null
        surfaceIsPresentedOrLaunching = false
    }

    internal fun suspendHubPresentation(presentation: Int, surface: FastorySurface, opened: Boolean) {
        if (presentation != surfaceLaunch) return
        presentedSurfaceRef = null
        suspendedPresentation = SuspendedPresentation(presentation, surface, opened)
    }

    /**
     * A game sheet whose `gameOpened` the host has heard, torn down with a surface the platform is
     * rebuilding: its `gameClosed` is owed by that presentation now — the sheet restored with the
     * surface takes it back, anything that ends the presentation first emits it, ahead of the
     * surface's own closing event. False when no presentation is suspended, and the sheet emits it
     * itself.
     */
    internal fun suspendGamePresentation(): Boolean {
        val suspended = suspendedPresentation ?: return false
        suspended.gameOpened = true
        return true
    }

    /**
     * Hands a rebuilt container the presentation its predecessor left: whether the host has already
     * heard it open, or null when that presentation is over and the instance must finish without a
     * word.
     */
    internal fun resumeHubPresentation(activity: Activity, presentation: Int): Boolean? {
        val suspended = suspendedPresentation
        if (suspended == null || suspended.launch != presentation || presentation != surfaceLaunch) {
            return null
        }
        suspendedPresentation = null
        presentedSurfaceRef = WeakReference(activity)
        return suspended.opened
    }

    private fun endSuspendedPresentation() {
        val suspended = suspendedPresentation ?: return
        suspendedPresentation = null
        if (suspended.gameOpened) notifyGameClosed()
        when {
            !suspended.opened -> releaseHubPresentation(suspended.launch)
            suspended.surface == FastorySurface.MEMBERSHIP ->
                notifyMembershipClosed(suspended.launch)
            else -> notifyHubClosed(suspended.launch)
        }
    }

    /// [fanzoneSlug] is the resolved one: configured by key, it is only known once the API answers.
    internal fun notifyHubOpened(activity: Activity, fanzoneSlug: String) {
        presentedSurfaceRef = WeakReference(activity)
        listener?.onHubOpened(fanzoneSlug)
    }

    internal fun notifyHubClosed(presentation: Int) {
        releaseHubPresentation(presentation)
        listener?.onHubClosed()
    }

    internal fun notifyMembershipOpened(activity: Activity) {
        presentedSurfaceRef = WeakReference(activity)
        listener?.onMembershipOpened()
    }

    /**
     * The reservation comes back **before** the host hears about the closing. Android destroys a
     * finishing Activity only once the one beneath it has settled, which can take seconds, and a
     * host reopening the panel from its own closing callback — the ordinary way to reach this —
     * must find the slot free, or its tap opens nothing at all.
     */
    internal fun notifyMembershipClosed(presentation: Int) {
        releaseHubPresentation(presentation)
        listener?.onMembershipClosed()
    }

    internal fun resetHubPresentationForTesting() {
        presentedSurfaceRef = null
        suspendedPresentation = null
        surfaceIsPresentedOrLaunching = false
        closeRequestedWhileLaunching = false
    }

    internal fun resetForTesting() {
        config = null
        listener = null
        identity = null
        identityGeneration = 0
        discardWarmPages()
        failedWarmWebViews.clear()
        // The registration below is made on one application context while the flag guarding it is
        // process-wide, so a reset that kept it armed would leave the next configuration listening
        // on a context that is gone.
        trimCallbacksRegistered = false
        resetHubPresentationForTesting()
        hostIsOnScreen = DEFAULT_HOST_IS_ON_SCREEN
        whenHostComesOnScreen = DEFAULT_WHEN_HOST_COMES_ON_SCREEN
        eraseWebsiteData = FastoryWebsiteDataEraser::erase
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
        // The host changed the answer by hand — set or cleared. A live game re-asks and adopts the
        // new value, or gets `unavailable` on a clear (SPEC § 13.9). No-op when no game is open.
        FastorySessionPush.broadcast()
    }

    internal fun openExternalBrowser(context: Context, url: String) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            listener?.onExternalLink(url)
        } catch (_: ActivityNotFoundException) {
        }
    }

    /**
     * One prepared page per surface, kept between presentations (SPEC § 2.1).
     *
     * Keyed rather than held in a field apiece: the hub's rules and the panel's are the same rules,
     * and the one thing that keeps two resident pages apart is which slot each is read from — a hub
     * handed the panel's page would open the workspace's bot under the games entry, and stash it
     * back over the hub's on the way out.
     */
    private val warmPages = mutableMapOf<FastorySurface, WarmPage>()

    /**
     * A page prepared ahead of a presentation, with everything that presentation needs to decide
     * whether it may use it.
     *
     * [config] is the configuration the page was loaded under — never the current one. A teardown at
     * [configure] time cannot be enough on its own: a page can be **re-stashed after it ran**, by an
     * Activity destroyed after a re-configure, and it comes back holding the previous workspace. The
     * stamp is what makes the check total — a page is reusable only for the configuration it was
     * rendered for, whenever it was put there.
     */
    private class WarmPage(
        val webView: WebView,
        /**
         * The address the page was **asked for** — never wherever it ended up, which the fan's own
         * navigation moves. A presentation reuses it only for the address it is asking for: the
         * same surface at two addresses is two documents, and the panel opened on a sequence is
         * exactly that.
         */
        val url: String?,
        val config: FastoryConfig,
        var loadStarted: Boolean,
        var didCommit: Boolean,
    )

    private val failedWarmWebViews = mutableListOf<WebView>()
    private var trimCallbacksRegistered = false

    /**
     * A page handed to a presentation, with everything that presentation needs to decide whether to
     * put it on screen as it stands.
     */
    internal data class WarmSurfacePage(
        val webView: WebView,
        val url: String?,
        val hasCommitted: Boolean,
        val isLoading: Boolean,
    ) {
        /**
         * Decided on the address, never on the arguments the opening carried: a page warm on the
         * panel's default screen is not the sequence the fan asked for, and one already warm on that
         * sequence is as reusable as the default is to a bare call. Stated this way, the next
         * parameter to reach one of these addresses is covered by it.
         *
         * The address joins the older rule rather than replacing it: a page with neither a commit
         * nor a load in flight is a blank WebView no callback will ever fire for, so a matching
         * address is not enough on its own.
         */
        fun isReusableFor(url: String): Boolean = (hasCommitted || isLoading) && this.url == url
    }

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

    private fun warmUpOnceTheHostIsOnScreen(appContext: Context) {
        // Nothing asked for is nothing to wait for: no page, and no observer left armed for one.
        if (config?.surfacesToPrewarm.isNullOrEmpty()) return
        if (hostIsOnScreen()) {
            preloadSurfaces(appContext)
            return
        }
        if (hostObserverArmed) return
        hostObserverArmed = true
        whenHostComesOnScreen {
            if (!hostObserverArmed) return@whenHostComesOnScreen
            hostObserverArmed = false
            preloadSurfaces(appContext)
        }
    }

    /**
     * Prepares the surfaces the current configuration asks for, on the one trigger the hub has
     * always used — the host's first screen.
     *
     * The hub alone unless the host asks for more (SPEC § 2.1): a prepared page is a WebView and a
     * renderer process resident from launch on, with the requests its page makes, so a host that
     * never opens the panel must not pay for one.
     */
    internal fun preloadSurfaces(context: Context) {
        val config = config ?: return
        if (config.surfacesToPrewarm.isEmpty()) return
        if (surfaceIsPresentedOrLaunching || presentedSurfaceRef?.get() != null) return
        val appContext = context.applicationContext
        config.staticHubUrl?.let { hubUrl ->
            // The deprecated slug path names a fanzone and never a workspace, so the hub is all it
            // can have asked for (SPEC § 3.5).
            prepareWarmPage(FastorySurface.HUB, appContext, hubUrl, config)
            return
        }
        val generation = identityGeneration
        WorkspaceResolver.whenResolved(config) { outcome ->
            val workspace = (outcome as? WorkspaceResolver.Outcome.Success)?.workspace
                ?: return@whenResolved
            warmUpSurfaces(appContext, workspace, config, generation)
        }
    }

    private fun warmUpSurfaces(
        appContext: Context,
        workspace: WorkspaceResolver.Workspace,
        config: FastoryConfig,
        generation: Int,
    ) {
        if (config != Fastory.config ||
            surfaceIsPresentedOrLaunching || presentedSurfaceRef?.get() != null ||
            generation != identityGeneration
        ) {
            return
        }
        if (!hostIsOnScreen()) {
            warmUpOnceTheHostIsOnScreen(appContext)
            return
        }
        val surfaces = config.surfacesToPrewarm
        if (FastorySurface.HUB in surfaces) {
            prepareWarmPage(FastorySurface.HUB, appContext, config.hubUrl(workspace.slug), config)
        }
        if (FastorySurface.MEMBERSHIP in surfaces) {
            prepareWarmPage(
                FastorySurface.MEMBERSHIP,
                appContext,
                config.membershipUrl(workspace.id),
                config,
            )
        }
    }

    private fun prepareWarmPage(
        surface: FastorySurface,
        appContext: Context,
        url: String,
        config: FastoryConfig,
    ) {
        // Already warm — nothing to do, and doing it anyway is what SPEC § 2.1 forbids on an equal
        // re-configure: the rendered page would be replaced by one still loading, so a harmless call
        // would be paid for as a cold open.
        if (warmPages[surface] != null) return
        val webView = createWebView(MutableContextWrapper(appContext))
        // Kicks off game discovery as soon as the warm hub has rendered, and drops the page when the
        // warm-up failed (SPEC § 9.1).
        webView.webViewClient = FastoryWarmUpClient(surface)
        warmPages[surface] = WarmPage(webView, url, config, loadStarted = true, didCommit = false)
        webView.loadUrl(url)
    }

    internal fun obtainWebView(surface: FastorySurface, activity: Activity): WarmSurfacePage {
        // Nothing warm is not a mismatch. Discarding on an empty slot would flush the preloader on
        // every cold open, throwing away the games discovered from the very hub that is opening —
        // this runs on presentation, when the slot has just been emptied or was never filled.
        val resident = warmPages[surface]
        if (resident != null && resident.config != config) {
            // Rendered for another configuration: presenting it under the current one is the
            // whole defect, so it is dropped rather than handed over (SPEC § 2.1).
            discardWarmPage(surface)
        }
        warmPages.remove(surface)?.let { page ->
            (page.webView.context as MutableContextWrapper).baseContext = activity
            page.webView.onResume()
            return WarmSurfacePage(
                page.webView,
                url = page.url,
                hasCommitted = page.didCommit,
                isLoading = page.loadStarted && !page.didCommit,
            )
        }
        return WarmSurfacePage(
            createWebView(MutableContextWrapper(activity)),
            url = null,
            hasCommitted = false,
            isLoading = false,
        )
    }

    /**
     * [presentation] is the launch the page was presented for. A container is destroyed on the
     * platform's schedule, possibly after the fan has asked for — and got — the next one, and a page
     * that late must not enter the slot once its own surface has been opened again: it would replace
     * what the newer presentation put there, or be handed to the one after it in place of a fresher
     * page. The other surface opening in between touches another slot and supersedes nothing.
     */
    internal fun stashWebView(
        webView: WebView,
        surface: FastorySurface,
        url: String?,
        config: FastoryConfig,
        presentation: Int,
        hasCommitted: Boolean,
    ) {
        if ((latestLaunchBySurface[surface] ?: presentation) > presentation) {
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView.destroy()
            return
        }
        stashWebView(webView, surface, url, config, hasCommitted)
    }

    /**
     * [config] is the one the page was **loaded** under, which the caller holds and the SDK may no
     * longer have: an Activity destroyed after a re-configure is exactly the case this parameter
     * exists for, and reading [Fastory.config] here would bless the stale page instead of catching it.
     *
     * [surface] is the slot it goes back into. Stashed over the other's it would open under the
     * wrong entry point.
     *
     * [url] is the address the surface **asked for**, and it travels for a third reason of its own:
     * [WebView.getUrl] is wherever the page ended, which a fan browsing the hub moves at will. Read
     * off the page, the slot would come back stamped with a deep address no opening ever asks for,
     * and every reopening would reload a document already rendered.
     */
    internal fun stashWebView(
        webView: WebView,
        surface: FastorySurface,
        url: String?,
        config: FastoryConfig,
        hasCommitted: Boolean,
    ) {
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
        // A page pushed out of the slot is unreachable the instant the entry moves, and it keeps its
        // renderer process alive until destroy() — Swift's ARC releases the iOS equivalent for free,
        // which is why only this platform has ever leaked one here.
        val resident = warmPages[surface]?.webView
        if (resident !== webView) resident?.destroy()
        warmPages[surface] = WarmPage(
            webView,
            url = url,
            config = config,
            loadStarted = hasCommitted,
            didCommit = hasCommitted,
        )
    }

    internal fun discardWarmPage(surface: FastorySurface) {
        emptyWarmSlot(surface)?.destroy()
    }

    private fun discardWarmPages() {
        discardWarmPage(FastorySurface.HUB)
        discardWarmPage(FastorySurface.MEMBERSHIP)
    }

    internal fun warmPageDidFail(webView: WebView, surface: FastorySurface) {
        if (warmPages[surface]?.webView !== webView) return
        emptyWarmSlot(surface)
        failedWarmWebViews.add(webView)
    }

    internal fun releaseFailedWarmWebView(webView: WebView) {
        if (failedWarmWebViews.remove(webView)) webView.destroy()
    }

    internal fun warmPageDidCommit(webView: WebView, surface: FastorySurface) {
        val page = warmPages[surface] ?: return
        if (page.webView !== webView) return
        page.didCommit = true
    }

    /**
     * Empties one slot and hands back whatever was in it, so a caller that has to destroy the page
     * and one that has to keep it alive a turn longer share the same bookkeeping.
     *
     * The preloaded games were discovered from the hub's own page: losing it loses them. Nothing
     * hangs off the panel's, so emptying that slot must leave the pool alone — it would throw away
     * exactly what the fan is about to tap, for a surface that lists no games at all.
     */
    private fun emptyWarmSlot(surface: FastorySurface): WebView? {
        val page = warmPages.remove(surface)
        if (surface == FastorySurface.HUB) GamePreloader.flush()
        return page?.webView
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
                    // Every resident WebView is one to give back when the system asks.
                    discardWarmPages()
                }
            }

            override fun onConfigurationChanged(newConfig: Configuration) {}

            @Deprecated("Deprecated in ComponentCallbacks")
            override fun onLowMemory() {
                discardWarmPages()
            }
        })
    }
}
