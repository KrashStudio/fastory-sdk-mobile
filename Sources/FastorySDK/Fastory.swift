import UIKit
import WebKit

public protocol FastoryEventsDelegate: AnyObject {
    func fastoryHubOpened(fanzoneSlug: String)
    func fastoryHubClosed()
    func fastoryGameOpened(slug: String)
    func fastoryGameClosed()
    func fastoryExternalLink(url: URL)

    /// A bridge message the web surface posted through the versioned envelope (SPEC §13).
    /// Only types in the SDK's registry reach here; everything else is dropped.
    func fastoryBridgeMessage(type: String, payload: [String: Any])

    func fastoryIdentityResolved(_ identity: FastoryResolvedIdentity)

    /// A hub or a game that did not load (SPEC § 9.1). The host is the only party that can decide
    /// what to do about it — log it, alert its team, offer the fan something else — so the SDK
    /// reports and never retries on its own.
    func fastorySurfaceLoadFailed(_ failure: FastoryLoadFailure)
}

public extension FastoryEventsDelegate {
    // Defaulted so a host written against the five v0.1 events keeps compiling: all three callbacks
    // are added to a protocol that already ships inside third-party integrations.
    func fastoryBridgeMessage(type: String, payload: [String: Any]) {}

    func fastoryIdentityResolved(_ identity: FastoryResolvedIdentity) {}

    func fastorySurfaceLoadFailed(_ failure: FastoryLoadFailure) {}
}

public enum Fastory {
    /// Guards `config` and `identity` only. They are the two pieces of state written from a thread
    /// the SDK does not choose — `configure` stores the configuration on whatever thread the host
    /// called it on (§ 2.7) — while every reader is on the main thread. Android marks the same two
    /// fields `@Volatile`, for the same reason and no more broadly.
    ///
    /// Everything else here is **main-thread-only by construction**, which is a stronger guarantee
    /// than a lock and is why it does not take one: `warmHubWebView` and `memoryWarningObserver` are
    /// touched from `configure`'s main-thread hop, from the hub view controller, and from the
    /// memory-pressure observer, all three on the main queue; `hubViewController` and
    /// `eventsDelegate` are UIKit objects that have no other legal home.
    private static let stateLock = NSLock()
    private static var storedConfig: FastoryConfig?
    private static var storedIdentity: FastoryResolvedIdentity?

