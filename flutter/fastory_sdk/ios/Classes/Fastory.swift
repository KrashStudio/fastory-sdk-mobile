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
    /// way, then call `Fastory.identify`, and the hub or panel on screen reloads signed in.
    ///
    /// `fastory:logout-requested` (empty payload) means a fan tapped a sign-out entry on a page,
    /// under the same declaration. The SDK signs nobody out on it: ask the fan to confirm, then call
    /// `Fastory.logout`. Never sign the fan out on receipt — the message is a request, not proof
    /// that the fan tapped.
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
    /// A `fanId` fan's refresh token as last read or stored, with the Keychain account and the
    /// environment it belongs to — so letting it go erases and revokes the right one even once the
    /// configuration it was issued under has been replaced. A restored fan's token is held unread
    /// until the launch read lands, so letting it go before then still revokes what the Keychain
    /// holds. Guarded like the session above.
    private static var storedRefreshToken: HeldRefreshToken?
    /// Advanced by every `logout()`, `identify` and replacing `configure` (SPEC § 2.6.3): a renewal
    /// answer or a Keychain read that returns under an older generation is ignored. Guarded, since a
    /// replacing `configure` advances it on the caller's thread.
    private static var storedSessionGeneration = 0
    /// Whether a `fanId` fan's launch renewal is awaited (SPEC § 13.8.2). Set on the thread that
    /// rehydrates the fan, so a request that arrives before the main thread has started the renewal
    /// already waits for it.
    private static var storedLaunchWaitPending = false
    /// Numbers the launch waits begun, so a page loaded during one knows which answer it reads.
    private static var storedLaunchWait = 0
    /// The fan whose session each ended launch wait answered its held requests with, nil with none.
    private static var storedLaunchWaitOutcomes: [Int: String?] = [:]

    private struct HeldRefreshToken {
        /// `nil` while the token is in the Keychain and has not been read yet.
        let token: String?
        let account: String
        let environment: FastoryEnvironment
    }

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

    /// The opening that `presentedSurface` answered, so a `close()` asked before a later opening
    /// never takes that later one down.
    private static var presentedSurfaceRequest = 0

    /// An opening asked for while a surface was leaving, or while the controller it was asked from
    /// was in a transition — the system browser sheet of a sign-in going away is the ordinary case.
    /// Both are moments UIKit refuses a presentation in, and an opening dropped there is a tap the
    /// fan made that silently did nothing (SPEC § 2.1). One at most: the first wins, as it does
    /// while a surface is on screen.
    private struct PendingOpening {
        let surface: FastorySurface
        let sequenceId: String?
        /// The controller the opening will be presented on, read with `settledAncestor`. Weak: it is
        /// the host's, and a host that let it go has nothing left to show a surface on.
        weak var anchor: UIViewController?
        /// The surface of the SDK this opening waits on, when it waits on one. Weak, so a surface
        /// released without ever disappearing shows up as gone rather than as still leaving.
        weak var awaited: FastoryHubViewController?
        let awaitsSurface: Bool
        let request: Int
    }

    private static var pendingOpening: PendingOpening?
    /// The request whose turn is queued. A queued turn cannot be withdrawn: one queued for an
    /// opening `close()` dropped must not serve the next opening with what was left of its deadline.
    private static var queuedTurnRequest: Int?

    /// Counts the openings accepted, under `stateLock`: `close()` reads it on the caller's thread,
    /// before its hop to the main thread, so it only cancels what was asked before it.
    private static var openingRequests = 0

    /// One main-thread turn later, as a waiting opening reads the presenter again. Replaceable so the
    /// turns can be driven explicitly rather than waited for.
    static var schedulePendingOpenTurn: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(
            deadline: .now() + FastoryHubViewController.closeTurnInterval,
            execute: work
        )
    }
    /// How many turns a waiting opening reads a presenter still in transition before trying anyway —
    /// about two seconds, longer than any dismissal animation UIKit runs.
    static let pendingOpenTurnBudget = 120

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
        /// The session the page read, stamped when it started loading and carried with it like
        /// `config` — never the one in force when it is put in the slot.
        ///
        /// The panel's page asks for the fan's session once, when it loads, and is reused on its
        /// address alone: a page that read none would open the fan who has since signed in, or
        /// whose session has since landed, as anonymous (SPEC § 3.5). Read at stash time instead,
        /// a panel on screen while the same fan's session lands — which nothing reloads — would
        /// go back stamped with a session its page never had. The hub reads only the stamp's
        /// `generation`: a fan with a session reopens it through a handoff address its warm page
        /// never has, but one whose handoff could not be minted opens it on the plain address, and
        /// that page must still not outlive an erasure.
        let session: PageSession
    }

    /// What a page's request for the fan's session reads (SPEC § 3.5, § 13.8.2), and the
    /// `pageGeneration` when the page started loading: an erasure since then means the page may hold
    /// the previous fan's rendered screen, even under an address an anonymous opening asks for.
    enum PageSession: Equatable {
        /// The fan whose session stood when the page started loading, nil with none.
        case read(String?, generation: Int)
        /// Loaded while a launch wait held those requests: the page reads whatever that wait ends
        /// with, which is not known yet.
        case awaitingLaunch(Int, generation: Int)

        var generation: Int {
            switch self {
            case .read(_, let generation), .awaitingLaunch(_, let generation):
                return generation
            }
        }
    }

    /// The fan whose session a page loaded now could read: the identified fan once a delegated
    /// session stands for them, nil before that. An identity without a `fanId` still has a session,
    /// so it reads as an empty name rather than as none.
    private static var sessionFan: String? {
        delegatedSessionToken == nil ? nil : (identity?.fanId ?? "")
    }

    /// The stamp of a page that starts loading now.
    static var pageSession: PageSession {
        let fan = sessionFan
        let generation = pageGeneration
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLaunchWaitPending
            ? .awaitingLaunch(storedLaunchWait, generation: generation)
            : .read(fan, generation: generation)
    }

    /// Whether a page stamped `stamp` holds the session in force now. One whose launch wait is
    /// still pending does: its request is held, and will be answered as a page loaded now would.
    private static func readsCurrentSession(_ stamp: PageSession) -> Bool {
        let fan = sessionFan
        switch stamp {
        case .read(let read, _):
            return read == fan
        case .awaitingLaunch(let wait, _):
            stateLock.lock()
            let outcome = storedLaunchWaitOutcomes[wait]
            stateLock.unlock()
            guard let answered = outcome else { return true }
            return answered == fan
        }
    }

    private static var failedWarmWebViews: [WKWebView] = []
    private static var memoryWarningObserver: NSObjectProtocol?
    private static var didBecomeActiveObserver: NSObjectProtocol?
    private static var identityGeneration = 0
    /// Bumped as an erasing transition starts and again when its erasure completes, and stamped on
    /// each page as it starts loading: a page of another generation may hold the previous fan's
    /// rendered screen, or have read their cookies while the erasure ran. Not `identityGeneration`,
    /// which the warm-up gates on and which moves only as a transition starts: a warm-up whose
    /// `configure` came during an erasure must still be prepared (SPEC § 2.5).
    private static var pageGeneration = 0
    static var eraseWebsiteData: ([URL], @escaping () -> Void) -> Void = {
        FastoryWebsiteDataEraser.erase(origins: $0, completion: $1)
    }

    /// The identity the SDK currently carries: `nil` until the first successful `identify` — or until
    /// `configure` restores a fan identified on an earlier launch, which emits no `identityResolved`
    /// (SPEC § 2.6.3) — and again after `logout()` or `identityRevoked`.
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

    /// Hands back the refresh token held until now, so the caller decides whether letting it go
    /// revokes it, without a second lock acquisition racing the first.
    private static func swapRefreshToken(_ token: HeldRefreshToken?) -> HeldRefreshToken? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let previous = storedRefreshToken
        storedRefreshToken = token
        return previous
    }

    private static var heldRefreshToken: HeldRefreshToken? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedRefreshToken
    }

    /// Holds the token stored for `config` as unread, unless one is already held.
    private static func holdUnreadRefreshToken(config: FastoryConfig) {
        let unread = HeldRefreshToken(
            token: nil,
            account: FastoryIdentityPersistence.stamp(for: config),
            environment: config.environment
        )
        stateLock.lock()
        if storedRefreshToken == nil {
            storedRefreshToken = unread
        }
        stateLock.unlock()
    }

    private static var sessionGeneration: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedSessionGeneration
    }

    private static func advanceSessionGeneration() {
        stateLock.lock()
        storedSessionGeneration += 1
        stateLock.unlock()
    }

    private static var isLaunchWaitPending: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLaunchWaitPending
    }

    private static func store(launchWaitPending pending: Bool) {
        let fan = sessionFan
        stateLock.lock()
        if pending, !storedLaunchWaitPending {
            storedLaunchWait += 1
        } else if !pending, storedLaunchWaitPending {
            storedLaunchWaitOutcomes.updateValue(fan, forKey: storedLaunchWait)
        }
        storedLaunchWaitPending = pending
        stateLock.unlock()
    }

    /// Where a `fanId` fan's refresh token is kept. Seam for tests, which substitute a store over an
    /// in-memory Keychain.
    static var refreshTokenStore = FastoryRefreshTokenStore()

    /// Whether the device's protected data can be read — `false` until the first unlock after a
    /// restart. Read on the main thread. Replaceable for the reason `hostIsOnScreen` is.
    static var protectedDataAvailable: () -> Bool = { UIApplication.shared.isProtectedDataAvailable }

    /// Schedules the bound on the launch wait. Seam for tests, like `renewalSchedule`.
    static var launchBoundSchedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
            advanceSessionGeneration()
            FastoryBridgeResponder.revokeAll()
            // The session was minted against the previous environment and workspace, so it must not
            // survive into the next one — same reason the standing answer it fed is revoked here.
            // The persisted identity was stamped under the previous configuration too, so it goes with
            // it (the stamp would refuse it on load anyway; purging keeps the store honest meanwhile).
            store(identity: nil)
            clearDelegatedSession(config: previous)
        } else {
            // A fresh configuration (first call, or the same one) may have a persisted fan to show at
            // once — the panel starts identified rather than blank, then a background renewal
            // confirms it (SPEC § 2.6.3). Read synchronously so `configure(); identity` already
            // carries it; no event is emitted from the cache.
            rehydratePersistedIdentity(config: config)
        }
        let generation = sessionGeneration
        onMain {
            if replacesConfiguration {
                discardWarmPages()
                cancelRenewal()
                abandonRenewals()
                endLaunchWait()
            }
            FastoryWorkspaceResolver.shared.reset()
            // Configured by key, neither the fanzone nor the workspace is known until the API
            // answers. Start the exchange now so a presentation usually finds it already resolved.
            FastoryWorkspaceResolver.shared.resolve(config: config)
            warmUpOnceTheHostIsOnScreen()
            startLaunch(config: config, generation: generation)
        }
    }

    /// Restores a persisted delegated identity for this configuration, if there is one and the SDK is
    /// not already identified. Only the identity is restored — the session behind it is re-established
    /// by `startLaunch`. No `identityResolved` from the cache: it announces a resolution, and this is a
    /// restoration. A `fanId` fan's token is awaited from here on, on whichever thread this runs, and
    /// held unread until the launch read lands.
    private static func rehydratePersistedIdentity(config: FastoryConfig) {
        guard identity == nil, let persisted = FastoryIdentityPersistence.load(config: config) else {
            return
        }
        store(identity: persisted)
        if persisted.mode == .fanId {
            holdUnreadRefreshToken(config: config)
            beginLaunchWait()
        }
    }

    /// Re-establishes what the stored identity and refresh token call for, on the main thread, once
    /// per `configure` and again once the device's protected data is found available (SPEC § 2.6.3,
    /// § 2.7, § 7.5): erases the tokens stamped for another configuration, renews a rehydrated fan in
    /// the background — with its refresh token for `fanId`, through the provider for `hostToken` — and
    /// erases a token that has no `fanId` fan beside it. Nothing is concluded while protected data is
    /// unavailable, since an empty read then means *not yet*; a launch that gets past that gate ends
    /// any wait for it, so the wait cannot start a second launch later.
    private static func startLaunch(config: FastoryConfig, generation: Int) {
        guard generation == sessionGeneration, config == Fastory.config, config.publishableKey != nil else {
            endLaunchWait()
            return
        }
        guard protectedDataAvailable() else {
            endLaunchWait()
            renewOnceProtectedDataIsAvailable(config: config, generation: generation)
            return
        }
        stopWaitingForProtectedData()
        sweepOrphanedRefreshTokens(keeping: FastoryIdentityPersistence.stamp(for: config))
        let mode = identity?.mode
        if mode == .fanId, delegatedSessionToken == nil {
            boundLaunchWait()
            renewDelegatedSessionNow()
            return
        }
        endLaunchWait()
        if mode == .hostToken, delegatedSessionToken == nil, hostTokenProvider != nil {
            renewDelegatedSessionNow()
        }
        if mode != .fanId {
            eraseUnpairedRefreshToken(config: config, generation: generation)
        }
    }

    /// Runs the launch again once the device's protected data can be read. Two notifications end the
    /// wait, because the unlock alone is not guaranteed to come: `protectedDataDidBecomeAvailable` is
    /// posted when the device is unlocked, while an app configured before its first activation — from
    /// a SwiftUI `App` initialiser, say — can read the data as unavailable on a device that is never
    /// locked, and then never receives it. The first activation is the other one. Either re-reads the
    /// availability: still unavailable, the wait goes on; available, both observers go and the launch
    /// runs once, whichever of the two arrives first. A wait outlived by its configuration or its
    /// generation ends at its next notification and starts nothing.
    private static func renewOnceProtectedDataIsAvailable(config: FastoryConfig, generation: Int) {
        stopWaitingForProtectedData()
        protectedDataObservers = [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                guard generation == sessionGeneration, config == Fastory.config else {
                    stopWaitingForProtectedData()
                    return
                }
                guard protectedDataAvailable() else { return }
                stopWaitingForProtectedData()
                rehydratePersistedIdentity(config: config)
                startLaunch(config: config, generation: generation)
            }
        }
    }

    private static func stopWaitingForProtectedData() {
        for observer in protectedDataObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        protectedDataObservers.removeAll()
    }

    /// Erases, and revokes where its environment can be read off its stamp, every token the SDK's
    /// Keychain service holds for this app under another configuration than `account` — one left by
    /// an app update that changed its key or its environment (SPEC § 7.5). Another app's items under
    /// the same service are left alone. Once per configuration in force.
    private static func sweepOrphanedRefreshTokens(keeping account: String) {
        guard sweptAccount != account else { return }
        sweptAccount = account
        let store = refreshTokenStore
        store.otherAccounts(keeping: account) { orphans in
            guard let config, FastoryIdentityPersistence.stamp(for: config) == account else { return }
            for orphan in orphans where FastoryIdentityPersistence.belongsToThisApp(account: orphan.account) {
                store.erase(account: orphan.account)
                if let environment = FastoryIdentityPersistence.environment(ofStamp: orphan.account) {
                    FastoryDelegatedSessionClient.shared.revoke(refreshToken: orphan.token, environment: environment)
                }
            }
        }
    }

    /// A token with no `fanId` fan beside it — the identity was lost to a reinstall, or the fan is a
    /// `hostToken` one — renews no one: it is erased, and its family revoked.
    private static func eraseUnpairedRefreshToken(config: FastoryConfig, generation: Int) {
        let account = FastoryIdentityPersistence.stamp(for: config)
        let store = refreshTokenStore
        store.read(account: account) { result in
            guard generation == sessionGeneration,
                  case .eraseToken(let token) = FastoryIdentityPersistence.pairing(identity: identity, token: result) else {
                return
            }
            store.erase(account: account)
            FastoryDelegatedSessionClient.shared.revoke(refreshToken: token, environment: config.environment)
        }
    }

    /// The one method that MUST be called on the main thread (SPEC § 2.7), and the only one that can
    /// say so honestly: it takes the host's own `UIViewController`, so a caller holding one is
    /// already in UI code.
    ///
    /// A call while a surface is on screen does nothing (SPEC § 2.1). A call while one is leaving —
    /// right after `close()`, or from its closing event — or while `presenter` is itself going away,
    /// such as a sign-in's browser sheet, opens the hub once that is over: after the closing event,
    /// never in its place.
    public static func openGames(from presenter: UIViewController) {
        guard config != nil else {
            assertionFailure("Fastory.configure(_:) must be called before openGames(from:)")
            return
        }
        requestOpening(.hub, sequenceId: nil, from: presenter)
    }

    /// Presents the workspace's membership panel — its bot, full-screen, with the host owning
    /// dismissal (SPEC § 3.5). Main thread, for the reason `openGames(from:)` is.
    ///
    /// Two call sites have nothing to open and are programmer errors, so each asserts in a
    /// development build and returns: an unconfigured SDK, and one configured with the deprecated
    /// fanzone slug, which names a fanzone and never the workspace this page is addressed by.
    /// A surface already presented is neither — it returns silently, which is the guarantee
    /// `openGames(from:)` carries, read across both surfaces rather than per kind, since a double
    /// tap on a tab bar is the ordinary way to reach it. A surface leaving, or a `presenter` going
    /// away, delays the panel rather than dropping it, as it does the hub.
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
        requestOpening(.membership, sequenceId: sequenceId, from: presenter)
    }

    /// Takes down the surface and its game sheet, and drops an opening asked for before this call
    /// that is still waiting to be presented — but never one asked for after it.
    public static func close() {
        // Callable from any thread, unlike the two openings: a host closing a surface is often doing
        // it from a completion handler it does not control the queue of. What it closes is fixed
        // here, before the hop, so an opening the host asked for once it called close() survives it
        // — once that opening reaches the main thread after the hop: one asked on the main thread
        // before the hop still finds the surface up, and does nothing, as on Android.
        stateLock.lock()
        let askedBefore = openingRequests
        stateLock.unlock()
        onMain {
            if let pending = pendingOpening, pending.request <= askedBefore {
                pendingOpening = nil
            }
            guard let surface = presentedSurface, presentedSurfaceRequest <= askedBefore else { return }
            surface.markLeaveRequested()
            surface.fastoryDismissPresentedThenSelf(animated: true)
        }
    }

    // MARK: - Openings asked for while something leaves

    private static func requestOpening(
        _ surface: FastorySurface,
        sequenceId: String?,
        from presenter: UIViewController
    ) {
        if let shown = presentedSurface, !shown.isLeaving {
            return
        }
        if let pending = pendingOpening {
            // The first opening wins — unless the surface it waits on was released without ever
            // disappearing: nothing will wake that wait any more, and keeping it would swallow this
            // call, then serve a request the host has since replaced.
            guard pending.awaitsSurface, pending.awaited == nil, queuedTurnRequest != pending.request else {
                return
            }
            pendingOpening = nil
        }
        stateLock.lock()
        openingRequests += 1
        let request = openingRequests
        stateLock.unlock()
        let anchor = settledAncestor(of: presenter)
        let leaving = leavingSurface
        if leaving == nil, isSettled(anchor) {
            present(surface, sequenceId: sequenceId, on: anchor, request: request)
            return
        }
        pendingOpening = PendingOpening(
            surface: surface,
            sequenceId: sequenceId,
            anchor: anchor,
            awaited: leaving,
            awaitsSurface: leaving != nil,
            request: request
        )
        // A surface of the SDK that is leaving says when it has left; only a transition of the
        // host's is read turn by turn.
        if leaving == nil {
            schedulePendingOpening(turnsLeft: pendingOpenTurnBudget)
        }
    }

    /// Called by a surface once it has left and announced it.
    static func surfaceDidLeave() {
        guard pendingOpening != nil else { return }
        schedulePendingOpening(turnsLeft: pendingOpenTurnBudget)
    }

    /// Called by a surface whose dismissal UIKit refused: it is on screen, so an opening waiting on
    /// it is one asked while a surface is up — nothing, as § 2.1 has it.
    static func surfaceStayed() {
        guard leavingSurface == nil else { return }
        pendingOpening = nil
    }

    private static var leavingSurface: FastoryHubViewController? {
        guard let surface = presentedSurface, surface.isLeaving, !surface.hasLeft else { return nil }
        return surface
    }

    private static func schedulePendingOpening(turnsLeft: Int) {
        guard let request = pendingOpening?.request, queuedTurnRequest != request else { return }
        queuedTurnRequest = request
        schedulePendingOpenTurn {
            guard queuedTurnRequest == request else { return }
            queuedTurnRequest = nil
            runPendingOpening(turnsLeft: turnsLeft)
        }
    }

    private static func runPendingOpening(turnsLeft: Int) {
        guard let pending = pendingOpening else { return }
        guard let anchor = pending.anchor else {
            pendingOpening = nil
            return
        }
        guard leavingSurface == nil else { return }
        let presenter = settledAncestor(of: anchor)
        // Kept, not just used: an anchor the host starts closing after the request is released once
        // it has gone, and the wait would have nothing left to present on.
        pendingOpening?.anchor = presenter
        guard isSettled(presenter) || turnsLeft <= 0 else {
            schedulePendingOpening(turnsLeft: turnsLeft - 1)
            return
        }
        pendingOpening = nil
        present(pending.surface, sequenceId: pending.sequenceId, on: presenter, request: pending.request)
    }

    /// The controller to present on: the one handed in, or — when it or anything presenting it is on
    /// its way out, as the surface being closed or a sign-in's browser sheet is — the controller that
    /// presents the highest of those. UIKit refuses a presentation on a controller that is leaving,
    /// and one presented by a leaving controller goes with it: a game sheet over the hub being closed
    /// is released with the hub, and an opening anchored on it would be dropped.
    private static func settledAncestor(of presenter: UIViewController) -> UIViewController {
        var anchor = presenter
        var candidate: UIViewController? = presenter
        while let current = candidate {
            if isLeaving(current), let parent = current.presentingViewController {
                anchor = parent
            }
            candidate = current.presentingViewController
        }
        return anchor
    }

    /// UIKit reports a dismissal on the controller that was presented, never on its children: the
    /// screen of a navigation or tab container the host is closing goes with it while answering
    /// `false` itself, so the containers above it are read too.
    private static func isLeaving(_ controller: UIViewController) -> Bool {
        if let surface = controller as? FastoryHubViewController, surface.isLeaving {
            return true
        }
        var current: UIViewController? = controller
        while let candidate = current {
            if candidate.isBeingDismissed {
                return true
            }
            current = candidate.parent
        }
        return false
    }

    /// Whether UIKit would take a presentation on `presenter` now: no transition in flight, and
    /// nothing it presents still on its way out.
    private static func isSettled(_ presenter: UIViewController) -> Bool {
        guard presenter.transitionCoordinator == nil, !presenter.isBeingDismissed else { return false }
        guard let shown = presenter.presentedViewController else { return true }
        if let surface = shown as? FastoryHubViewController {
            return surface.hasLeft
        }
        return !shown.isBeingDismissed
    }

    private static func present(
        _ surface: FastorySurface,
        sequenceId: String?,
        on presenter: UIViewController,
        request: Int
    ) {
        guard let config else { return }
        let container: FastoryHubViewController
        if surface == .membership {
            guard config.publishableKey != nil else { return }
            container = FastoryHubViewController(
                config: config,
                surface: .membership,
                resolve: { completion in resolveMembership(sequenceId: sequenceId, completion) }
            )
        } else {
            container = FastoryHubViewController(config: config)
        }
        presentedSurface = container
        presentedSurfaceRequest = request
        presenter.present(container, animated: true)
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
    /// renewal, and the identity kept across launches — and the hub or panel on screen reloads
    /// anonymous (§ 7).
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
        startNewGeneration()
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
        startNewGeneration()
        let originString = delegatedOrigin(for: config)

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
        startNewGeneration()
        let originString = delegatedOrigin(for: config)

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
    /// hub hands off and the games read over the bridge, the identity kept across launches, a `fanId`
    /// fan's refresh token, and the renewal armed to fire before it expires. The one place all five are
    /// set, so a renewal and a first resolution leave the SDK in the same state.
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
        keepRefreshToken(of: session, config: config)
        armDelegatedRenewal(for: session.token)
    }

    /// Stores the refresh token a `fanId` session came with, in place of the one held until now. A
    /// token held until now and not spent by this session — a new login, of this fan or another — is
    /// let go: its family is revoked, best effort (SPEC § 2.6.3). A rotation forgets the spent token
    /// before it gets here, since revoking it would end its successor's family too.
    private static func keepRefreshToken(of session: FastoryDelegatedSession, config: FastoryConfig) {
        let account = FastoryIdentityPersistence.stamp(for: config)
        let incoming = identity?.mode == .fanId ? session.refreshToken : nil
        let previous = swapRefreshToken(
            incoming.map { HeldRefreshToken(token: $0, account: account, environment: config.environment) }
        )
        if let previous {
            if previous.token == nil {
                letGoOfUnreadRefreshToken(previous)
            } else if let token = previous.token, token != incoming {
                FastoryDelegatedSessionClient.shared.revoke(refreshToken: token, environment: previous.environment)
            }
        }
        if let incoming {
            refreshTokenStore.write(incoming, account: account)
        } else if let previous {
            refreshTokenStore.erase(account: previous.account)
        }
    }

    /// Lets go of a token held unread — a restored fan dropped before the launch read landed: one
    /// queued read-then-erase, behind that read, and the family of what it read revoked, best effort.
    private static func letGoOfUnreadRefreshToken(_ held: HeldRefreshToken) {
        refreshTokenStore.take(account: held.account) { token in
            guard let token else { return }
            FastoryDelegatedSessionClient.shared.revoke(refreshToken: token, environment: held.environment)
        }
    }

    /// The origin a delegated session is bound to: the games' stories origin, because the games are
    /// what read its token over the bridge; the hub adopts the same session through a handoff instead.
    /// Development has no stories origin, so it falls back to the base URL exactly as game-URL
    /// construction does.
    private static func delegatedOrigin(for config: FastoryConfig) -> String {
        let origin = config.environment.storiesOrigin ?? config.environment.baseURL
        return FastoryBridgeResponder.origin(of: origin) ?? origin.absoluteString
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

    // MARK: - Delegated session lifecycle (SPEC § 2.6.3, § 5.3)

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

    /// Renews the current delegated session (SPEC § 2.6.3). Tries the cheap path first —
    /// `/embed/auth/refresh`, involving no one — and falls back to the mode's own credential only when
    /// the refresh is refused or there is no session to refresh: the stored refresh token for a `fanId`
    /// fan, a fresh host assertion from the provider for a `hostToken` one — never the provider for a
    /// `fanId` fan. Callable from the armed timer, the foreground observer, the launch, or a test.
    ///
    /// One renewal at a time: a call made while one is in flight waits for it, since rotation admits a
    /// single successor and a second presentation would read as a replay.
    static func renewDelegatedSessionNow(completion: (() -> Void)? = nil) {
        guard let config else {
            completion?()
            return
        }
        let generation = sessionGeneration
        if renewalInFlight == generation {
            if let completion {
                renewalWaiters.append(completion)
            }
            return
        }
        if let token = delegatedSessionToken, let origin = delegatedSessionOrigin {
            beginRenewal(generation: generation, completion: completion)
            FastoryDelegatedSessionClient.shared.refresh(
                sessionToken: token,
                origin: origin,
                environment: config.environment
            ) { result in
                guard generation == sessionGeneration else { return }
                switch result {
                case .success(let renewed):
                    // The same session extended: identity and persistence are untouched, only the
                    // token the games read is swapped and the renewal re-armed (fixture:
                    // session_expiring).
                    store(delegatedSessionToken: renewed)
                    FastoryBridgeResponder.setReply(for: .userToken, payload: ["token": renewed])
                    // The standing answer changed under a live game — tell it to re-read (SPEC § 13.9).
                    FastorySessionPush.broadcast()
                    armDelegatedRenewal(for: renewed)
                    finishRenewal()
                case .failure:
                    renewThroughModeCredential(config: config, generation: generation)
                }
            }
            return
        }
        let mode = identity?.mode
        guard mode == .fanId || (mode == .hostToken && hostTokenProvider != nil) else {
            completion?()
            return
        }
        beginRenewal(generation: generation, completion: completion)
        renewThroughModeCredential(config: config, generation: generation)
    }

    private static func renewThroughModeCredential(config: FastoryConfig, generation: Int) {
        if identity?.mode == .fanId {
            renewFanIdSession(config: config, generation: generation)
        } else {
            reexchangeThroughProvider(config: config, generation: generation)
        }
    }

    /// Presents a `fanId` fan's refresh token, read from the Keychain when it is not already held. What
    /// the read finds decides the rest (`FastoryIdentityPersistence.pairing`): a fan whose token is
    /// gone is signed out with no event, and a Keychain that reached no answer signs no one out.
    private static func renewFanIdSession(config: FastoryConfig, generation: Int) {
        let account = FastoryIdentityPersistence.stamp(for: config)
        if let held = heldRefreshToken, held.account == account, let token = held.token {
            presentRefreshToken(token, config: config, generation: generation)
            return
        }
        refreshTokenStore.read(account: account) { result in
            guard generation == sessionGeneration else { return }
            switch FastoryIdentityPersistence.pairing(identity: identity, token: result) {
            case .renew(let token):
                _ = swapRefreshToken(HeldRefreshToken(token: token, account: account, environment: config.environment))
                presentRefreshToken(token, config: config, generation: generation)
            case .signOut:
                signOutWithoutToken(config: config)
            case .waitForUnlock:
                renewOnceProtectedDataIsAvailable(config: config, generation: generation)
                finishRenewal()
            case .retryLater:
                armDelegatedRenewalRetry()
                finishRenewal()
            case .eraseToken, .unchanged:
                finishRenewal()
            }
        }
    }

    /// Presents `token` for a new session. Without the application identifier the grant would be
    /// refused, so the SDK refuses in its place, with the code the key exchange uses for the same
    /// absence (SPEC § 2.5).
    private static func presentRefreshToken(_ token: String, config: FastoryConfig, generation: Int) {
        let origin = delegatedOrigin(for: config)
        guard let publishableKey = config.publishableKey,
              let applicationId = FastoryWorkspaceResolver.shared.applicationId(),
              !applicationId.isEmpty else {
            let revocation = FastoryIdentityRevocation(reason: .rejected, code: "sdk_application_id_required")
            finishReexchange(.refused(revocation), mode: .fanId, origin: origin, config: config, generation: generation)
            return
        }
        FastoryDelegatedSessionClient.shared.refreshGrant(
            refreshToken: token,
            publishableKey: publishableKey,
            applicationId: applicationId,
            environment: config.environment
        ) { result in
            let answer: RenewalAnswer
            switch result {
            case .renewed(let session):
                answer = .renewed(session)
            case .failed(.transient):
                answer = .transient
            case .failed(.refused(let reason, let code)):
                answer = .refused(FastoryIdentityRevocation(reason: reason, code: code))
            }
            finishReexchange(answer, mode: .fanId, origin: origin, config: config, generation: generation)
        }
    }

    /// The refresh was refused, or there is no session to refresh, so the session itself is no longer
    /// renewable. Ask the host for a fresh assertion and re-exchange it (fixture: refresh_refused). No
    /// provider, or a provider that hands back nothing, means the session simply lapses — revoked with
    /// `reason: expired`.
    private static func reexchangeThroughProvider(config: FastoryConfig, generation: Int) {
        let lapsed = RenewalAnswer.refused(FastoryIdentityRevocation(reason: .expired))
        guard let provider = hostTokenProvider else {
            finishReexchange(lapsed, mode: .hostToken, origin: nil, config: config, generation: generation)
            return
        }
        provider { freshToken in
            onMain {
                guard let jwt = freshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !jwt.isEmpty else {
                    finishReexchange(lapsed, mode: .hostToken, origin: nil, config: config, generation: generation)
                    return
                }
                FastoryWorkspaceResolver.shared.whenResolved(config: config) { result in
                    switch result {
                    case .failure(let bootstrapError):
                        finishReexchange(
                            RenewalAnswer(.failure(FastoryIdentityExchangeClassifier.error(from: bootstrapError))),
                            mode: .hostToken, origin: nil, config: config, generation: generation
                        )
                    case .success(let workspace):
                        let origin = delegatedOrigin(for: config)
                        FastoryDelegatedSessionClient.shared.exchange(
                            jwt: jwt,
                            workspaceId: workspace.id,
                            origin: origin,
                            environment: config.environment
                        ) { exchange in
                            finishReexchange(
                                RenewalAnswer(exchange),
                                mode: .hostToken, origin: origin, config: config, generation: generation
                            )
                        }
                    }
                }
            }
        }
    }

    /// What a renewal through the mode's own credential came back with.
    private enum RenewalAnswer {
        case renewed(FastoryDelegatedSession)
        case refused(FastoryIdentityRevocation)
        /// No verdict was reached: nothing was refused.
        case transient

        /// A re-exchange refused by the API is a refusal; anything else it failed on reached no
        /// verdict.
        init(_ exchange: Result<FastoryDelegatedSession, FastoryIdentifyError>) {
            switch exchange {
            case .success(let session):
                self = .renewed(session)
            case .failure(.rejected(let code)):
                self = .refused(FastoryIdentityRevocation(reason: .rejected, code: code))
            case .failure:
                self = .transient
            }
        }
    }

    /// Lands a renewal through the mode's own credential, in the mode the fan signed in with. An answer
    /// that returns under an older generation is ignored: the fan it renews was signed out, replaced or
    /// configured away in the meantime, and applying it would sign them back in. A renewal forgets the
    /// token it presented rather than revoking it: that token is spent, and revoking it would end its
    /// successor's family with it.
    private static func finishReexchange(
        _ answer: RenewalAnswer,
        mode: FastoryIdentityMode,
        origin: String?,
        config: FastoryConfig,
        generation: Int
    ) {
        guard generation == sessionGeneration else { return }
        switch answer {
        case .renewed(let session):
            let resolved = FastoryResolvedIdentity(mode: mode, fanId: session.fanId)
            let transition = FastoryIdentityRules.afterResolution(resolved, from: identity)
            _ = swapRefreshToken(nil)
            apply(transition, config: config) {
                store(identity: resolved)
                adoptDelegatedSession(session, origin: origin ?? "", config: config)
                // A renewal through the credential is a fresh session whether or not the fan changed,
                // so the live game re-reads it unconditionally (SPEC § 13.9).
                FastorySessionPush.broadcast()
                if transition.emitsIdentityResolved {
                    eventsDelegate?.fastoryIdentityResolved(resolved)
                }
                finishRenewal()
            }
        case .refused(let revocation):
            revokeDelegatedSession(revocation, config: config) { finishRenewal() }
        case .transient:
            // A failure that refused nothing keeps the identity and re-arms a bounded retry rather than
            // signing a fan out over a lost connection — the armed timer that fired this renewal is
            // spent, so without this the session would stay identified but never renew again.
            armDelegatedRenewalRetry()
            finishRenewal()
        }
    }

    /// Drops a delegated session the SDK could not keep (SPEC § 5.3): erase, revoke the standing
    /// answer, purge the persisted identity and the refresh token, land on anonymous, and tell the
    /// host why. The one path that emits `identityRevoked` — a host-driven `logout` never comes
    /// through here. The refused token is erased and never revoked again: the server already ended
    /// its family.
    private static func revokeDelegatedSession(
        _ revocation: FastoryIdentityRevocation,
        config: FastoryConfig,
        completion: (() -> Void)? = nil
    ) {
        let transition = FastoryIdentityRules.afterResolutionFailure(from: identity)
        _ = swapRefreshToken(nil)
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

    /// A `fanId` fan whose refresh token is gone — a reinstall, a restore — cannot be renewed: the
    /// fan is signed out the way `logout()` does it, with no event, since nothing was refused and the
    /// host signed no one out (SPEC § 2.6.3).
    private static func signOutWithoutToken(config: FastoryConfig) {
        apply(FastoryIdentityRules.logout(from: identity), config: config) {
            store(identity: nil)
            FastorySessionPush.broadcast()
            finishRenewal()
        }
    }

    // MARK: - One renewal at a time, under one generation

    /// The generation the renewal in flight was started under, and the callers waiting for it.
    /// Main-thread-only, like the armed renewal.
    private static var renewalInFlight: Int?
    private static var renewalWaiters: [() -> Void] = []

    private static func beginRenewal(generation: Int, completion: (() -> Void)?) {
        renewalInFlight = generation
        if let completion {
            renewalWaiters.append(completion)
        }
    }

    private static func finishRenewal() {
        renewalInFlight = nil
        endLaunchWait()
        releaseRenewalWaiters()
    }

    /// The generation moved on: the renewal in flight answers into nothing, so nothing waits for it.
    private static func abandonRenewals() {
        renewalInFlight = nil
        releaseRenewalWaiters()
    }

    private static func releaseRenewalWaiters() {
        let waiters = renewalWaiters
        renewalWaiters = []
        waiters.forEach { $0() }
    }

    /// Every `logout()`, `identify` and replacing `configure` starts a new generation (SPEC § 2.6.3).
    private static func startNewGeneration() {
        advanceSessionGeneration()
        abandonRenewals()
        endLaunchWait()
    }

    // MARK: - The launch wait (SPEC § 13.8.2)

    /// How long a token request and the hub's opening wait for a `fanId` fan's launch renewal.
    private static let launchWaitTimeout: TimeInterval = 3

    /// Main-thread-only: the armed bound and the hub openings waiting for the renewal.
    private static var launchBound: DispatchWorkItem?
    private static var launchBoundSerial = 0
    private static var launchHubWaiters: [() -> Void] = []
    private static var protectedDataObservers: [NSObjectProtocol] = []
    private static var sweptAccount: String?

    /// From now on a page's request for the fan's token, and the hub's opening, wait for the launch
    /// renewal. Callable from any thread.
    private static func beginLaunchWait() {
        store(launchWaitPending: true)
        FastoryBridgeResponder.beginDeferringUserToken()
    }

    /// Bounds the launch wait to `launchWaitTimeout`, beginning it if it is not already pending.
    private static func boundLaunchWait() {
        if !isLaunchWaitPending {
            beginLaunchWait()
        }
        guard launchBound == nil else { return }
        launchBoundSerial += 1
        let serial = launchBoundSerial
        let work = DispatchWorkItem {
            guard serial == launchBoundSerial else { return }
            endLaunchWait()
        }
        launchBound = work
        launchBoundSchedule(launchWaitTimeout, work)
    }

    /// Answers the waiting token requests with the answer in force now, and opens the waiting hubs on
    /// the session in force now — signed in when the renewal landed, anonymous otherwise.
    private static func endLaunchWait() {
        store(launchWaitPending: false)
        launchBound?.cancel()
        launchBound = nil
        launchBoundSerial += 1
        FastoryBridgeResponder.endDeferringUserToken()
        let waiters = launchHubWaiters
        launchHubWaiters = []
        waiters.forEach { $0() }
    }

    /// Forgets the delegated session state that is lock-guarded and thread-safe to clear from any
    /// thread — the token, its origin, the persisted identity, and the refresh token stored for
    /// `config`. The armed renewal is main-thread state, disarmed separately by `cancelRenewal`.
    ///
    /// The refresh token is erased on the store's own queue, and its family then revoked, best effort
    /// and without waiting (SPEC § 2.6.3): the SDK is letting it go. A token held unread is read and
    /// erased in one step on that queue, so what the launch read would have found is revoked too. A
    /// token the server already ended is forgotten before this runs, so it is never revoked twice.
    private static func clearDelegatedSession(config: FastoryConfig?) {
        store(delegatedSessionToken: nil)
        store(delegatedOrigin: nil)
        FastoryIdentityPersistence.purge()
        let held = swapRefreshToken(nil)
        if let held, held.token == nil {
            letGoOfUnreadRefreshToken(held)
        }
        let configured = config.flatMap { $0.publishableKey == nil ? nil : FastoryIdentityPersistence.stamp(for: $0) }
        for account in Set([held?.account, configured].compactMap { $0 }) {
            refreshTokenStore.erase(account: account)
        }
        if let held, let token = held.token {
            FastoryDelegatedSessionClient.shared.revoke(refreshToken: token, environment: held.environment)
        }
    }

    /// Disarms the renewal timer. Main-thread-only, like the work item it cancels.
    private static func cancelRenewal() {
        renewalWorkItem?.cancel()
        renewalWorkItem = nil
    }

    /// Signs the fan out of Fastory only — the host application's own session is never touched
    /// (§ 12). Idempotent, and waits on no network call: a `fanId` fan's refresh token is erased at
    /// once and its family revoked in the background, best effort. A renewal answer that lands after
    /// this call is ignored rather than signing the fan back in.
    public static func logout(completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            onMain { logout(completion: completion) }
            return
        }
        advanceSessionGeneration()
        abandonRenewals()
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
        endLaunchWait()
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
            clearDelegatedSession(config: config)
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
        pageGeneration += 1
        // All of them were built before this transition, so they hold the previous fan's rendered
        // page.
        discardWarmPages()
        eraseWebsiteData(FastoryIdentityStorage.origins(for: config)) {
            // Again once the erasure is done: a page that started loading while it ran may have
            // read the previous fan's cookies.
            pageGeneration += 1
            settle()
        }
    }

    /// The surface on screen, hub or panel, follows the identified fan (SPEC § 2.6.1, § 7): it
    /// reloads when the transition changed *which* fan is identified, and only then — the hub
    /// through the session handoff `resolveHub` mints, the panel on the address it was opened at,
    /// whose page asks the bridge for the session again. Anonymous and not identified both carry no
    /// `fanId`, so moving between them reloads nothing, and neither does the same fan identified
    /// again or renewed. A game learns the change from the session-change signal.
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
    ) -> (webView: WKWebView, url: URL?, hasCommitted: Bool, session: PageSession)? {
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
        // Loaded before an erasure: a page stashed after the discard that erasure ran — closed while
        // it was still erasing — would bring the previous fan's screen back.
        guard page.session.generation == pageGeneration,
              surface != .membership || readsCurrentSession(page.session) else {
            discardWarmPage(for: surface)
            return nil
        }
        // The view controller becomes the page's navigation delegate, so the warm-up's own observer
        // is done watching: it goes with the entry.
        warmPages[surface] = nil
        return (page.webView, page.url, page.hasCommitted, page.session)
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
    ///
    /// `session` is what the page read when it loaded, carried for the reason `config` is: the
    /// session in force now may have landed after the page asked. It defaults to a page loaded now.
    static func stashWarmPage(
        _ webView: WKWebView,
        for surface: FastorySurface,
        url: URL?,
        config: FastoryConfig,
        hasCommitted: Bool,
        session: PageSession = Fastory.pageSession
    ) {
        warmPages[surface] = WarmPage(
            webView: webView,
            url: url,
            config: config,
            hasCommitted: hasCommitted,
            observer: nil,
            session: session
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
    ///
    /// While a `fanId` fan's launch renewal is in flight there is no session yet, so the opening waits
    /// for it, at most `launchWaitTimeout`, and the hub opens signed in (SPEC § 13.8.2).
    private static func hubURLAdoptingSession(
        _ hubURL: URL,
        config: FastoryConfig,
        completion: @escaping (URL) -> Void
    ) {
        if isLaunchWaitPending {
            launchHubWaiters.append { hubURLAdoptingSession(hubURL, config: config, completion: completion) }
            return
        }
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
            observer: observer,
            session: pageSession
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
        openingRequests = 0
        storedRefreshToken = nil
        storedSessionGeneration = 0
        storedLaunchWaitPending = false
        storedLaunchWait = 0
        storedLaunchWaitOutcomes = [:]
        stateLock.unlock()
        pendingOpening = nil
        queuedTurnRequest = nil
        presentedSurfaceRequest = 0
        schedulePendingOpenTurn = { work in
            DispatchQueue.main.asyncAfter(
                deadline: .now() + FastoryHubViewController.closeTurnInterval,
                execute: work
            )
        }
        FastoryDelegatedSessionClient.shared.reset()
        FastoryFanLoginController.shared.reset()
        renewalInFlight = nil
        renewalWaiters.removeAll()
        launchBound?.cancel()
        launchBound = nil
        launchHubWaiters.removeAll()
        sweptAccount = nil
        stopWaitingForProtectedData()
        refreshTokenStore = FastoryRefreshTokenStore()
        FastoryIdentityPersistence.forgetApplicationId()
        protectedDataAvailable = { UIApplication.shared.isProtectedDataAvailable }
        launchBoundSchedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
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
        pageGeneration = 0
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
