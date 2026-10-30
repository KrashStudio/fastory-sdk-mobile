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
    ///
    /// `fastory:login-requested` (empty payload) means a fan tapped a sign-in entry on a page. It is
    /// posted only when `FastoryConfig.handlesLoginRequests` is declared: sign the fan in your own
    /// way, then call `Fastory.identify`, and the hub on screen reloads signed in.
    func fastoryBridgeMessage(type: String, payload: [String: Any])

    func fastoryIdentityResolved(_ identity: FastoryResolvedIdentity)

    /// The SDK dropped a delegated identity **on its own** (SPEC § 5.3): a session that expired with
    /// no way to renew, or a background re-exchange the API refused. The fan is now anonymous. The
    /// host learns why through `revocation.reason` so it can re-`identify` with a fresh token or let
    /// the fan continue anonymously — never a blank panel. A host-driven `logout()` is not a
    /// revocation and never fires this.
    func fastoryIdentityRevoked(_ revocation: FastoryIdentityRevocation)

    /// The membership panel is presented on a page that loaded (SPEC § 5.3). It carries nothing:
    /// the panel opens the one page the workspace's publishable key resolves, so there is no
    /// identifier the host could not already know.
    func fastoryMembershipOpened()

    /// The membership panel is dismissed. Owed exactly once per panel that opened, and never for
    /// one whose page did not load (SPEC § 9.1).
    func fastoryMembershipClosed()

    /// A surface that did not load (SPEC § 9.1). The host is the only party that can decide
    /// what to do about it — log it, alert its team, offer the fan something else — so the SDK
    /// reports and never retries on its own.
    func fastorySurfaceLoadFailed(_ failure: FastoryLoadFailure)
}

public extension FastoryEventsDelegate {
    // Defaulted so a host written against an earlier event set keeps compiling: every callback here
    // was added to a protocol that already ships inside third-party integrations.
    func fastoryBridgeMessage(type: String, payload: [String: Any]) {}

    func fastoryIdentityResolved(_ identity: FastoryResolvedIdentity) {}

    func fastoryIdentityRevoked(_ revocation: FastoryIdentityRevocation) {}

    func fastoryMembershipOpened() {}

    func fastoryMembershipClosed() {}

    func fastorySurfaceLoadFailed(_ failure: FastoryLoadFailure) {}
}

/// Hands the SDK a fresh host assertion when it needs to renew a delegated session. Registered with
/// `Fastory.setHostTokenProvider`, called on a background turn, and answered through `completion` —
/// with a new JWT, or `nil` when the host cannot supply one (the session then lapses to anonymous).
/// Asynchronous on purpose: fetching a token may itself be a round trip, and blocking the SDK on it
/// would violate § 2.7.
public typealias FastoryHostTokenProvider = (@escaping (String?) -> Void) -> Void

public enum Fastory {
    /// Guards `config` and `identity` only. They are the two pieces of state written from a thread
    /// the SDK does not choose — `configure` stores the configuration on whatever thread the host
    /// called it on (§ 2.7) — while every reader is on the main thread. Android marks the same two
    /// fields `@Volatile`, for the same reason and no more broadly.
    ///
    /// Everything else here is **main-thread-only by construction**, which is a stronger guarantee
    /// than a lock and is why it does not take one: `warmPages` and `memoryWarningObserver` are
    /// touched from `configure`'s main-thread hop, from the surface view controllers, and from the
    /// memory-pressure observer, all three on the main queue; `presentedSurface` and
    /// `eventsDelegate` are UIKit objects that have no other legal home.
    private static let stateLock = NSLock()
    private static var storedConfig: FastoryConfig?
    private static var storedIdentity: FastoryResolvedIdentity?
    /// The embed session the last `identify(.hostToken)` resolved, kept so the hub can mint a fresh
    /// single-use handoff from it at load time. Guarded like the two fields above, cleared whenever
    /// the fan behind it goes (logout, `identify(.anonymous)`, a failed resolution, a configuration
    /// that is replaced).
    private static var storedDelegatedSessionToken: String?
    /// The origin the delegated session is bound to. Renewal (`/embed/auth/refresh`) must present the
    /// same one, and it is not recoverable from the token, so it is kept beside it.
    private static var storedDelegatedOrigin: String?
    /// Registered by `setHostTokenProvider`. Guarded because a host may set it from any thread (§ 2.7).
    private static var storedHostTokenProvider: FastoryHostTokenProvider?