    public static var config: FastoryConfig? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedConfig
    }

    public static weak var eventsDelegate: FastoryEventsDelegate?
    private static weak var hubViewController: FastoryHubViewController?
    private static var warmHubWebView: WKWebView?
    /// The configuration `warmHubWebView`'s page was loaded under — never the current one.
    ///
    /// A teardown at `configure` time cannot be enough on its own: the hub can be **re-stashed after
    /// it ran**, by a dismissal that happens after a re-configure, and it comes back holding the
    /// previous fanzone. The stamp is what makes the check total — a page is reusable only for the
    /// configuration it was rendered for, whenever it was put there.
    private static var warmHubConfig: FastoryConfig?
    /// Whether `warmHubWebView`'s page has committed a document.
    ///
    /// Tracked rather than read back off the WebView, and that is the whole point: `WKWebView.url`
    /// is the **active** URL, set the instant `load()` is called, so a page that has only *started*
    /// loading already has one. A hub presented inside that window would announce itself open on a
    /// page that then fails — the defect this release exists to close, reintroduced by the cheapest
    /// available check. Android's `WebView.getUrl()` genuinely lags to the committed page, so the
    /// same expression is correct there and wrong here.
    private static var warmHubDidCommit = false
    /// Retained because `WKWebView.navigationDelegate` is weak, and an unretained one would leave the
    /// warm-up unwatched again the moment it went out of scope (§ 9.1).
    private static var warmUpObserver: FastoryWarmUpObserver?
    private static var memoryWarningObserver: NSObjectProtocol?
    private static var didBecomeActiveObserver: NSObjectProtocol?

    /// The identity the SDK currently carries: `nil` until the first successful `identify`, and
    /// again after `logout()`.
    public static var identity: FastoryResolvedIdentity? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedIdentity
    }

    /// Stores the configuration and hands back the one it replaced, so the caller decides what the
    /// replacement invalidates without a second lock acquisition racing the first.
    private static func store(config: FastoryConfig) -> FastoryConfig? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let previous = storedConfig
        storedConfig = config
        return previous
    }

    private static func store(identity: FastoryResolvedIdentity?) {
        stateLock.lock()
        storedIdentity = identity
        stateLock.unlock()
    }

    /// Callable from any thread (SPEC § 2.7), and it returns without doing the work that would make
    /// that a lie: the configuration is stored on the calling thread, and everything the platform
    /// restricts to the main thread is hopped there.
    ///
    /// The order matters and is not cosmetic. Storing the configuration synchronously is what keeps
    /// `configure(); openGames()` legal — `openGames` refuses on a nil configuration, so a deferred
    /// store would turn a correct sequence into a refusal. Revoking the standing bridge answer
    /// synchronously is what keeps § 13.8.6 airtight: deferred, it would leave a window in which the
    /// previous configuration's credential is still handed out.
    public static func configure(_ config: FastoryConfig) {
        do {
            try config.validate()
        } catch {
            // Kept non-throwing for source compatibility. A rejected configuration is not
            // stored, so it never opens someone else's fanzone or a blank hub — but note what
            // that leaves standing: returning here also skips the teardown below, so a
            // configuration already in force keeps applying and openGames() opens *it*.
            // "openGames() reports not configured" is only the first-call case (SPEC § 2.1).
            assertionFailure("Fastory.configure(_:) rejected the configuration: \(error)")
            return
        }
        let previous = store(config: config)
        // A configure that replaces the configuration invalidates what the previous one produced,
        // before anything new is prepared (SPEC § 2.1):
        //
        //  - the warm hub renders the previous fanzone, so keeping it makes the next openGames()
        //    present the old configuration's page under the new one;
        //  - the standing bridge answer was minted for the previous environment and workspace, so
        //    serving it under the next one hands a production token to a staging page (§ 13.8.6).
        //
        // Here rather than inside warmUpHub(), which is the trap this closes: warming up returns
        // early when there is nothing to warm — the whole publishable-key path — so a teardown that
        // lived past that guard would never run on the very configurations that need it.
        //
        // Nothing to invalidate on the first call, and a host may legitimately set the standing
        // answer before configuring, so revoking there would drop a value it never got to use.
        let replacesConfiguration = previous != nil && previous != config
        if replacesConfiguration {
            FastoryBridgeResponder.revokeAll()
        }
        onMain {
            if replacesConfiguration {
                discardWarmHub()
            }
            FastoryWorkspaceResolver.shared.reset()
            // Configured by key, the fanzone to open is only known once the API answers. Start the
            // exchange now so openGames() usually finds it already resolved.
            FastoryWorkspaceResolver.shared.resolve(config: config)
            warmUpHubOnceTheHostIsOnScreen()
        }
    }

    /// The one method that MUST be called on the main thread (SPEC § 2.7), and the only one that can
    /// say so honestly: it takes the host's own `UIViewController`, so a caller holding one is
    /// already in UI code.
    public static func openGames(from presenter: UIViewController) {
        guard let config else {
            assertionFailure("Fastory.configure(_:) must be called before openGames(from:)")
            return
        }
        guard hubViewController == nil else {
            return
        }
        let hub = FastoryHubViewController(config: config)
        hubViewController = hub
        presenter.present(hub, animated: true)
    }

    public static func close() {
        // Callable from any thread, unlike `openGames`: a host closing the hub is often doing it from
        // a completion handler it does not control the queue of.
        onMain { hubViewController?.dismiss(animated: true) }
    }

    // MARK: - Identity

    /// Binds the host app's user to a Fastory fan. See `SPEC.md` § 2.6.
    ///
    /// Non-blocking and non-throwing: every outcome arrives through `completion`, on the main
    /// thread. Only `.anonymous` resolves in this version; the two identified modes are reserved
    /// signatures that fail with `identify_mode_unavailable` (§ 2.6).
    public static func identify(
        _ requested: FastoryIdentity,
        completion: ((Result<FastoryResolvedIdentity, FastoryIdentifyError>) -> Void)? = nil
    ) {
        guard Thread.isMainThread else {
            onMain { identify(requested, completion: completion) }
            return
        }
        guard let config = config else {
            completion?(.failure(.notConfigured))
            return
        }
        let transition = FastoryIdentityRules.transition(requesting: requested, from: identity)
        if let error = transition.error {
            completion?(.failure(error))
            return
        }
        guard let resolved = transition.resolved else {
            completion?(.failure(.network))
            return
        }
        apply(transition, config: config) {
            // Set before emitting, so a delegate reading Fastory.identity sees the new fan.
            store(identity: resolved)
            if transition.emitsIdentityResolved {
                eventsDelegate?.fastoryIdentityResolved(resolved)
            }
            completion?(.success(resolved))
        }
    }

    /// Signs the fan out of Fastory only — the host application's own session is never touched
    /// (§ 12). Idempotent, and needs no network call.
    public static func logout(completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            onMain { logout(completion: completion) }
            return
        }
        let transition = FastoryIdentityRules.logout(from: identity)
        apply(transition, config: config) {
            store(identity: nil)
            completion?()
        }
    }

    private static func apply(
        _ transition: FastoryIdentityTransition,
        config: FastoryConfig?,
        then: @escaping () -> Void
    ) {
        // Before the erasure and outside its guard: revocation needs no configuration and no store,
        // and `logout()` revokes even when it has no session to erase (SPEC § 13.8.2).
        if transition.revokesBridgeReplies {
            FastoryBridgeResponder.revokeAll()
        }
        guard transition.erasesStorage, let config else {
            then()
            return
        }
        // Both were built before this transition, so they hold the previous fan's rendered page.
        discardWarmHub()
        FastoryWebsiteDataEraser.erase(
            origins: FastoryIdentityStorage.origins(for: config),
            completion: then
        )
    }

    // MARK: - Hub keep-alive

    // The hub WebView is created and loaded at configure() and retained across sessions, so
    // openGames() presents an already-rendered page instead of reloading every time. Dropped on
    // re-configure (the hub URL may change) and under memory pressure.

    /// The warm page and whether it has committed, handed over together: they are one fact about one
    /// page, and reading the second anywhere else would let it answer for a different one.
    static func takeWarmHubWebView() -> (webView: WKWebView, hasCommitted: Bool)? {
        // Nothing warm is not a mismatch. Reaching the discard below on an empty slot would flush the
        // preloader on every cold open — and the games in it were discovered from the hub that is
        // opening, so it would throw away exactly what the fan is about to tap.
        guard let webView = warmHubWebView else { return nil }
        guard warmHubConfig == config else {
            // Rendered for another configuration: presenting it under the current one is the
            // whole defect, so it is dropped rather than handed over (SPEC § 2.1).
            discardWarmHub()
            return nil
        }
        let hasCommitted = warmHubDidCommit
        warmHubWebView = nil
        warmHubConfig = nil
        warmHubDidCommit = false
        // The hub view controller becomes the page's navigation delegate, so the warm-up's own is
        // done watching. Kept only as long as it has something to watch.
        warmUpObserver = nil
        return (webView, hasCommitted)
    }

    /// `config` is the one the page was **loaded** under, which the caller holds and the SDK may no
    /// longer have: a hub dismissed after a re-configure is exactly the case this parameter exists
    /// for, and reading `Fastory.config` here would bless the stale page instead of catching it.
    ///
    /// `hasCommitted` travels with the page for the same reason: a hub stashed back on dismissal
    /// knows whether its document ever committed, and the next presentation cannot work it out.
    static func stashWarmHubWebView(
        _ webView: WKWebView,
        config: FastoryConfig,
        hasCommitted: Bool
    ) {
        warmHubWebView = webView
        warmHubConfig = config
        warmHubDidCommit = hasCommitted
    }

    /// Drops the warm page only if the slot still holds it. The warm-up's observer reports a failure
    /// a main-thread turn late, and a presentation can take the page inside that turn — discarding
    /// then would flush the preloader for the hub that is opening.
    static func discardWarmHub(ifStillHolding webView: WKWebView) {
        guard warmHubWebView === webView else { return }
        discardWarmHub()
    }

    /// Read-only view of the warm slot. `takeWarmHubWebView()` empties it, so a case that has to
    /// check the slot *and* leave it as it found it has nothing else to read.
    static var warmHubWebViewForTesting: WKWebView? { warmHubWebView }

    /// The warm-up's page committed a document — reported by the observer watching that load, which
    /// is the only thing that can see it.
    static func warmHubPageDidCommit() {
        warmHubDidCommit = true
    }

    // Warm game webviews live in FastoryGamePreloader: games are preloaded from the hub's
    // own game list, and a played game is rebuilt fresh right after its sheet closes.

    static func watchHubForPreloading(_ webView: WKWebView) {
        guard let config else { return }
        FastoryGamePreloader.shared.watchHub(webView, config: config)
    }

    /// Resolves the fanzone to open, and its slug — the `hubOpened` event carries it. Immediate on
    /// the deprecated slug path; on the publishable key path it waits for
    /// `/sdk/auth/bootstrap`, which `configure` already started.
    static func resolveHub(
        _ completion: @escaping (Result<(url: URL, fanzoneSlug: String), FastoryBootstrapError>) -> Void
    ) {
        guard let config else {
            completion(.failure(.unreachable))
            return
        }
        if let slug = config.fanzoneSlug {
            completion(.success((url: config.hubURL(fanzoneSlug: slug), fanzoneSlug: slug)))
            return
        }
        FastoryWorkspaceResolver.shared.whenResolved(config: config) { result in
            completion(result.map {
                (url: config.hubURL(fanzoneSlug: $0.slug), fanzoneSlug: $0.slug)
            })
        }
    }

    /// The fan asked again from the error view (§ 9). Kept apart from `resolveHub` so that only this
    /// caller can discard a remembered failure — `FastoryWorkspaceResolver.rearmAfterFailure` carries
    /// why that separation matters. A no-op on the deprecated slug path, where nothing is exchanged.
    static func retryHubResolution() {
        FastoryWorkspaceResolver.shared.rearmAfterFailure()
    }

    /// Warms the hub only once the host application is on screen.
    ///
    /// Allocating a `WKWebView` starts a WebKit content process and `load()` starts a network fetch,
    /// and a host configures the SDK from `application(_:didFinishLaunchingWithOptions:)` — the exact
    /// moment the club app is drawing its first screen. Done inline, the SDK competes with that first
    /// paint against a budget (16 ms) it has no way to honour there. Deferred to `didBecomeActive`,
    /// the work lands after the first frame, and a **background launch** — a common way to reach
    /// `configure` — warms nothing at all until there is a screen to be fast for.
    ///
    /// One observer, re-read at fire time rather than captured: the configuration in force when the
    /// app comes to the foreground is the one to warm, not the one that armed the observer.
    private static func warmUpHubOnceTheHostIsOnScreen() {
        guard !hostIsOnScreen() else {
            warmUpHub()
            return
        }
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            if let observer = didBecomeActiveObserver {
                NotificationCenter.default.removeObserver(observer)
                didBecomeActiveObserver = nil
            }
            warmUpHub()
        }
    }

    /// Whether the host application has a screen up. Seam for tests: a suite cannot foreground its
    /// own test host, and a case that skipped itself on that account would assert nothing on the one
    /// runner that matters.
    static var hostIsOnScreen: () -> Bool = { UIApplication.shared.applicationState == .active }

    /// The SDK's own main-thread hop, used by every entry point the host may call from any thread
    /// (§ 2.7). `identify` and `logout` re-enter themselves through it rather than wrapping a block,
    /// because they have to re-read the identity *after* the hop, not before it.
    ///
    /// Inline when already on the main thread, so `configure(); openGames()` from UI code behaves
    /// exactly as it did before this existed — a hop that always deferred would push the resolver's
    /// start behind the presentation that waits on it.
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private static func warmUpHub() {
        guard hubViewController == nil, let config else { return }
        // Already warm for this configuration — nothing to do, and doing it anyway is what SPEC § 2.1
        // forbids on an equal re-configure: the flush below would drop every preloaded game and the
        // rendered page would be replaced by one still loading, so a harmless call would be paid for
        // as a cold open. Android's `preloadHub` has always carried this guard; iOS did not.
        guard warmHubWebView == nil else { return }
        FastoryGamePreloader.shared.flush()
        // Only the slug path can warm up synchronously. On the key path the hub view controller
        // resolves and loads on presentation — warming a webview for an unknown URL is pointless.
        guard let hubURL = config.staticHubURL else { return }
        let webView = FastoryWebKit.makeWebView()
        FastoryGamePreloader.shared.watchHub(webView, config: config)
        // A warm-up nobody watches keeps whatever it loaded, error page included (§ 9.1). The
        // observer is retained here because `navigationDelegate` is weak, and it is dropped with the
        // page it watches — the hub view controller takes the delegate over on presentation.
        let observer = FastoryWarmUpObserver()
        webView.navigationDelegate = observer
        warmUpObserver = observer
        webView.load(URLRequest(url: hubURL))
        warmHubWebView = webView
        warmHubConfig = config
        // Nothing has committed yet — the observer says when it does.
        warmHubDidCommit = false
        observeMemoryPressureOnce()
    }

    /// Drops the warm hub and every preloaded game. Named rather than inlined in the memory-pressure
    /// observer because an identity transition needs the same teardown (§ 7.4) — a warm hub is built
    /// at `configure()`, necessarily before any `identify()`, so it always carries the previous
    /// session's rendered state.
    static func discardWarmHub() {
        warmHubWebView = nil
        warmHubConfig = nil
        warmHubDidCommit = false
        warmUpObserver = nil
        FastoryGamePreloader.shared.flush()
    }

    // MARK: - The bridge reply channel (SPEC §13.8)

    /// What the SDK answers the next time a web surface asks for `type` over the bridge — the fan
    /// token a game requests from its host page, in the place of the host page it does not have.
    ///
    /// Standing rather than resolved on demand: the game asks while it boots, so an answer that has
    /// to be fetched would stall its first paint, and §13.5 forbids network or disk on this path
    /// anyway. Set it before opening a game; `nil` clears it, and a cleared type is answered with an
    /// explicit failure rather than with silence.
    ///
    /// A payload that cannot be serialised to JSON is refused and the current answer left as it was —
    /// non-throwing like `configure`, and traced at debug level.
    public static func setBridgeReply(for type: FastoryBridgeRequestType, payload: [String: Any]?) {
        FastoryBridgeResponder.setReply(for: type, payload: payload)
    }

    // MARK: - Test seam

    /// Hands the next suite an unconfigured SDK.
    ///
    /// `config`, `identity` and the standing bridge answers are process-wide, and the public
    /// contract has no "unconfigure" — deliberately: a host that could drop a configuration would
    /// have a way to leave the SDK half-alive. So a suite that configures cannot undo it, and every
    /// test asserting *pre-configure* behaviour would silently depend on running before the first
    /// one that configures. That is not a hypothetical: the invalidation cases of § 13.8.2 configure
    /// by key, and they sort before the identify contracts.
    static func resetForTesting() {
        stateLock.lock()
        storedConfig = nil
        storedIdentity = nil
        stateLock.unlock()
        warmHubWebView = nil
        warmHubConfig = nil
        warmHubDidCommit = false
        warmUpObserver = nil
        // Both seams below are process-wide and are the ones a suite is most likely to stub and
        // forget: left stubbed, every later case that expects a load — or a deferred discard —
        // silently gets none.
        FastoryWarmUpObserver.scheduleDiscard = { work in DispatchQueue.main.async(execute: work) }
        FastoryGamePreloader.shared.startLoad = FastoryGamePreloader.performLoad
        FastoryGamePreloader.shared.scheduleTimeout = FastoryGamePreloader.performScheduleTimeout
        FastoryGamePreloader.shared.flush()
        hostIsOnScreen = { UIApplication.shared.applicationState == .active }
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            didBecomeActiveObserver = nil
        }
        FastoryWorkspaceResolver.shared.reset()
        FastoryBridgeResponder.revokeAll()
    }

    private static func observeMemoryPressureOnce() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            discardWarmHub()
        }
    }
}