    public static var config: FastoryConfig? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedConfig
    }

    public static weak var eventsDelegate: FastoryEventsDelegate?

    /// The surface on screen, whichever of the two it is — one reference rather than one per kind.
    ///
    /// What `openGames` and `openMembership` both have to answer is "is anything of the SDK's up?":
    /// stacking one over the other would give the host two openings for one screen, and leave
    /// `close()` returning the fan to the surface underneath instead of to the application.
    private static weak var presentedSurface: FastoryHubViewController?

    /// One prepared page per surface, kept between openings (SPEC § 11).
    ///
    /// Keyed rather than held in a field apiece: the hub's rules and the panel's are the same rules,
    /// and the one thing that keeps two resident pages apart is which slot each is read from — a hub
    /// that took the panel's page would open the workspace's bot under the Games entry, and stash it
    /// back over the hub's on the way out.
    private static var warmPages: [FastorySurface: WarmPage] = [:]

    /// A page prepared ahead of a presentation, with everything that presentation needs to decide
    /// whether it may use it.
    private struct WarmPage {
        let webView: WKWebView
        /// The address the page was **asked for** — never wherever it ended up, which the fan's
        /// own navigation moves. A presentation reuses it only for the address it is asking for:
        /// the same surface at two addresses is two documents, and the panel opened on a sequence
        /// is exactly that. Compared rather than reasoned about from the arguments a call carried,
        /// so the next parameter that reaches one of these URLs is covered by it.
        let url: URL?
        /// The configuration the page was loaded under — never the current one.
        ///
        /// A teardown at `configure` time cannot be enough on its own: a page can be **re-stashed
        /// after it ran**, by a dismissal that happens after a re-configure, and it comes back
        /// holding the previous workspace. The stamp is what makes the check total — a page is
        /// reusable only for the configuration it was rendered for, whenever it was put there.
        let config: FastoryConfig
        /// Whether the page has committed a document.
        ///
        /// Tracked rather than read back off the WebView, and that is the whole point: `WKWebView.url`
        /// is the **active** URL, set the instant `load()` is called, so a page that has only *started*
        /// loading already has one. A surface presented inside that window would announce itself open
        /// on a page that then fails, reintroduced by the cheapest available check. Android's
        /// `WebView.getUrl()` genuinely lags to the committed page, so the same expression is correct
        /// there and wrong here.
        var hasCommitted: Bool
        /// Retained because `WKWebView.navigationDelegate` is weak, and an unretained observer would
        /// leave the warm-up unwatched again the moment it went out of scope (§ 9.1). Nil for a page
        /// handed back by a presentation, which watched its own load.
        var observer: FastoryWarmUpObserver?
    }

    private static var failedWarmWebViews: [WKWebView] = []
    private static var memoryWarningObserver: NSObjectProtocol?
    private static var didBecomeActiveObserver: NSObjectProtocol?
    private static var identityGeneration = 0
    static var eraseWebsiteData: ([URL], @escaping () -> Void) -> Void = {
        FastoryWebsiteDataEraser.erase(origins: $0, completion: $1)
    }

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

    /// The embed session token behind the current delegated identity, read on the main thread when
    /// the hub resolves so it can mint a handoff.
    static var delegatedSessionToken: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedDelegatedSessionToken
    }

    private static func store(delegatedSessionToken token: String?) {
        stateLock.lock()
        storedDelegatedSessionToken = token
        stateLock.unlock()
    }

    /// The origin the current delegated session is bound to, read when renewal needs it.
    static var delegatedSessionOrigin: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedDelegatedOrigin
    }

    private static func store(delegatedOrigin origin: String?) {
        stateLock.lock()
        storedDelegatedOrigin = origin
        stateLock.unlock()
    }

    static var hostTokenProvider: FastoryHostTokenProvider? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedHostTokenProvider
    }

    /// Registers the closure the SDK calls to obtain a fresh host assertion when a delegated session
    /// must be renewed (SPEC § 2.6.3). Callable from any thread; `nil` clears it. Setting it does not
    /// itself renew anything — it is consulted the next time a session nears expiry or a refresh is
    /// refused.
    public static func setHostTokenProvider(_ provider: FastoryHostTokenProvider?) {
        stateLock.lock()
        storedHostTokenProvider = provider
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
        let replacesConfiguration = previous != nil && previous != config
        if replacesConfiguration {
            FastoryBridgeResponder.revokeAll()
            // The session was minted against the previous environment and workspace, so it must not
            // survive into the next one — same reason the standing answer it fed is revoked here.
            // The persisted identity was stamped under the previous configuration too, so it goes with
            // it (the stamp would refuse it on load anyway; purging keeps the store honest meanwhile).
            store(identity: nil)
            clearDelegatedSession()
        } else {
            // A fresh configuration (first call, or the same one) may have a persisted fan to show at
            // once — the panel starts identified rather than blank, then a background re-exchange
            // confirms it (SPEC § 2.6.3). Read synchronously so `configure(); identity` already
            // carries it; no event is emitted from the cache.
            rehydratePersistedIdentity(config: config)
        }
        onMain {
            if replacesConfiguration {
                discardWarmPages()
                cancelRenewal()
            }
            FastoryWorkspaceResolver.shared.reset()
            // Configured by key, neither the fanzone nor the workspace is known until the API
            // answers. Start the exchange now so a presentation usually finds it already resolved.
            FastoryWorkspaceResolver.shared.resolve(config: config)
            warmUpOnceTheHostIsOnScreen()
            confirmRehydratedIdentity(config: config)
        }
    }

    /// Restores a persisted delegated identity for this configuration, if there is one and the SDK is
    /// not already identified. Only the identity is restored — the session behind it is re-established
    /// by `confirmRehydratedIdentity`. No `identityResolved` from the cache: it announces a resolution,
    /// and this is a restoration.
    private static func rehydratePersistedIdentity(config: FastoryConfig) {
        guard identity == nil, let persisted = FastoryIdentityPersistence.load(config: config) else {
            return
        }
        store(identity: persisted)
    }

    /// Re-establishes the session behind a rehydrated identity by re-exchanging a fresh host assertion
    /// in the background — so the games get a live token and the identity is confirmed or dropped. A
    /// no-op unless a fan was rehydrated and a provider is registered: with no provider the identity
    /// stays shown but the first game is anonymous until the host identifies again.
    private static func confirmRehydratedIdentity(config: FastoryConfig) {
        guard identity?.mode == .hostToken, delegatedSessionToken == nil else { return }
        guard hostTokenProvider != nil else { return }
        reexchangeThroughProvider(config: config, completion: nil)
    }

    /// The one method that MUST be called on the main thread (SPEC § 2.7), and the only one that can
    /// say so honestly: it takes the host's own `UIViewController`, so a caller holding one is
    /// already in UI code.
    public static func openGames(from presenter: UIViewController) {
        guard let config else {
            assertionFailure("Fastory.configure(_:) must be called before openGames(from:)")
            return
        }
        guard presentedSurface == nil else {
            return
        }
        let hub = FastoryHubViewController(config: config)
        presentedSurface = hub
        presenter.present(hub, animated: true)
    }

    /// Presents the workspace's membership panel — its bot, full-screen, with the host owning
    /// dismissal (SPEC § 3.5). Main thread, for the reason `openGames(from:)` is.
    ///
    /// Two call sites have nothing to open and are programmer errors, so each asserts in a
    /// development build and returns: an unconfigured SDK, and one configured with the deprecated
    /// fanzone slug, which names a fanzone and never the workspace this page is addressed by.
    /// A surface already presented is neither — it returns silently, which is the guarantee
    /// `openGames(from:)` carries, read across both surfaces rather than per kind, since a double
    /// tap on a tab bar is the ordinary way to reach it.
    ///
    /// `sequenceId` opens the panel on one of the workspace's sequences; naming none, or naming a
    /// blank one, opens it on its default screen.
    public static func openMembership(from presenter: UIViewController, sequenceId: String? = nil) {
        guard let config else {
            assertionFailure("Fastory.configure(_:) must be called before openMembership(from:)")
            return
        }
        guard config.publishableKey != nil else {
            assertionFailure(
                "openMembership(from:) needs a publishable key: the fanzone slug names a fanzone, "
                    + "never the workspace this surface is addressed by"
            )
            return
        }
        guard presentedSurface == nil else {
            return
        }
        let panel = FastoryHubViewController(
            config: config,
            surface: .membership,
            resolve: { completion in resolveMembership(sequenceId: sequenceId, completion) }
        )
        presentedSurface = panel
        presenter.present(panel, animated: true)
    }

    public static func close() {
        // Callable from any thread, unlike the two openings: a host closing a surface is often doing
        // it from a completion handler it does not control the queue of.
        onMain { presentedSurface?.fastoryDismissPresentedThenSelf(animated: true) }
    }

    // MARK: - Identity

    /// Binds the host app's user to a Fastory fan. See `SPEC.md` § 2.6.
    ///
    /// Non-blocking and non-throwing: every outcome arrives through `completion`, on the main
    /// thread. `.anonymous` resolves synchronously, `.hostToken` resolves through a server-side
    /// exchange with no browser and no form, and `.fanId` signs the fan in through the system
    /// browser — never a WebView — then exchanges the returned code for the same session (§ 2.6).
    ///
    /// `.anonymous` over an identified fan drops that fan the way `logout()` does — session,
    /// renewal, and the identity kept across launches — and a hub on screen reloads anonymous (§ 7).
    /// Over an SDK already anonymous it does nothing.
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
        if case .hostToken(let jwt) = requested {
            identifyHostToken(jwt: jwt, config: config, completion: completion)
            return
        }
        if case .fanId = requested {
            identifyFanId(config: config, completion: completion)
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
            // A resolved change that revokes the standing answer — `identify(.anonymous)` over a
            // delegated fan — is a different identity, so a live game re-asks and gets `unavailable`
            // (SPEC § 13.9.2). An idempotent same-identity call does not revoke and stays silent.
            if transition.revokesBridgeReplies {
                FastorySessionPush.broadcast()
            }
            if transition.emitsIdentityResolved {
                eventsDelegate?.fastoryIdentityResolved(resolved)
            }
            completion?(.success(resolved))
        }
    }

    /// Resolves `identify(.hostToken)` — the partner already authenticated the fan, so the JWT is
    /// forwarded for server-side verification and nothing is typed or opened (§ 2.6, § 12).
    ///
    /// Two pre-flight rejections come first and leave the current identity untouched (§ 2.6.1): a
    /// blank JWT, and a slug configuration, which carries no workspace to exchange against — the mode
    /// is unavailable until the host configures by publishable key. Everything after the exchange is
    /// a resolution outcome, so a failure lands the SDK on anonymous rather than on the previous fan.
    private static func identifyHostToken(
        jwt: String,
        config: FastoryConfig,
        completion: ((Result<FastoryResolvedIdentity, FastoryIdentifyError>) -> Void)?
    ) {
        guard !jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion?(.failure(.invalidHostToken))
            return
        }
        guard config.publishableKey != nil else {
            completion?(.failure(.modeUnavailable(.hostToken)))
            return
        }
        // The session is bound to the games' origin, because the games are what read this token over
        // the bridge; the hub adopts the same session through a handoff instead. Development has no
        // stories origin, so it falls back to the base URL exactly as game-URL construction does.
        let origin = config.environment.storiesOrigin ?? config.environment.baseURL
        let originString = FastoryBridgeResponder.origin(of: origin) ?? origin.absoluteString

        FastoryWorkspaceResolver.shared.whenResolved(config: config) { result in
            switch result {
            case .failure(let bootstrapError):
                failIdentifiedResolution(
                    FastoryIdentityExchangeClassifier.error(from: bootstrapError),
                    config: config,
                    completion: completion
                )
            case .success(let workspace):
                FastoryDelegatedSessionClient.shared.exchange(
                    jwt: jwt,
                    workspaceId: workspace.id,
                    origin: originString,
                    environment: config.environment
                ) { exchange in
                    switch exchange {
                    case .failure(let error):
                        failIdentifiedResolution(error, config: config, completion: completion)
                    case .success(let session):
                        resolveIdentifiedFan(
                            session, mode: .hostToken, origin: originString,
                            config: config, completion: completion
                        )
                    }
                }
            }
        }
    }

    /// Resolves `identify(.fanId)` — the fan signs in to Fastory in the **system browser** (§ 2.6):
    /// the platform's reference OpenID client opens the login, and the returned single-use code is
    /// exchanged server-side for the same session `.hostToken` gets. Nothing renders in a WebView,
    /// which is also the only path that reaches the device's password manager.
    ///
    /// The pre-flight is the same as `.hostToken`: a slug configuration carries no publishable key
    /// to prove the caller with, so the mode is unavailable (§ 2.6.1, identity untouched). The
    /// workspace is resolved first so a refused key fails before any browser opens. A dismissed
    /// browser is `login_cancelled`; like every resolution failure, it lands the SDK on anonymous.
    private static func identifyFanId(
        config: FastoryConfig,
        completion: ((Result<FastoryResolvedIdentity, FastoryIdentifyError>) -> Void)?
    ) {
        guard let publishableKey = config.publishableKey else {
            completion?(.failure(.modeUnavailable(.fanId)))
            return
        }
        let origin = config.environment.storiesOrigin ?? config.environment.baseURL
        let originString = FastoryBridgeResponder.origin(of: origin) ?? origin.absoluteString

        FastoryWorkspaceResolver.shared.whenResolved(config: config) { result in
            switch result {
            case .failure(let bootstrapError):
                failIdentifiedResolution(
                    FastoryIdentityExchangeClassifier.error(from: bootstrapError),
                    config: config,
                    completion: completion
                )
            case .success:
                guard let applicationId = FastoryWorkspaceResolver.shared.applicationId(),
                      !applicationId.isEmpty,
                      let redirectURI = URL(string: "\(applicationId)://fastory/callback") else {
                    // The exchange would be refused without the identifier, so refuse in its place —
                    // the same code the key exchange uses for the same absence (§ 2.5).
                    failIdentifiedResolution(
                        .rejected(code: "sdk_application_id_required"),
                        config: config,
                        completion: completion
                    )
                    return
                }
                let login = FastoryFanLoginRequest(
                    authorizationEndpoint: config.environment.baseURL
                        .appendingPathComponent("auth/sdk/authorize"),
                    tokenEndpoint: config.environment.embedTokenURL,
                    clientId: publishableKey,
                    redirectURI: redirectURI
                )
                FastoryFanLoginController.shared.performLogin(login) { outcome in
                    onMain {
                        switch outcome {
                        case .failure(.cancelled):
                            failIdentifiedResolution(.loginCancelled, config: config, completion: completion)
                        case .failure(.failed):
                            failIdentifiedResolution(.network, config: config, completion: completion)
                        case .success(let granted):
                            FastoryDelegatedSessionClient.shared.exchangeLoginCode(
                                code: granted.code,
                                codeVerifier: granted.codeVerifier,
                                publishableKey: publishableKey,
                                applicationId: applicationId,
                                environment: config.environment
                            ) { exchange in
                                switch exchange {
                                case .failure(let error):
                                    failIdentifiedResolution(error, config: config, completion: completion)
                                case .success(let session):
                                    resolveIdentifiedFan(
                                        session, mode: .fanId, origin: originString,
                                        config: config, completion: completion
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func resolveIdentifiedFan(
        _ session: FastoryDelegatedSession,
        mode: FastoryIdentityMode,
        origin: String,
        config: FastoryConfig,
        completion: ((Result<FastoryResolvedIdentity, FastoryIdentifyError>) -> Void)?
    ) {
        let resolved = FastoryResolvedIdentity(mode: mode, fanId: session.fanId)
        let transition = FastoryIdentityRules.afterResolution(resolved, from: identity)
        // `apply` revokes the previous fan's standing answer when the fan changed; the fresh token is
        // set right after, so a different fan is revoke-then-populate and the same fan is a refresh.
        apply(transition, config: config) {
            store(identity: resolved)
            adoptDelegatedSession(session, origin: origin, config: config)
            if transition.emitsIdentityResolved {
                // A different fan now stands behind the answer; a same-fan re-identify is idempotent
                // and stays observable as nothing, this channel included (SPEC § 13.9.2).
                FastorySessionPush.broadcast()
                eventsDelegate?.fastoryIdentityResolved(resolved)
            }
            completion?(.success(resolved))
        }
    }

    /// Records a freshly minted delegated session and everything that hangs off it: the token the
    /// hub hands off and the games read over the bridge, the identity kept across launches, and the
    /// renewal armed to fire before it expires. The one place all four are set, so a renewal and a
    /// first resolution leave the SDK in the same state.
    private static func adoptDelegatedSession(
        _ session: FastoryDelegatedSession,
        origin: String,
        config: FastoryConfig
    ) {
        store(delegatedSessionToken: session.token)
        store(delegatedOrigin: origin)
        FastoryBridgeResponder.setReply(for: .userToken, payload: ["token": session.token])
        if let resolved = identity {
            FastoryIdentityPersistence.save(resolved, config: config)
        }
        armDelegatedRenewal(for: session.token)
    }

    private static func failIdentifiedResolution(
        _ error: FastoryIdentifyError,
        config: FastoryConfig,
        completion: ((Result<FastoryResolvedIdentity, FastoryIdentifyError>) -> Void)?
    ) {
        let transition = FastoryIdentityRules.afterResolutionFailure(from: identity)
        apply(transition, config: config) {
            store(identity: nil)
            completion?(.failure(error))
        }
    }

    // MARK: - Host-token lifecycle (SPEC § 2.6.3, § 5.3)

    /// How long before a session's `exp` the SDK renews it, so the fan never meets a dead session in
    /// the middle of a game or a purchase. A functional lead time, not a performance budget.
    private static let renewalLeadTime: TimeInterval = 120

    /// How long to wait before retrying a renewal that failed on the network (not a refusal). A fixed
    /// backoff rather than `exp`-based, so a lost connection retries steadily instead of spinning on an
    /// already-expired token.
    private static let renewalRetryDelay: TimeInterval = 30

    /// The armed renewal. Main-thread-only by construction, like the warm-hub state — it is set and
    /// cancelled from `configure`'s hop, the identity transitions, and the timer's own fire.
    private static var renewalWorkItem: DispatchWorkItem?
    private static var renewalForegroundObserver: NSObjectProtocol?

    /// Schedules the renewal work. Seam for tests: a suite replaces it so no wall-clock timer fires
    /// mid-run, and drives `renewDelegatedSessionNow` directly instead.
    static var renewalSchedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Arms renewal to fire `renewalLeadTime` before the session's `exp`, and re-arms a foreground
    /// check so a session that expired while the app was backgrounded is caught on return. A token
    /// with no readable `exp` is treated as due now rather than trusted for an unknown lifetime.
    private static func armDelegatedRenewal(for token: String) {
        renewalWorkItem?.cancel()
        let expiry = FastoryDelegatedSessionClient.expiry(of: token) ?? Date()
        let delay = max(0, expiry.addingTimeInterval(-renewalLeadTime).timeIntervalSinceNow)
        let work = DispatchWorkItem { renewDelegatedSessionNow() }
        renewalWorkItem = work
        renewalSchedule(delay, work)
        observeForegroundForRenewalOnce()
    }

    /// Re-arms a renewal after `renewalRetryDelay` when the last attempt failed on the network. A
    /// stale retry is harmless — `renewDelegatedSessionNow` no-ops once the session is gone — and it
    /// is cancelled with any other by `cancelRenewal`.
    private static func armDelegatedRenewalRetry() {
        renewalWorkItem?.cancel()
        let work = DispatchWorkItem { renewDelegatedSessionNow() }
        renewalWorkItem = work
        renewalSchedule(renewalRetryDelay, work)
        observeForegroundForRenewalOnce()
    }

    private static func observeForegroundForRenewalOnce() {
        guard renewalForegroundObserver == nil else { return }
        renewalForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Only if the session is now within its renewal window — a foreground far from expiry
            // leaves the armed timer to do the work at the right moment.
            guard let token = delegatedSessionToken else { return }
            let expiry = FastoryDelegatedSessionClient.expiry(of: token) ?? Date()
            if expiry.addingTimeInterval(-renewalLeadTime).timeIntervalSinceNow <= 0 {
                renewDelegatedSessionNow()
            }
        }
    }

    /// Renews the current delegated session once (SPEC § 2.6.3). Tries the cheap path first —
    /// `/embed/auth/refresh`, involving no one — and falls back to a fresh host assertion from the
    /// provider only when the refresh is refused. Callable from the armed timer, the foreground
    /// observer, or a test.
    static func renewDelegatedSessionNow(completion: (() -> Void)? = nil) {
        guard let token = delegatedSessionToken,
              let origin = delegatedSessionOrigin,
              let config = config else {
            completion?()
            return
        }
        FastoryDelegatedSessionClient.shared.refresh(
            sessionToken: token,
            origin: origin,
            environment: config.environment
        ) { result in
            switch result {
            case .success(let renewed):
                // The same session extended: identity and persistence are untouched, only the token
                // the games read is swapped and the renewal re-armed (fixture: session_expiring).
                store(delegatedSessionToken: renewed)
                FastoryBridgeResponder.setReply(for: .userToken, payload: ["token": renewed])
                // The standing answer changed under a live game — tell it to re-read (SPEC § 13.9).
                FastorySessionPush.broadcast()
                armDelegatedRenewal(for: renewed)
                completion?()
            case .failure:
                reexchangeThroughProvider(config: config, completion: completion)
            }
        }
    }

    /// The refresh was refused, so the session itself is no longer renewable. Ask the host for a
    /// fresh assertion and re-exchange it (fixture: refresh_refused). No provider, or a provider that
    /// hands back nothing, means the session simply lapses — revoked with `reason: expired`.
    private static func reexchangeThroughProvider(
        config: FastoryConfig,
        completion: (() -> Void)?
    ) {
        guard let provider = hostTokenProvider else {
            revokeDelegatedSession(FastoryIdentityRevocation(reason: .expired), config: config, completion: completion)
            return
        }
        provider { freshToken in
            onMain {
                guard let jwt = freshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !jwt.isEmpty else {
                    revokeDelegatedSession(FastoryIdentityRevocation(reason: .expired), config: config, completion: completion)
                    return
                }
                FastoryWorkspaceResolver.shared.whenResolved(config: config) { result in
                    switch result {
                    case .failure(let bootstrapError):
                        finishReexchange(
                            .failure(FastoryIdentityExchangeClassifier.error(from: bootstrapError)),
                            origin: nil, config: config, completion: completion
                        )
                    case .success(let workspace):
                        let bound = config.environment.storiesOrigin ?? config.environment.baseURL
                        let origin = FastoryBridgeResponder.origin(of: bound) ?? bound.absoluteString
                        FastoryDelegatedSessionClient.shared.exchange(
                            jwt: jwt,
                            workspaceId: workspace.id,
                            origin: origin,
                            environment: config.environment
                        ) { exchange in
                            finishReexchange(exchange, origin: origin, config: config, completion: completion)
                        }
                    }
                }
            }
        }
    }

    private static func finishReexchange(
        _ exchange: Result<FastoryDelegatedSession, FastoryIdentifyError>,
        origin: String?,
        config: FastoryConfig,
        completion: (() -> Void)?
    ) {
        switch exchange {
        case .success(let session):
            let resolved = FastoryResolvedIdentity(mode: .hostToken, fanId: session.fanId)
            let transition = FastoryIdentityRules.afterResolution(resolved, from: identity)
            apply(transition, config: config) {
                store(identity: resolved)
                adoptDelegatedSession(session, origin: origin ?? "", config: config)
                // A re-exchange is a renewal: the session behind the standing answer is fresh whether
                // or not the fan changed, so the live game re-reads it unconditionally (SPEC § 13.9).
                FastorySessionPush.broadcast()
                if transition.emitsIdentityResolved {
                    eventsDelegate?.fastoryIdentityResolved(resolved)
                }
                completion?()
            }
        case .failure(let error):
            // A refusal drops the fan and tells the host why. A network failure did not refuse
            // anything, so it keeps the identity and re-arms a bounded retry rather than signing a fan
            // out over a lost connection — the armed timer that fired this renewal is spent, so without
            // this the session would stay identified but never renew again until the host acted.
            switch error {
            case .rejected(let code):
                revokeDelegatedSession(FastoryIdentityRevocation(reason: .rejected, code: code), config: config, completion: completion)
            default:
                armDelegatedRenewalRetry()
                completion?()
            }
        }
    }

    /// Drops a delegated session the SDK could not keep (SPEC § 5.3): erase, revoke the standing
    /// answer, purge the persisted identity, land on anonymous, and tell the host why. The one path
    /// that emits `identityRevoked` — a host-driven `logout` never comes through here.
    private static func revokeDelegatedSession(
        _ revocation: FastoryIdentityRevocation,
        config: FastoryConfig,
        completion: (() -> Void)? = nil
    ) {
        let transition = FastoryIdentityRules.afterResolutionFailure(from: identity)
        // `apply`'s erasure is asynchronous, so the identity is only actually cleared and the event
        // only fired inside `then` — completing before that would report a revocation that has not
        // happened yet.
        apply(transition, config: config) {
            store(identity: nil)
            // The standing answer was revoked, so a live game must re-ask and get `unavailable`,
            // which is how it learns the fan is gone (SPEC § 13.9).
            FastorySessionPush.broadcast()
            eventsDelegate?.fastoryIdentityRevoked(revocation)
            completion?()
        }
    }

    /// Forgets the delegated session state that is lock-guarded and thread-safe to clear from any
    /// thread — the token, its origin, and the persisted identity. The armed renewal is main-thread
    /// state, disarmed separately by `cancelRenewal`.
    private static func clearDelegatedSession() {
        store(delegatedSessionToken: nil)
        store(delegatedOrigin: nil)
        FastoryIdentityPersistence.purge()
    }

    /// Disarms the renewal timer. Main-thread-only, like the work item it cancels.
    private static func cancelRenewal() {
        renewalWorkItem?.cancel()
        renewalWorkItem = nil
    }

    /// Signs the fan out of Fastory only — the host application's own session is never touched
    /// (§ 12). Idempotent, and needs no network call.
    public static func logout(completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            onMain { logout(completion: completion) }
            return
        }
        let transition = FastoryIdentityRules.logout(from: identity)
        // A sign-out wins over a fanId login still in the system browser: cancelling it drives its
        // completion to `.cancelled`, so it cannot re-identify the fan after this logout has run.
        FastoryFanLoginController.shared.cancelInFlight()
        apply(transition, config: config) {
            store(identity: nil)
            // logout() revoked the standing answer — a live game re-asks and gets `unavailable`
            // (SPEC § 13.9). The host gets no event: it made the call and already knows.
            FastorySessionPush.broadcast()
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
            clearDelegatedSession()
            cancelRenewal()
        }
        // Read before anything moves, compared once `then` has stored the identity it lands on and
        // the session the hub hands off. Reloading inside the erasure's window would load the
        // previous fan's cookies, or have the erasure remove the new fan's (SPEC § 7).
        let fanBefore = identity?.fanId
        let settle = {
            then()
            reloadPresentedHubIfTheFanChanged(from: fanBefore)
        }
        guard transition.erasesStorage, let config else {
            settle()
            return
        }
        identityGeneration += 1
        // All of them were built before this transition, so they hold the previous fan's rendered
        // page.
        discardWarmPages()
        eraseWebsiteData(FastoryIdentityStorage.origins(for: config), settle)
    }

    /// A hub on screen follows the identified fan (SPEC § 2.6.1, § 7): it reloads, through the
    /// session handoff `resolveHub` mints, when the transition changed *which* fan is identified, and
    /// only then. Anonymous and not identified both carry no `fanId`, so moving between them reloads
    /// nothing, and neither does the same fan identified again or renewed. The panel is not
    /// reloaded, and a game learns the change from the session-change signal.
    private static func reloadPresentedHubIfTheFanChanged(from fanBefore: String?) {
        guard identity?.fanId != fanBefore else { return }
        presentedSurface?.reloadAfterIdentityChange()
    }

    // MARK: - Keep-alive, one page per surface

    /// The warm page, the address it carries and whether it has committed, handed over together:
    /// they are one fact about one page, and reading either of the last two anywhere else would let
    /// it answer for a different one.
    static func takeWarmPage(
        for surface: FastorySurface
    ) -> (webView: WKWebView, url: URL?, hasCommitted: Bool)? {
        // Nothing warm is not a mismatch. Reaching the discard below on an empty slot would flush the
        // preloader on every cold open — and the games in it were discovered from the hub that is
        // opening, so it would throw away exactly what the fan is about to tap.
        guard let page = warmPages[surface] else { return nil }
        guard page.config == config else {
            // Rendered for another configuration: presenting it under the current one is the
            // whole defect, so it is dropped rather than handed over (SPEC § 2.1).
            discardWarmPage(for: surface)
            return nil
        }
        // The view controller becomes the page's navigation delegate, so the warm-up's own observer
        // is done watching: it goes with the entry.
        warmPages[surface] = nil
        return (page.webView, page.url, page.hasCommitted)
    }

    /// `config` is the one the page was **loaded** under, which the caller holds and the SDK may no
    /// longer have: a surface dismissed after a re-configure is exactly the case this parameter
    /// exists for, and reading `Fastory.config` here would bless the stale page instead of catching
    /// it.
    ///
    /// `hasCommitted` travels with the page for the same reason: a surface stashed back on dismissal
    /// knows whether its document ever committed, and the next presentation cannot work it out.
    ///
    /// `url` is the address the surface **asked for**, and it travels for a third reason of its own:
    /// `webView.url` is wherever the page ended, which a fan browsing the hub moves at will. Read
    /// off the page, the slot would come back stamped with a deep address no opening ever asks for,
    /// and every reopening would reload a document already rendered.
    static func stashWarmPage(
        _ webView: WKWebView,
        for surface: FastorySurface,
        url: URL?,
        config: FastoryConfig,
        hasCommitted: Bool
    ) {
        warmPages[surface] = WarmPage(
            webView: webView,
            url: url,
            config: config,
            hasCommitted: hasCommitted,
            observer: nil
        )
    }

    static func warmPageDidFail(_ webView: WKWebView, surface: FastorySurface) {
        guard warmPages[surface]?.webView === webView else { return }
        discardWarmPage(for: surface)
        failedWarmWebViews.append(webView)
    }

    static func releaseFailedWarmWebView(_ webView: WKWebView) {
        failedWarmWebViews.removeAll { $0 === webView }
    }

    /// Read-only views of the two slots: `takeWarmPage(for:)` empties a slot, so these are the only
    /// way to look at one and leave it as it was.
    static var warmHubWebViewForTesting: WKWebView? { warmPages[.hub]?.webView }

    static var warmMembershipWebViewForTesting: WKWebView? { warmPages[.membership]?.webView }

    /// The warm-up's page committed a document — reported by the observer watching that load, which
    /// is the only thing that can see it.
    static func warmPageDidCommit(surface: FastorySurface) {
        warmPages[surface]?.hasCommitted = true
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
        _ completion: @escaping (Result<(url: URL, fanzoneSlug: String?), FastoryBootstrapError>) -> Void
    ) {
        guard let config else {
            completion(.failure(.unreachable))
            return
        }
        // A resolved slug becomes the hub URL, then adopts the fan's session through a handoff when
        // one exists. The slug path never carries a session — `identify(.hostToken)` needs a
        // publishable key — so it is the plain hub URL, exactly as before.
        let deliver: (String) -> Void = { slug in
            let hubURL = config.hubURL(fanzoneSlug: slug)
            hubURLAdoptingSession(hubURL, config: config) { finalURL in
                completion(.success((url: finalURL, fanzoneSlug: slug)))
            }
        }
        if let slug = config.fanzoneSlug {
            deliver(slug)
            return
        }
        FastoryWorkspaceResolver.shared.whenResolved(config: config) { result in
            switch result {
            case .success(let workspace):
                deliver(workspace.slug)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Turns a plain hub URL into one that adopts the current delegated session, by minting a
    /// single-use handoff token at load time (its window is short, so it is minted now and not at
    /// `identify`). A failed mint falls back to the plain URL: an anonymous hub is better than a hub
    /// that does not open. No session means the URL is unchanged.
    private static func hubURLAdoptingSession(
        _ hubURL: URL,
        config: FastoryConfig,
        completion: @escaping (URL) -> Void
    ) {
        guard let sessionToken = delegatedSessionToken else {
            completion(hubURL)
            return
        }
        FastoryDelegatedSessionClient.shared.mintHandoff(
            sessionToken: sessionToken,
            environment: config.environment
        ) { handoff in
            guard let handoff else {
                completion(hubURL)
                return
            }
            completion(handoffURL(base: config.environment.baseURL, handoff: handoff, callback: hubURL))
        }
    }

    /// The handoff URL a hub loads to adopt a session: `/auth/handoff` on the fanzone origin, carrying
    /// the single-use token and the hub path to land on once the session cookie is set. `callbackUrl`
    /// is kept relative — the route resolves it against its own origin and refuses anything that is
    /// not same-origin.
    static func handoffURL(base: URL, handoff: String, callback: URL) -> URL {
        let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        var relativePath = callbackComponents?.path ?? "/"
        if let query = callbackComponents?.query {
            relativePath += "?\(query)"
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/auth/handoff"
        components.queryItems = [
            URLQueryItem(name: "token", value: handoff),
            URLQueryItem(name: "callbackUrl", value: relativePath),
        ]
        return components.url ?? callback
    }

    /// Resolves the membership panel's address (SPEC § 3.5). It is built on the workspace identifier
    /// the key exchange already returned, so this waits on that exchange and sends nothing of its
    /// own; the deprecated slug path resolves no workspace and therefore no panel.
    ///
    /// The panel announces itself with no identifier of its own, so nothing here has to be named
    /// before it can open — hence the nil slug.
    static func resolveMembership(
        sequenceId: String?,
        _ completion: @escaping (Result<(url: URL, fanzoneSlug: String?), FastoryBootstrapError>) -> Void
    ) {
        guard let config, config.publishableKey != nil else {
            completion(.failure(.unreachable))
            return
        }
        FastoryWorkspaceResolver.shared.whenResolved(config: config) { result in
            completion(result.map {
                (
                    url: config.membershipURL(workspaceId: $0.id, sequenceId: sequenceId),
                    fanzoneSlug: nil
                )
            })
        }
    }

    /// The fan asked again from the error view (§ 9). Kept apart from `resolveHub` so that only this
    /// caller can discard a remembered failure — `FastoryWorkspaceResolver.rearmAfterFailure` carries
    /// why that separation matters. A no-op on the deprecated slug path, where nothing is exchanged.
    static func retryHubResolution() {
        FastoryWorkspaceResolver.shared.rearmAfterFailure()
    }

    private static func warmUpOnceTheHostIsOnScreen() {
        // Nothing asked for is nothing to wait for: no page, and no observer left armed for one.
        guard config?.surfacesToPrewarm.isEmpty == false else { return }
        guard !hostIsOnScreen() else {
            warmUpSurfaces()
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
            warmUpSurfaces()
        }
    }

    /// Whether the host application has a screen up. Replaceable because the warm-up gates on it and
    /// the platform's own answer cannot be set from outside.
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

    /// Prepares the surfaces the configuration asks for, on the one trigger the hub has always used —
    /// the host's first painted screen.
    ///
    /// The hub alone unless the host asks for more (SPEC § 2.1): a prepared page is a WebView
    /// resident from launch on, with the requests its page makes, so a host that never opens the
    /// panel must not pay for one.
    private static func warmUpSurfaces() {
        guard presentedSurface == nil, let config else { return }
        guard !config.surfacesToPrewarm.isEmpty else { return }
        if let hubURL = config.staticHubURL {
            // The deprecated slug path names a fanzone and never a workspace, so the hub is all it can
            // have asked for (SPEC § 3.5).
            prepareWarmPage(.hub, at: hubURL, for: config)
            return
        }
        guard config.publishableKey != nil else { return }
        let generation = identityGeneration
        FastoryWorkspaceResolver.shared.whenResolved(config: config) { result in
            guard case .success(let workspace) = result else { return }
            warmUpSurfaces(for: workspace, config: config, identityGeneration: generation)
        }
    }

    private static func warmUpSurfaces(
        for workspace: FastoryWorkspace,
        config: FastoryConfig,
        identityGeneration generation: Int
    ) {
        guard config == Fastory.config,
              presentedSurface == nil,
              generation == identityGeneration else { return }
        guard hostIsOnScreen() else {
            warmUpOnceTheHostIsOnScreen()
            return
        }
        let surfaces = config.surfacesToPrewarm
        if surfaces.contains(.hub) {
            prepareWarmPage(.hub, at: config.hubURL(fanzoneSlug: workspace.slug), for: config)
        }
        if surfaces.contains(.membership) {
            prepareWarmPage(
                .membership,
                at: config.membershipURL(workspaceId: workspace.id),
                for: config
            )
        }
    }

    private static func prepareWarmPage(
        _ surface: FastorySurface,
        at url: URL,
        for config: FastoryConfig
    ) {
        // Already warm — nothing to do, and doing it anyway is what SPEC § 2.1 forbids on an equal
        // re-configure: the flush below would drop every preloaded game and the rendered page would
        // be replaced by one still loading, so a harmless call would be paid for as a cold open.
        guard warmPages[surface] == nil else { return }
        let webView = FastoryWebKit.makeWebView()
        if surface == .hub {
            // The pool is discovered from the hub's own page, so it belongs to whichever page is in
            // the hub's slot and to no other.
            FastoryGamePreloader.shared.flush()
            FastoryGamePreloader.shared.watchHub(webView, config: config)
        }
        // A warm-up nobody watches keeps whatever it loaded, error page included (§ 9.1). The
        // observer is retained with the page it watches, and dropped with it — the view controller
        // takes the delegate over on presentation.
        let observer = FastoryWarmUpObserver(surface: surface)
        webView.navigationDelegate = observer
        webView.load(URLRequest(url: url))
        // Nothing has committed yet — the observer says when it does.
        warmPages[surface] = WarmPage(
            webView: webView,
            url: url,
            config: config,
            hasCommitted: false,
            observer: observer
        )
        observeMemoryPressureOnce()
    }

    static func discardWarmPages() {
        discardWarmPage(for: .hub)
        discardWarmPage(for: .membership)
    }

    private static func discardWarmPage(for surface: FastorySurface) {
        warmPages[surface] = nil
        // The preloaded games were discovered from the hub's page: losing it loses them. Nothing
        // hangs off the panel's, so emptying that slot must leave the pool alone.
        if surface == .hub {
            FastoryGamePreloader.shared.flush()
        }
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
        // The host changed the answer by hand — set or cleared. A live game re-asks and adopts the
        // new value, or gets `unavailable` on a clear (SPEC § 13.9). No-op when no game is open.
        FastorySessionPush.broadcast()
    }

    // MARK: - Reset

    /// Puts the SDK back to its unconfigured state.
    ///
    /// `config`, `identity` and the standing bridge answers are process-wide, and the public
    /// contract has no "unconfigure" — deliberately: a host that could drop a configuration would
    /// have a way to leave the SDK half-alive. This is the one entry point that undoes a
    /// configuration, and it is not part of the public surface.
    static func resetForTesting() {
        stateLock.lock()
        storedConfig = nil
        storedIdentity = nil
        storedDelegatedSessionToken = nil
        storedDelegatedOrigin = nil
        storedHostTokenProvider = nil
        stateLock.unlock()
        FastoryDelegatedSessionClient.shared.reset()
        FastoryFanLoginController.shared.reset()
        // Disarm any renewal and drop the persisted identity into an isolated, empty suite so no
        // case fires a real timer or inherits another's stored fan. The scheduling seam is
        // process-wide and, like the load/discard seams below, silently starves the next case if
        // left stubbed.
        cancelRenewal()
        if let observer = renewalForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
            renewalForegroundObserver = nil
        }
        renewalSchedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        FastoryIdentityPersistence.store = UserDefaults(suiteName: "com.fastory.sdk.tests")
            ?? .standard
        FastoryIdentityPersistence.purge()
        warmPages.removeAll()
        failedWarmWebViews.removeAll()
        if let observer = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            didBecomeActiveObserver = nil
        }
        // Both seams below are process-wide and are the ones a suite is most likely to stub and
        // forget: left stubbed, every later case that expects a load — or a deferred discard —
        // silently gets none.
        FastoryWarmUpObserver.scheduleDiscard = { work in DispatchQueue.main.async(execute: work) }
        FastoryGamePreloader.shared.startLoad = FastoryGamePreloader.performLoad
        FastoryGamePreloader.shared.scheduleTimeout = FastoryGamePreloader.performScheduleTimeout
        FastoryGamePreloader.shared.flush()
        FastoryWorkspaceResolver.shared.performRequest = { request, completion in
            URLSession.shared.dataTask(with: request) { data, response, error in
                completion(data, response, error)
            }.resume()
        }
        FastoryWorkspaceResolver.shared.applicationId = { Bundle.main.bundleIdentifier }
        identityGeneration = 0
        // Unlike the request seams, the erase resets to a no-op rather than the real eraser: a
        // per-origin erase on the test host's data store takes seconds, long enough to time out a
        // case awaiting an identity transition. A case asserting erasure stubs its own recorder.
        eraseWebsiteData = { _, done in done() }
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
            // Every resident WebView is one to give back when the system asks.
            discardWarmPages()
        }
    }
}
