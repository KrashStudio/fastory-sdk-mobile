# Fastory Mobile SDK — Specification

Status: **Normative** — this document is the single source of truth for the Fastory Mobile SDK public API. Sections tagged *since X.Y.Z* were added after 0.1.
Audience: SDK implementers (iOS, Android, Flutter) and integrators (your-fanzone app team).
The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as described in RFC 2119.

**Everything this document makes normative, it states itself.** No rule here delegates its authority
to a file outside the package you received — the enumerations in § 2.5 and § 9.1 in particular are
closed where they are written.

---

## 1. Overview & Scope (v0.1)

The Fastory Mobile SDK embeds the Fastory Fanzone games experience inside a host mobile application. v0.1 was deliberately ultra-light: a native WebView container with a strict URL interception policy, and no identity, no analytics and no behavior-modifying JavaScript.

Two of those three restrictions are permanent and normative, not historical: the SDK sends no analytics of its own (§ 12), and it injects no behavior-modifying JavaScript (§ 12.1, which bounds its few exceptions — the read-only preload discovery query of § 11.1 first among them). **Identity is no longer among them:** since 0.4.0 the SDK binds the host application's user to a Fastory fan (§ 2.6).

### 1.1 User flow

1. The host app (Flutter, e.g. the your-fanzone app) calls `Fastory.openGames()`.
2. The SDK presents a **full-screen native view** containing **WebView A** (the "hub"), which loads a hidden tab of the client's Fanzone (e.g. `https://fanzone.me/your-fanzone?tab=games&chrome=0&consent=0`).
3. The user taps a game image in the hub. The web page performs `window.open(url, '_self')`; the SDK intercepts this navigation natively.
4. The SDK presents a **native bottom sheet** (the "toaster") containing **WebView B**, which loads the game (e.g. `https://fanzone.me/s/{slug}?embed=1&utm_source=sdk`).
5. Any navigation to an origin other than the configured Fanzone base URL opens in the **system browser**.

### 1.2 In scope (v0.1)

- Full-screen hub view (WebView A) and game bottom sheet (WebView B).
- URL interception policy (§ 4).
- Flutter platform channel bridge (§ 5).
- Android back button handling (§ 6).
- Per-origin session and web-storage model, and its erasure contract (§ 7).
- Native safe-area handling (§ 8).
- Native error/offline view with retry (§ 9).
- Game preloading and fresh-state close (§ 11).

### 1.3 Minimum OS versions

- iOS: **15.0**
- Android: **minSdk 24** (Android 7.0)

---

## 2. Public API Surface

The SDK exposes **eight operations** — `configure`, `openGames`, `close` (since 0.1), `identify`, `logout` and `setBridgeReply` (since 0.4.0), `openMembership` (since 0.5.0), and `setHostTokenProvider` (since 0.5.0) — and **one event stream** carrying the eleven events of § 5.3. Signatures below are normative; implementations MUST match them exactly.

**Two of the senses the word *surface* carries here can be read for one another, so this is which is which.** One is a web view the SDK presents — the hub, or a game: that is `FastorySurface` in the API (§ 2.2–2.4, § 5.3) and *web surface* in § 13. The other is a set of exported names — *the public surface* of this section, *the two native API surfaces*, *the Dart surface*. Which one a sentence means follows from what it is about: a surface that loads, fails or is presented is the first; a surface a host compiles against is the second. Where it means an area of exposure instead — *a leak surface*, *an assertion surface* — it is neither of the two; that is the ordinary English word.

### 2.1 Configuration model

| Field | Type | Required | Description |
|---|---|---|---|
| `environment` | enum `production` \| `staging` \| `development` | yes | Selects the Fanzone base URL (§ 3.1) |
| `publishableKey` | string | exactly one of `publishableKey` / `fanzoneSlug` | Workspace publishable key, `fpk_live_…` or `fpk_test_…` (§ 2.5) |
| `fanzoneSlug` | string | exactly one of `publishableKey` / `fanzoneSlug` | **Deprecated since 0.3.0.** Fanzone identifier, e.g. `"your-fanzone"` |
| `hubTabSlug` | string | yes | Hidden tab used as games hub, e.g. `"games"` |
| `locale` | string (BCP 47) | no | Preferred locale hint, e.g. `"en"`, `"fr-FR"` |
| `theme` | enum `light` \| `dark` | no | Appearance hint forwarded to the web surfaces (§ 3.2, § 3.3) |
| `developmentBaseUrl` | string (https URL) | only when `environment == development` | Custom base URL for development |
| `prewarm` | set of `FastorySurface` | no (default: `hub` alone) | *Since 0.5.0.* The surfaces prepared before their first opening (§ 11). An empty set prepares nothing ahead of time |
| `handlesLoginRequests` | bool | no (default: `false`) | *Since 0.5.0.* The host listens for `fastory:login-requested` (§ 13.3) and signs the fan in itself. Declared, it is forwarded to the web surfaces as `hostLogin=1` (§ 3.2, § 3.3, § 3.5), and their sign-in entries ask the host; left `false`, they show none (§ 2.6) |

`configure` MUST be called before `openGames()`. Calling `openGames()` unconfigured MUST fail with error code `not_configured` (§ 5.4). `configure` MAY be called again; the new configuration applies to the next `openGames()` call. It may be called from any thread (§ 2.7).

**`openGames()` is idempotent** (since 0.4.0): called while a hub is already presented, it MUST do nothing at all — not an error, and never a second hub. A double tap on a tab-bar entry is the ordinary way to reach this, so the guarantee cannot rest on the host not asking twice. Three consequences follow from a second hub and each is normative on its own: the host receives exactly **one `hubOpened` and one `hubClosed` per hub the SDK presents** (§ 5.3), `close()` MUST return the fan to the host application rather than to another hub, and no page may leave the warm slot (§ 11) without being released — a stacked hub stashes over the other one's page on the way out, and a platform without automatic reference counting leaks it.

**Where presentation is asynchronous, the reservation MUST be taken at the request, not at the arrival.** An implementation whose hub is an `Activity` — or any container the platform builds on a later turn — cannot answer "is a hub up?" from the container itself during the launch window, and that window is precisely where the second tap lands. It MUST therefore mark the hub as taken when `openGames()` is called, release that mark when the container is **dismissed** — and no later than its destruction, including when it never reached the screen — and re-take it when the platform recreates the same container, or `openGames()` becomes a permanent no-op instead of an idempotent one. A call arriving while the container is still animating out MAY be absorbed; one arriving after it MUST open a hub. A platform may destroy a dismissed container seconds later, and a mark held until then makes an `openGames()` in that gap a silent no-op. A `close()` arriving inside that window MUST still be honoured: a hub the host has asked to be rid of MUST NOT appear a frame later.

**And the reservation MUST survive a launch that is refused without saying so.** Releasing it when the container is destroyed is not sufficient, because a start the platform refuses outright never builds one to destroy: since Android 10 a start from the background is refused with a log line and **no exception**, and `openGames(context)` takes a plain `Context` on purpose, so a native host may legitimately call it from there. An implementation MUST therefore also give the reservation back on a **timeout** — the current one is **10 s**, keyed to the launch it was armed for so it can never free a hub that did arrive — and that behaviour is observable: nothing opens, and roughly ten seconds later `openGames()` works normally again. Without it, one refused start makes the SDK mute for the life of the process, which is strictly worse than the stacking the reservation prevents and, unlike it, unrecoverable.

iOS presents synchronously and has always behaved this way; Android did not until 0.4.0.

**The count is per presentation, and a platform rebuilding its own container is not one** (since 0.4.5). Android destroys and recreates an `Activity` for a configuration change outside its declared `configChanges` — a locale switch, a density change, *Don't keep activities* — and until 0.4.5 the implementation surfaced that as a `hubClosed` immediately followed by a `hubOpened`, for one hub the fan never saw leave: honest about the container, wrong about the presentation. A rebuilt hub MUST continue the presentation and emit neither event; a game sheet rebuilt with it MUST continue the game and emit neither `gameClosed` nor `gameOpened` — its page reloads with the screen, and a reload that fails reports `surfaceLoadFailed` (§ 9.1) — with one exception no implementation can avoid: a game that opened after the platform saved the hub's state has no record to resume from, so its closing is reported at the rebuild and the restored sheet announces a new opening. An `openGames()` arriving before the platform has rebuilt the hub asks for that hub again; a `close()` arriving then ends the presentation at once — `gameClosed` when a game was open, then `hubClosed` — and the container the platform rebuilds afterwards finishes without emitting anything. The presentation ends with the one `hubClosed` — preceded by one `gameClosed` when a game was open — that § 5.3 requires: on a dismissal, or when the platform has dropped the saved container and the next `openGames()` starts a new presentation, which ends the lost one first. An implementation tells a rebuild from a dismissal at the point the container ends, not at the point an event is emitted: a container ending without finishing its presentation is being rebuilt.

The membership panel (since 0.5.0) is the same container presenting another surface, and every rule of this paragraph holds for it with its own pair of events: a rebuilt panel MUST continue its presentation and emit neither `membershipClosed` nor `membershipOpened`, and a game sheet rebuilt with it is carried as one rebuilt with the hub. A `close()` arriving before the platform has rebuilt the panel ends the presentation at once — `gameClosed` when a game was open, then `membershipClosed` — and the container rebuilt afterwards finishes without emitting anything. The two openings share one reservation (§ 5.3), so either of them arriving before the rebuild asks for the container being rebuilt again, as `openGames()` does for a hub; when the platform has dropped the saved container, that opening starts a new presentation, which ends the lost one first. The panel's presentation ends with the one `membershipClosed` — preceded by one `gameClosed` when a game was open — that § 5.3 requires.

**A container rebuilt while it shows the error view MUST load its surface again** (since 0.5.0). Its page does not cross the rebuild — its last attempt failed, and a page that failed never returns to the warm slot (§ 9.1) — so the rebuilt container asks for its surface as the first opening did: it loads the surface's address, announces the opening on that load's commit, and when the load fails once more shows the error view again and reports `surfaceLoadFailed` (§ 9.1). Only an opening the presentation has not emitted yet is owed: a surface that opened before it failed — an in-place navigation that did not load — continues its presentation and emits no second opening, as above. **This load starts without the fan's Retry** (§ 9) — the only one a full-screen surface starts over its error view — and the exception is deliberate, on the precedent of the game sheet above, whose page reloads with a rebuilt screen, its error view included, and whose failed reload is reported. The alternative is a rebuilt container standing on a page that never rendered, announced open over a blank screen. The rebuild starts no publishable-key exchange of its own: where that exchange is what failed, the rebuilt container is answered from the last outcome the SDK holds — a failure, unless an exchange started since has resolved the workspace. After a failure, and short of a `configure`, iOS starts a new exchange only on the fan's Retry (§ 9); Android also starts one on an `openGames()` or `openMembership()` that finds the failure cached, and answers that opening from the failure until the new exchange lands — so a container rebuilt once that exchange has resolved the workspace opens where its first opening showed the error view.

**What is prepared ahead of the first opening is the host's choice** (since 0.5.0). A prepared surface opens already rendered, and it is paid for from the moment it is prepared, on every launch: a resident WebView — a renderer process on Android — and the requests its page makes, whether or not the fan ever opens it. `prewarm` names the surfaces a host wants paid for. Implementations MUST prepare exactly the surfaces it names that the configuration can address before any opening, and MUST NOT prepare one it leaves out:

- **`hub`** is addressable on both paths — at once on the slug path, once the exchange resolves on the key path (§ 2.5). It is the default, alone — the only surface there was to prepare before 0.5.0.
- **`membership`** is addressable on the publishable-key path only. The deprecated slug path resolves no workspace, so a `membership` it names MUST be ignored — the panel cannot even be opened there (§ 5.2) — and the configuration is not rejected for it.
- **`game`** names no page of its own: games are preloaded from the hub's page (§ 11), so they follow `hub`, and `game` in the set prepares nothing by itself.
- **An empty set is legal** and prepares nothing ahead of time. The publishable-key exchange still starts at `configure` (§ 2.5), so a first opening waits for no round trip it could have started earlier.

The set governs **preparation ahead of the first opening only**. A surface the fan has opened is kept warm once it closes, whether or not the set names it, provided its page loaded (§ 11) — a page that failed is not kept (§ 9.1) — so a surface left out loads cold on its first opening and not on every one; `openMembership` is fully available without `membership` in the set. The set is part of the configuration like every other field, so the equality rule below applies to it unchanged: a `configure` that changes it replaces the configuration, and one that repeats it keeps what is warm.

**A `configure` whose configuration differs from the one in force MUST first discard everything the previous one produced** (since 0.4.0): the warm hub WebView and the preloaded games (§ 11), and the standing bridge answer (§ 13.8.6). Otherwise the next `openGames()` presents the *previous* configuration's fanzone under the new configuration — a multi-club app opens the wrong club, and an environment switch opens the wrong environment. Two consequences implementations get wrong in opposite directions, so both are normative:

- **The teardown MUST NOT be conditional on there being something to prepare in exchange.** The warm-up does not run unconditionally: it waits for the host's first screen (§ 2.7) and, configured by key, for the exchange to resolve (§ 2.5) — so a teardown placed behind those waits keeps the previous configuration's page in reserve until they are over, and an `openGames()` inside that window presents it. The teardown runs at `configure`, whatever the warm-up later does. This is the defect iOS carried until 0.4.0.
- **A `configure` with an *equal* configuration MUST NOT discard the warm hub or the preloaded games.** Re-configuring identically has changed nothing to render, so it is not an invalidation; making it one turns a harmless call into a cold hub open. Equality is the whole configuration, field by field. This binds the *warm-up path* as much as the teardown: an implementation that re-runs its warm-up unconditionally discards by rebuilding, which is the same defect wearing the opposite sign — and it is the shape iOS carried until 0.4.0, where warming up flushed the preloader before it checked whether anything needed warming.
- **The publishable-key exchange (§ 2.5) is deliberately outside that rule, and the two platforms diverge there.** A cached **failure** is re-armed by any `configure`, equal or not, on **both** platforms: each resolver skips a fresh exchange only while one is in flight or a workspace is already resolved — so a failed outcome falls through and a second request leaves the device. It is also re-armed by the fan's Retry, which is the one caller that discards it without a `configure` at all (§ 9). Two things do still differ, and neither is that. **A cached success**: iOS discards it on every `configure` and exchanges again, Android keeps it unless the configuration changed. **And what a surface opening inside the new exchange's window is answered with**: an implementation that clears the outcome at `configure` — iOS, and Android on a *changed* configuration — makes that surface wait for the new answer, while one that leaves it in place — Android on an *equal* configuration — answers it from the previous failure until the new one lands. Both re-ran the exchange; only one of them lets the previous verdict be read once more. Reconciling those two is still open, and neither platform is to be moved to match the other until it is decided: widening Android adds a network round trip to every equal re-configure, and narrowing iOS is a behavior change. Neither costs the fan anything now that § 9's Retry re-runs the exchange itself — a `configure` is no longer the only way back from a refused key. **Do not read "the outcome is cached per configuration" as "an equal `configure` sends nothing"** — true of a resolved workspace, false of a failure.

**And the teardown alone MUST NOT be the only defence.** The hub is put *back* into the warm slot when it is dismissed (§ 11), which can happen after the re-configure — so a page rendered under the previous configuration returns to the slot the teardown already emptied, and the next `openGames()` presents it. Implementations MUST therefore also make a warm hub reusable **only for the configuration its page was loaded under**: stamp it, and drop it on a mismatch whenever it is taken. The same rule applies to a cached key exchange — a workspace resolved for one configuration MUST NOT answer for another, or its slug builds a hub URL in the wrong environment. Both together are what make § 2.7's threading freedom safe: the teardown lands on a later main-thread turn, so correctness cannot rest on it having run yet.

The two native platforms MUST agree here. They did not before 0.4.0, and the divergence was recorded nowhere as a decision.

Implementations MUST reject, at `configure` time and before any network call: neither identifier supplied, both supplied, a blank `fanzoneSlug`, and a `publishableKey` that is malformed or minted for another environment (§ 2.5). A rejected configuration MUST NOT be stored, and MUST NOT be accepted now to fail later at the network layer.

**A rejection MUST leave the configuration already in force untouched.** Not storing the rejected one is only half of it: the previous configuration keeps applying, so a `configure` that is refused is a call that changed nothing, not a call that de-configured the SDK. A host whose *first* `configure` is refused is unconfigured and `openGames()` reports `not_configured` (§ 5.4); a host that re-configures and is refused still holds the configuration it had, and `openGames()` opens **that** one. Documentation MUST NOT state the first case as though it were the general one — it is the case a host meets on day one and never again.

**A typed, catchable error MUST be reachable for every rejection, and on which entry point it sits is a platform decision — which is not the same as it being reachable from `configure` itself.** The two shipped channels put it in different places: Swift's `configure(_:)` is non-throwing by design (§ 2.2 — the signature is locked and both initializers are non-throwing too), so it validates and, on a **debug** build, `assertionFailure`s and terminates the process; on a release build it returns, having changed nothing. Dart's `configure` throws `ArgumentError` on the caller's thread, before the platform channel, so the native side is not reached at all. Both satisfy the requirement above, and both are correct: the catchable error a Swift host reaches is `FastoryConfig.validate()`, which is public, throws `FastoryConfigError` (a `LocalizedError`, so its `localizedDescription` names the rule), applies this same rule set and calls nothing. What is normative:

- Every rejection listed above MUST be reachable as a **typed, catchable error** on some public entry point of the platform's own API — `validate()` where `configure` is non-throwing, `configure` itself where the language makes that idiomatic.
- A platform MAY additionally trap on a debug build, as an assertion about programmer error. It MUST NOT trap on a release build.
- **Whatever a platform does, its shipped documentation MUST say so, distinguishing debug from release**, and MUST NOT attribute to one channel what another does. An integrator moving between the two channels — the migration path § 2.5's deprecation window describes — meets exactly this divergence on the single most likely configuration mistake, a key and an environment that disagree.

### 2.2 Swift (iOS)

```swift
public enum FastoryEnvironment {
    case production
    case staging
    case development(baseURL: URL)
}

public enum FastoryTheme: String { case light, dark }

public struct FastoryConfig {
    public let environment: FastoryEnvironment
    public let publishableKey: String?
    public let fanzoneSlug: String?
    public let hubTabSlug: String
    public let locale: String?
    public let theme: FastoryTheme?
    public let prewarm: Set<FastorySurface>   // since 0.5.0 (§ 2.1)
    public let handlesLoginRequests: Bool     // since 0.5.0 (§ 2.1)

    public init(publishableKey: String,
                environment: FastoryEnvironment = .production,
                hubTabSlug: String = "games",
                locale: String? = nil,
                theme: FastoryTheme? = nil,
                prewarm: Set<FastorySurface> = [.hub],
                handlesLoginRequests: Bool = false)

    @available(*, deprecated)
    public init(environment: FastoryEnvironment = .production,
                fanzoneSlug: String,
                hubTabSlug: String = "games",
                locale: String? = nil,
                theme: FastoryTheme? = nil,
                prewarm: Set<FastorySurface> = [.hub],
                handlesLoginRequests: Bool = false)

    public func validate() throws
}

public protocol FastoryEventsDelegate: AnyObject {
    func fastoryHubOpened(fanzoneSlug: String)
    func fastoryHubClosed()

    // since 0.5.0 — defaulted to a no-op in a protocol extension (§ 3.5)
    func fastoryMembershipOpened()
    func fastoryMembershipClosed()

    func fastoryGameOpened(slug: String)
    func fastoryGameClosed()
    func fastoryExternalLink(url: URL)

    // since 0.4.0 — defaulted to a no-op in a protocol extension (§ 13)
    func fastoryBridgeMessage(type: String, payload: [String: Any])

    // since 0.4.0 — defaulted to a no-op in a protocol extension (§ 2.6)
    func fastoryIdentityResolved(_ identity: FastoryResolvedIdentity)

    // since 0.4.0 — defaulted to a no-op in a protocol extension (§ 9.1)
    func fastorySurfaceLoadFailed(_ failure: FastoryLoadFailure)
}

// since 0.4.0 — a surface that did not load (§ 9.1); `membership` added in 0.5.0 (§ 3.5)
public enum FastorySurface: String { case hub, game, membership }

public enum FastoryLoadFailureReason: String { case rejected, network, unknown }

public struct FastoryLoadFailure: Equatable {
    public let surface: FastorySurface
    public let reason: FastoryLoadFailureReason
    /// The API's machine-readable code (§ 2.5); non-nil only for a refused key exchange.
    public let code: String?
    /// The HTTP status the surface's main document answered; non-nil only when one did.
    public let statusCode: Int?
}

// since 0.4.0 — the requested mode (§ 2.6)
public enum FastoryIdentity {
    case anonymous
    case fanId
    case hostToken(jwt: String)
}

public enum FastoryIdentityMode: String {
    case anonymous, fanId, hostToken
}

public struct FastoryResolvedIdentity: Equatable {
    public let mode: FastoryIdentityMode
    /// Non-nil only for an identified fan; always `nil` for `.anonymous` (§ 2.6.2).
    public let fanId: String?
}

public enum FastoryIdentifyError: Error, Equatable {
    case notConfigured
    case modeUnavailable(FastoryIdentityMode)
    case invalidIdentityMode(String)
    case invalidHostToken
    case loginCancelled
    case rejected(code: String)
    case network
}

// since 0.4.0 — what a web surface may ask the native side to answer (§ 13.8.3). An enum, not a
// free string: the request registry is a security boundary, so a host cannot name a type outside it.
public enum FastoryBridgeRequestType: String, CaseIterable {
    case userToken = "fastory:user-token"
}

public enum Fastory {
    public private(set) static var config: FastoryConfig?
    public static weak var eventsDelegate: FastoryEventsDelegate?

    public static func configure(_ config: FastoryConfig)
    public static func openGames(from presenter: UIViewController)
    // since 0.5.0 (§ 3.5). `sequenceId` opens the panel on one of the workspace's sequences;
    // absent or blank, the panel opens on its default screen.
    public static func openMembership(from presenter: UIViewController, sequenceId: String? = nil)
    public static func close()

    // since 0.4.0 (§ 2.6). `nil` until the first successful identify, and again after logout().
    public private(set) static var identity: FastoryResolvedIdentity?

    public static func identify(
        _ identity: FastoryIdentity,
        completion: ((Result<FastoryResolvedIdentity, FastoryIdentifyError>) -> Void)? = nil
    )
    public static func logout(completion: (() -> Void)? = nil)

    // since 0.4.0 (§ 13.8). What the next web request for `type` is answered with; `nil` clears it.
    public static func setBridgeReply(for type: FastoryBridgeRequestType, payload: [String: Any]?)
}
```

- `openGames(from:)` MUST present the hub full screen (`.fullScreen` modal presentation) over `presenter`. Calling it unconfigured is a no-op (an assertion fires in debug builds); it does not throw. Calling it while a hub is already presented is a no-op too, and silent — § 2.1.
- `openMembership(from:sequenceId:)` (since 0.5.0) MUST present the membership panel the same way, over `presenter`. Calling it unconfigured, or on a configuration that carries a fanzone slug rather than a publishable key, is a no-op with an assertion in debug builds — the two cases assert distinct messages, since a host told only "not configured" re-configures with the same slug. Calling it while either surface is presented is a silent no-op, § 2.1. `sequenceId` is optional and defaulted: naming none is the ordinary form and opens the panel's default screen. What it names, and what a blank or unknown identifier does, is § 3.5.
- `close()` MUST dismiss the game sheet (if any) and the presented surface, in that order, emitting `gameClosed` then that surface's closing event.
- `eventsDelegate` is `weak`: the host app MUST retain its delegate for the lifetime of the session, or events stop being delivered.
- `identify(_:completion:)` and `logout(completion:)` are non-throwing and non-blocking (§ 2.6.1); every outcome arrives through the completion, on the main thread. The `completion` is optional so a host that only watches `fastoryIdentityResolved` can ignore it — but the errors of § 2.6 are reported **only** there, never as an event.
- Every callback added after v0.1 — `fastoryBridgeMessage`, `fastoryIdentityResolved` and `fastorySurfaceLoadFailed` in 0.4.0, `fastoryMembershipOpened` and `fastoryMembershipClosed` in 0.5.0 — MUST have a default no-op implementation in a protocol extension, so a host written against the v0.1 delegate keeps compiling. That is what makes this surface additive while Dart's is source-breaking (§ 10): the list must stay complete, or the next release adds one more and breaks a conformer that never asked for it.

### 2.3 Kotlin (Android)

```kotlin
// DEVELOPMENT carries no URL of its own: `developmentBaseUrl` on FastoryConfig does, and the
// configuration is refused without it (§ 2.1).
enum class FastoryEnvironment { PRODUCTION, STAGING, DEVELOPMENT }

enum class FastoryTheme { LIGHT, DARK }

data class FastoryConfig(
    @Deprecated("use publishableKey") val fanzoneSlug: String? = null,
    val environment: FastoryEnvironment = FastoryEnvironment.PRODUCTION,
    val hubTabSlug: String = "games",
    val locale: String? = null,
    val developmentBaseUrl: String? = null,
    val publishableKey: String? = null,
    val theme: FastoryTheme? = null,
    val prewarm: Set<FastorySurface> = setOf(FastorySurface.HUB),   // since 0.5.0 (§ 2.1)
    // since 0.5.0 (§ 2.1). Last, and defaulted, so a positional call written before it compiles.
    val handlesLoginRequests: Boolean = false,
)

interface FastoryEventsListener {
    fun onHubOpened(fanzoneSlug: String) {}
    fun onHubClosed() {}

    // since 0.5.0 (§ 3.5)
    fun onMembershipOpened() {}
    fun onMembershipClosed() {}

    fun onGameOpened(slug: String) {}
    fun onGameClosed() {}
    fun onExternalLink(url: String) {}

    // since 0.4.0 (§ 13)
    fun onBridgeMessage(type: String, payload: Map<String, Any?>) {}
    // since 0.4.0 (§ 2.6)
    fun onIdentityResolved(identity: FastoryResolvedIdentity) {}
    // since 0.4.0 (§ 9.1)
    fun onSurfaceLoadFailed(failure: FastoryLoadFailure) {}
}

// since 0.4.0 — a surface that did not load (§ 9.1); `MEMBERSHIP` added in 0.5.0 (§ 3.5)
enum class FastorySurface { HUB, GAME, MEMBERSHIP }

enum class FastoryLoadFailureReason { REJECTED, NETWORK, UNKNOWN }

data class FastoryLoadFailure(
    val surface: FastorySurface,
    val reason: FastoryLoadFailureReason,
    /** The API's machine-readable code (§ 2.5); non-null only for a refused key exchange. */
    val code: String? = null,
    /** The HTTP status the surface's main document answered; non-null only when one did. */
    val statusCode: Int? = null,
)

// since 0.4.0 — the requested mode (§ 2.6). A sealed class, so constructing more than one
// mode is impossible by construction rather than rejected at runtime.
sealed class FastoryIdentity {
    object Anonymous : FastoryIdentity()
    object FanId : FastoryIdentity()
    data class HostToken(val jwt: String) : FastoryIdentity()
}

enum class FastoryIdentityMode { ANONYMOUS, FAN_ID, HOST_TOKEN }

/** [fanId] is non-null only for an identified fan; always null for [FastoryIdentityMode.ANONYMOUS]. */
data class FastoryResolvedIdentity(val mode: FastoryIdentityMode, val fanId: String? = null)

/** Every identify failure of § 5.4, carried as its machine-readable [code]. */
class FastoryIdentifyException(val code: String, message: String? = null) : Exception(message ?: code)

// since 0.4.0 — what a web surface may ask the native side to answer (§ 13.8.3). An enum, not a
// free string: the request registry is a security boundary, so a host cannot name a type outside it.
enum class FastoryBridgeRequestType { USER_TOKEN }

object Fastory {
    // The Context names the application for the key exchange (§ 2.5) and lets the SDK
    // watch the process lifecycle for the hub warm-up (§ 2.7). Any Context; only its application
    // context is kept.
    fun configure(context: Context, config: FastoryConfig, listener: FastoryEventsListener? = null)
    @Deprecated("use configure(context, …)")
    fun configure(config: FastoryConfig, listener: FastoryEventsListener? = null)
    fun openGames(context: Context)
    // since 0.5.0 (§ 3.5). `sequenceId` opens the panel on one of the workspace's sequences;
    // absent or blank, the panel opens on its default screen.
    fun openMembership(context: Context, sequenceId: String? = null)
    fun close()

    // since 0.4.0 (§ 2.6). Null until the first successful identify, and again after logout().
    val identity: FastoryResolvedIdentity?

    fun identify(
        identity: FastoryIdentity,
        callback: ((Result<FastoryResolvedIdentity>) -> Unit)? = null,
    )
    fun logout(callback: (() -> Unit)? = null)

    // since 0.4.0 (§ 13.8). What the next web request for [type] is answered with; null clears it.
    fun setBridgeReply(type: FastoryBridgeRequestType, payload: Map<String, Any?>?)
}
```

- The event listener is supplied to `configure` (all methods have default no-op bodies, so hosts override only what they need). Calling `openGames` unconfigured throws `IllegalStateException`.
- `configure(context, …)` is the form a native host SHOULD call: the `Context` names the application for the key exchange, so the exchange starts at `configure` rather than at the first `openGames`, and lets the SDK watch the process lifecycle for the warm-up (§ 2.7) — the surfaces `prewarm` names are prepared ahead of their first opening, at once on the slug path and when the exchange resolves on the key path (§ 2.1, § 2.5). Any `Context` is accepted and only its application context is kept. **The context-less form remains accepted for the whole 0.x line and MUST keep behaving exactly as before**: without an application identifier the exchange waits for the first `openGames(context)`, and nothing is prepared ahead of it on either path, whatever `prewarm` names. It is marked `@Deprecated` and is removed in 1.0.
- `identify` follows that same rule: called before `configure`, it throws the **same** `IllegalStateException` as `openGames` rather than reporting a new error shape. Every other failure arrives in the `callback` as a failed `Result` carrying a `FastoryIdentifyException`, on the main thread — never as a thrown exception.
- `openGames(context)` MUST launch a dedicated full-screen `Activity` (or full-screen `DialogFragment`) hosting WebView A. That `Activity` MUST be declared `singleTop`: the SDK's own idempotence guard (§ 2.1) is what refuses the second call, and the launch mode is what stops the *platform* from stacking an instance in the moment the guard cannot see — a manifest left on the default `standard` was the other half of the pre-0.4.0 defect.
- The game toaster MUST be a `BottomSheetDialogFragment` (Material bottom sheet) hosting WebView B.

### 2.4 Dart (Flutter plugin)

```dart
enum FastoryEnvironment { production, staging, development }

enum FastoryTheme { light, dark }

class FastoryConfig {
  // Both identifiers are optional so an app written against 0.1 keeps compiling;
  // validate() enforces "exactly one".
  const FastoryConfig({
    this.publishableKey,
    this.fanzoneSlug,
    this.environment = FastoryEnvironment.production,
    this.hubTabSlug = 'games',
    this.locale,
    this.theme,
    this.developmentBaseUrl,
    this.prewarm = const <FastorySurface>{FastorySurface.hub},
    this.handlesLoginRequests = false,
  });

  final String? publishableKey;
  @Deprecated('use publishableKey')
  final String? fanzoneSlug;
  final FastoryEnvironment environment;
  final String hubTabSlug;
  final String? locale;
  final FastoryTheme? theme;
  final String? developmentBaseUrl;
  // since 0.5.0 (§ 2.1)
  final Set<FastorySurface> prewarm;
  // since 0.5.0 (§ 2.1)
  final bool handlesLoginRequests;

  void validate();
}

sealed class FastoryEvent {
  const FastoryEvent();
}

class FastoryHubOpened extends FastoryEvent {
  const FastoryHubOpened(this.fanzoneSlug);
  final String fanzoneSlug;
}

class FastoryHubClosed extends FastoryEvent { const FastoryHubClosed(); }

// since 0.5.0 (§ 3.5)
class FastoryMembershipOpened extends FastoryEvent { const FastoryMembershipOpened(); }
class FastoryMembershipClosed extends FastoryEvent { const FastoryMembershipClosed(); }

class FastoryGameOpened extends FastoryEvent {
  const FastoryGameOpened(this.slug);
  final String slug;
}

class FastoryGameClosed extends FastoryEvent { const FastoryGameClosed(); }

class FastoryExternalLink extends FastoryEvent {
  const FastoryExternalLink(this.url);
  final String url;
}

// since 0.4.0 (§ 13); `fastory:login-requested` added in 0.5.0 (§ 13.3)
class FastoryBridgeMessage extends FastoryEvent {
  const FastoryBridgeMessage(this.type, this.payload);
  static const Set<String> knownTypes = <String>{'fastory:ready', 'fastory:login-requested'};
  final String type;
  final Map<String, Object?> payload;
}

// since 0.4.0 (§ 2.6)
class FastoryIdentityResolved extends FastoryEvent {
  const FastoryIdentityResolved(this.mode, this.fanId);
  final FastoryIdentityMode mode;
  /// Non-null only for an identified fan; always null for [FastoryIdentityMode.anonymous].
  final String? fanId;
}

// since 0.4.0 — a surface that did not load (§ 9.1); `membership` added in 0.5.0 (§ 3.5)
enum FastorySurface { hub, game, membership }

enum FastoryLoadFailureReason { rejected, network, unknown }

class FastorySurfaceLoadFailed extends FastoryEvent {
  const FastorySurfaceLoadFailed(this.surface, this.reason, {this.code, this.statusCode});
  final FastorySurface surface;
  final FastoryLoadFailureReason reason;
  /// The API's machine-readable code (§ 2.5); non-null only for a refused key exchange.
  final String? code;
  /// The HTTP status the surface's main document answered; non-null only when one did.
  final int? statusCode;
}

// since 0.4.0 — the requested mode. Sealed, so a mode cannot be combined with another.
sealed class FastoryIdentity {
  const FastoryIdentity();
}

class FastoryAnonymous extends FastoryIdentity { const FastoryAnonymous(); }

class FastoryFanId extends FastoryIdentity { const FastoryFanId(); }

class FastoryHostToken extends FastoryIdentity {
  const FastoryHostToken(this.jwt);
  final String jwt;
}

enum FastoryIdentityMode { anonymous, fanId, hostToken }

class FastoryResolvedIdentity {
  const FastoryResolvedIdentity(this.mode, this.fanId);
  final FastoryIdentityMode mode;
  final String? fanId;
}

// since 0.4.0 — what a web surface may ask the native side to answer (§ 13.8.3). An enum, not a
// free string: the request registry is a security boundary, so a host cannot name a type outside it.
// `wireValue` is the registry string; it is what crosses the channel, never the Dart enum name.
enum FastoryBridgeRequestType {
  userToken('fastory:user-token');

  const FastoryBridgeRequestType(this.wireValue);
  final String wireValue;
}

class Fastory {
  static Future<void> configure(FastoryConfig config);
  static Future<void> openGames();
  // since 0.5.0 (§ 3.5). `sequenceId` opens the panel on one of the workspace's sequences;
  // absent or blank, the panel opens on its default screen.
  static Future<void> openMembership({String? sequenceId});
  static Future<void> close();

  // since 0.4.0 (§ 2.6)
  static Future<FastoryResolvedIdentity> identify(FastoryIdentity identity);
  static Future<void> logout();

  // since 0.4.0 (§ 13.8). What the next web request for [type] is answered with; null clears it.
  static Future<void> setBridgeReply(
    FastoryBridgeRequestType type,
    Map<String, Object?>? payload,
  );

  static Stream<FastoryEvent> get events;
}
```

- All methods delegate to the platform channel (§ 5) and complete when the native side has acknowledged the call.
- `events` is a broadcast stream backed by the `EventChannel`; subscribing MUST NOT be required for the SDK to function.
- `identify` rejects with a `PlatformException` carrying one of the § 5.4 codes; it never completes with a partially resolved identity. `logout` always succeeds.
- Adding a subtype to the `sealed` `FastoryEvent` hierarchy is **source-breaking on Dart**: an exhaustive `switch` with no `default:` stops compiling until the host adds a case. 0.4.0 adds **three** — `FastoryBridgeMessage`, `FastoryIdentityResolved` and `FastorySurfaceLoadFailed` — and a host meets all of them at once, since none of the three shipped separately. Deliberate, under SemVer § 4 for a `0.y.z` line, and called out in `CHANGELOG.md`. The two native API surfaces are unaffected: every new callback is defaulted to a no-op.

### 2.5 Publishable key (since 0.3.0)

A publishable key identifies the workspace a host application belongs to. It is embedded in a shipped app and is **not a credential**: it grants no data access, it is bound to declared application identifiers, its use is rate-limited, and it is revocable.

- Keys are minted per environment: `fpk_live_` belongs to `production`, `fpk_test_` to `staging` and `development`. A prefix alone is not a key. Both rules MUST be enforced locally at `configure` time.
- Configured by key, the SDK does **not** know which fanzone to open. It MUST exchange the key at `POST {apiBase}/sdk/auth/bootstrap` — `{apiBase}` is the per-environment table in § 3.1, and it is **not** the Fanzone origin — sending the key and the host's application identifier (bundle identifier on iOS, package name on Android) as headers, and MUST take the fanzone slug from the `workspace.slug` of the response. Where the identifier cannot be read at all there is no well-formed request to send: the implementation MUST refuse in the API's place, with `sdk_application_id_required` (§ 9.1), rather than exchange without it.
- The exchange MUST start at `configure` and `openGames()` MUST wait on it rather than blocking the caller. While it is in flight the hub MUST show its existing loading state; on failure it MUST show the existing native error view (§ 9) — never a blank WebView.
- Failures MUST surface the API's machine-readable `code`. Hosts branch on the code, never on a message, so the list they branch against has to be complete rather than illustrative. **Four of the endpoint's codes are reachable through a request this SDK forms:**
  - `sdk_key_unknown` (401) — this API knows no such key. It is **not** only a typo: a key **deleted** in the back-office, and a key whose workspace no longer exists, both read back as unknown, so an application already in the field can meet it after a back-office action it never saw.
  - `sdk_key_revoked` (403) — the key exists and was withdrawn. Distinct from the previous one at the point where it is acted on, and the two MUST NOT be presented as interchangeable.
  - `sdk_application_not_allowed` (403) — the key exists and this application identifier is not declared on it.
  - `sdk_rate_limited` (429) — too many exchanges from this key or this address. **It is not always transient, and an implementation MUST NOT present it as such.** Repeated sanctions escalate: at the third the caller's address is added to a block list with no expiry, and every later exchange from it answers this same code until the block is lifted, which the integrator asks their Fastory contact for. A host that retries in a loop is therefore the host most likely to earn the permanent form of it. Back off, and surface it rather than absorb it.

  **Two refusals never leave the device, for the same reason twice — the SDK stops before a request exists.** A configuration with no key, or a blank or malformed one, is rejected at `configure` (§ 2.1). And where the application identifier cannot be read, the implementation refuses rather than send a request without it, so the `sdk_application_id_required` a host sees under that name is always the SDK's own.

  With § 9.1's two synthesised codes, a host therefore matches **the four names above, plus `sdk_application_id_required` — always the SDK's, never the endpoint's, per the paragraph above — plus the `http_<status>` family**, and nothing else. `sdk_application_id_required` is named here on purpose rather than left out: an absence would not say whether the code does not exist or whether nobody looked. None of them is the fan's connection — that is `reason=network`, with no code at all (§ 9.1). They are not one class either, and a host that alerts on `code` should not treat them as one: `sdk_key_unknown`, `sdk_key_revoked` and `sdk_application_not_allowed` are back-office or configuration facts, `sdk_application_id_required` is a build problem, `sdk_rate_limited` is a traffic condition, and `http_<status>` is usually something between the SDK and the API rather than the API itself.

  **The channel that carries these codes is § 9.1's failure event**, which every platform gained in 0.4.0: this rule has been normative since 0.3.0 and no implementation honoured it, because none of them had anywhere to put the code — the key was refused, the native error view came up, and the host was told nothing at all. A code the SDK synthesises for an outcome the API never answered (an unreachable endpoint, an unreadable response) is **not** a code and MUST NOT be surfaced as one; it becomes a `reason` instead (§ 9.1).
- **A key resolves exactly one workspace, and the SDK MUST NOT ask the host to confirm which.** The workspace is a property of the key, so an implementation has no second opinion to check it against: what stops a key opening a workspace it does not belong to is the exchange being bound to the host's application identifier, which the API refuses unless the owning workspace declared it on that key. That refusal is unconditional and arrives as `sdk_application_not_allowed`. Implementations MUST surface it like any other failure code and MUST NOT open a hub on the resolved fanzone. Removed in 0.4.0: `workspaceId`, a host-declared cross-check that duplicated this opt-in and could only ever be weaker.
- The endpoint also returns a short-lived session token. Until a route accepts it, implementations MUST discard it — holding an unused credential only creates a leak surface.
- **Configured by key, the warm-up (§ 11) MUST start when the exchange resolves**, for each surface `prewarm` names (§ 2.1) — the hub by default, the membership panel when it is named — under the same gates as the slug path: the host has presented its first screen (§ 2.7), no surface is presented, that surface's warm slot is empty, and the configuration the exchange was run for is still the one in force. A surface the set leaves out MUST NOT be prepared. It MUST NOT start when an identity transition that erases storage (§ 7.4) began since `configure`: a resolution that lands after such a transition prepares nothing. A resolver failure warms nothing and reports nothing — the next presentation loads cold and reports for itself (§ 9). The warm-up subscribes to the resolution once, at `configure`; the fan's Retry (§ 9) re-runs the exchange without re-arming it, since a hub is presented at that point and its page is stashed when it closes.

**Deprecation window.** `fanzoneSlug` remains accepted for the whole 0.x line and MUST keep behaving exactly as in 0.1 — same URL, same warm-up, same events. `prewarm`'s default keeps the warm-up exactly that; a slug configuration that names `membership` prepares no panel (§ 2.1). Each platform marks it deprecated in the way its language allows (Swift `@available`, Kotlin `@Deprecated`, Dart `@Deprecated`); no platform may make it a compile error before 1.0.

### 2.6 Identity (since 0.4.0)

The SDK binds the host application's user to a Fastory **fan** through **one method with three
mutually-exclusive modes**, plus a sign-out. These four names are the entire identity API surface,
and they ship inside third-party integrations, so they are locked exactly like the rest of § 2 (§ 10).

| Mode | What the fan does | Mechanism | Resolves in |
|---|---|---|---|
| `anonymous` | nothing; they are not recognised | No credential at all — each origin's web page mints or reuses its own device visitor. This is the v0.1 behavior, unchanged | **0.4.0** |
| `fanId` | **signs in to Fastory** | The **system browser** only: `ASWebAuthenticationSession` (iOS) / Custom Tabs (Android), through the platform's reference OpenID library (AppAuth). The login returns a single-use authorization code, exchanged server-side — with PKCE, the publishable key and the application identifier — for the same fan session `hostToken` resolves. Requires configuration by publishable key | **0.5.0** |
| `hostToken(jwt)` | nothing; the host app already signed them in | The partner's backend asserts the identity as a signed JWT, which the SDK forwards for server-side verification (§ 12). Requires configuration by publishable key — the exchange is bound to the resolved workspace | **0.5.0** |

Two properties of that table are easy to get backwards:

- **`hostToken` involves no browser and no form.** It is precisely the mode in which the fan interacts
  with nothing: the partner has already authenticated them, and the account *travels* rather than being
  re-created. An implementation that opens a browser for `hostToken` is incorrect, not merely
  suboptimal.
- **`fanId` takes no argument.** It is a login, not an identifier: the credentials are typed in the
  system browser, which is also the only path that reaches the device's password manager. **No login
  form may ever render in a WebView**, on any platform, in any mode.

**A sign-in entry on a page the SDK presents asks the host, or is not shown** (since 0.5.0). The
hub, the membership panel and the games carry sign-in entries of their own — a *Log in* button, a
contest reserved to signed-in fans, a game's end offering to save the score. Inside an SDK WebView
none of them may open a login form, a drawer, a popup or any other window: signing the fan in belongs
to the host, through `identify`. What a page does instead follows from `handlesLoginRequests`
(§ 2.1), which it reads from the `hostLogin` parameter of the address it was loaded with (§ 3.2,
§ 3.3, § 3.5):

- **Declared.** The page keeps its sign-in entries. A fan's tap on one posts
  `fastory:login-requested` (§ 13.3) and does nothing else. The host then signs the fan in its own
  way — its own login followed by `identify(hostToken)`, or `identify(fanId)` and the system browser
  — and the identity that call resolves reaches the hub and the games (§ 2.6.1, § 13.9). The page
  MUST NOT post the message without a fan's gesture: loading a page, reaching a locked one or
  completing a game never asks the host to show its login.
- **Not declared.** The page shows no sign-in entry. An entry whose only effect is to sign in is not
  rendered, and content reserved to a signed-in fan says that the fan signs in from the app, with no
  control attached. A host that declares nothing therefore never hands a fan a control that does
  nothing.

The SDK's whole part is to forward the declaration on the URLs it builds and to deliver the message
(§ 13.4): it opens nothing on it and changes no navigation (§ 13). **A host that declares the
capability MUST listen for the message** — declared and unheard, every sign-in entry becomes a
control that does nothing, and no event tells the host so. The page reads the parameter only where it
runs inside an SDK WebView: carried onto a page opened in a browser, it changes nothing there.

A reserved mode MUST fail fast with `identify_mode_unavailable` (§ 5.4) until the version that
implements it — never a silent no-op, never a partially resolved state. Since 0.5.0 no mode is
reserved: all three resolve. The failure remains, though, in one case that is not a version gate:
**an identified mode asked of an SDK configured by fanzone slug** — `hostToken` or `fanId` alike —
fails with `identify_mode_unavailable`, because the deprecated slug path carries no publishable key
to prove the caller with and no workspace to bind the exchange to. Each mode's signature was
normative from 0.4.0 regardless, so shipping its behavior later was not a source-breaking change for
hosts: the mode set and the error set were both complete then, which is the point of specifying them
ahead of their behavior.

Three properties of the `fanId` login, all normative:

- **The browser leg opens only after the caller is proven.** The workspace resolution (the
  publishable-key exchange of § 2.5) runs first, so a refused or unknown key fails before the fan is
  ever shown a login. A missing application identifier fails the same way it fails the key exchange:
  `identify_rejected` carrying `sdk_application_id_required` in `details.code`.
- **The redirect back to the app is derived, never supplied.** Its form is
  `<application identifier>://fastory/callback`, where the application identifier is the bundle
  identifier (iOS) / package name (Android) already bound to the publishable key. The server refuses
  a code minted for any other pair, and the PKCE verifier — generated and held by the OpenID library —
  ties the exchange to the app that opened the login. A host never chooses, passes or configures the
  redirect.
- **A dismissed login is a resolution failure, not a pre-flight.** The fan walked away from a login
  the SDK had already committed to: the call fails with `login_cancelled` and the SDK lands on
  anonymous (§ 2.6.1), never on the previously resolved fan. An already signed-in fan in the system
  browser is not asked to type again — the login round-trips through the existing web session and
  returns at once.

#### 2.6.1 State transitions

The whole of `identify` follows from one rule:

> The SDK erases the previous identity's per-origin storage (§ 7.4) **only when the resolved identity
> differs from the current one.**

- **`identify(anonymous)` while already anonymous is a no-op.** Same fan, no erasure, no new visitor,
  no second `identityResolved`. This is what makes repeated calls **idempotent**, and it is the reason
  the rule is written as a difference rather than as an unconditional reset: erasing here would force
  the web to mint a fresh visitor on the next load, so every call would hand back a *different* fan.
- **Resolving a different identity replaces the session.** Erase first (§ 7.4), then resolve. Nothing
  of the previous fan survives — including the warm hub and the preloaded games.
- **A refusal leaves the SDK anonymous.** Not half-identified, and not still the previous fan: the call
  surfaces a typed error (§ 5.4), emits no `identityResolved`, and the next surface load mints a plain
  anonymous visitor. A failed `identify` is therefore **not** a no-op — implementations MUST NOT keep
  the previous identity on failure, which is exactly the shape that leaves a live session the host
  believes is gone.
- **`logout()` erases and returns to not-identified.** It is idempotent, it MUST NOT touch the host
  application's own session (§ 12), and it needs no network call to be complete. It also revokes the
  standing bridge answer (§ 13.8.6), unconditionally — including when no identity was ever resolved,
  since a host may set the answer by hand without ever calling `identify`.
- **A hub on screen follows the identified fan** (since 0.5.0). A transition that changes *which* fan
  is identified — none to one, one to another, one to none — MUST reload the presented hub through the
  session handoff, so the page shows the fan the SDK now holds, or no fan. A transition that leaves the
  identified fan as it was MUST NOT reload it: the same fan identified again, the § 2.6.3 renewal, and
  a move between not identified and anonymous, neither of which identifies anyone. The membership
  panel is not reloaded. § 7 holds the rule in full.
- `identify` MUST NOT block the caller, and MUST NOT throw across the bridge (§ 5.4). It MAY be called
  before or after `openGames()`. Calling it before `configure()` fails with `not_configured` — the same
  code `openGames()` already uses, not a new one.
- **Re-configuring does not change the resolved identity** — but it does revoke the standing bridge
  answer when the configuration differs (§ 13.8.6). `configure` MAY be called again (§ 2.1) and the
  identity survives it, because a host that re-configures with the same workspace has not changed who
  the fan is; the two rules differ because the identity is a mode the host asked for, while the
  standing answer is a credential minted against a specific environment and workspace. The consequence is on the host: a host that switches **environment or workspace** at
  runtime MUST call `logout()` **before** re-configuring, since § 7.4 erases the origins of the
  configuration in force when it runs — erase after the switch and the previous environment's cookies
  are the ones left behind. Runtime environment switching is not a supported integration pattern; this
  rule exists so the one app that tries it does not discover the ordering by leaking a session.

#### 2.6.2 `identityResolved`

A successful resolution emits `identityResolved` **exactly once** (§ 5.3). It MUST be emitted **before**
any `hubOpened` or `gameOpened` the SDK emits for a surface loaded with that identity, so a host never
attributes a session to the wrong fan. The event means *an identity was resolved*; a refusal emits
nothing and reports its error to the caller instead.

Its `fanId` is `null` in `anonymous` mode, and that is normative rather than incidental: the device
visitor is minted **per origin, by the web page**, so the native side never sees it and cannot report
it. A host MUST NOT expect a stable anonymous identifier from the SDK. What *is* guaranteed for
anonymous is the idempotency above — the same fan across calls — not a value naming them.

In `hostToken` mode `fanId` is **non-null**: it is the fan account's identifier, stable across
repeated assertions of the same partner subject, which is what makes a re-`identify` of the same fan
idempotent (§ 2.6.1). It is an opaque string a host may key on; it is not the partner's own subject,
the visitor, or a fanzone profile id (a delegated fan has no fanzone profile until they earn one).

#### 2.6.3 Delegated session lifecycle (since 0.5.0)

A `hostToken` identity is backed by an embed session with a short lifetime. The SDK keeps the fan
identified across that lifetime without a visible break, and drops the identity cleanly when it cannot.

**Renewal.** Before the embed session expires, the SDK MUST renew it, ahead of time and off the host's
critical path — the fan never meets a dead session mid-game or mid-purchase. It renews in two steps:
first a server-side refresh of the session while it is still valid, involving no one; and when that is
refused, a fresh assertion obtained from the host through `setHostTokenProvider` (§ 5.2) and
re-exchanged. The SDK reads the `exp` of **its own embed session** to time this; it MUST NOT inspect
the host's token (§ 12). Transmitting a renewed token MUST be non-blocking. A renewal that lands
announces itself to the live game pages through the session-change signal (§ 13.9), so a page
mid-game re-reads its session instead of running the old one to expiry.

**The provider.** `setHostTokenProvider` registers the closure the SDK calls back — `requestHostToken`
(§ 5.2) — when it needs a fresh assertion. A provider that returns `null`, or none registered at all,
means the session simply lapses.

**Revocation.** When a session expires with no way to renew it, or a background re-exchange is refused,
the SDK MUST drop the identity to anonymous — erasing per § 7.4, revoking the standing bridge answer
(§ 13.8.6) — and emit `identityRevoked` (§ 5.3) carrying a `reason` the host can act on: `expired` when
nothing could renew it, `rejected` (with the API's `code` when it named one) when a re-exchange was
refused. A refused session MUST NOT leave a blank panel: the host is told, and may re-`identify` or let
the fan continue anonymously. The live game pages are told the same way as for a renewal (§ 13.9):
the signal fires, the page re-asks, and `unavailable` (§ 13.8.2) is the answer that tells it the fan
is gone.

**Persistence.** The verified identity — its `mode` and `fanId`, never the host token or the embed
session — MUST survive between launches, scoped to the workspace and environment it was resolved under.
The SDK rehydrates it **as early as it can reach a stored identity** — no later than the panel opening,
so the panel is never shown before the last known fan — rather than re-verifying from scratch;
rehydration MUST NOT emit `identityResolved` (it restores, it does not resolve), and the session behind
it is re-established in the background. What rehydration guarantees is the **identity**, not the
surfaces' live session, which the background re-exchange restores. (The exact moment is a platform
detail: where the SDK holds an application context at startup it rehydrates then; where it first
receives one when the host opens the panel, it rehydrates there — both before anything renders.)

### 2.7 Threading (since 0.4.0)

Which thread a host may call from was **implicit until 0.4.0**, and the implementations disagreed with
each other about it: `identify` and `logout` returned to the main thread before doing anything, while
`configure` — the entry point doing the most main-thread-only work — ran on whatever thread it was
called on. Initialising the SDK from a background bootstrap, which is a common pattern, therefore
crashed the host app at launch. This section closes that.

| Method | Thread the host may call it from |
|---|---|
| `configure` | **any** |
| `identify` | **any** |
| `logout` | **any** |
| `close` | **any** |
| `setBridgeReply` | **any** |
| `openGames` | **main thread only** |
| `openMembership` | **main thread only** |

- **Implementations MUST NOT require the host to be on the main thread**, except for the two
  openings, `openGames` and `openMembership`.
  Work the platform restricts to the main thread — allocating or destroying a WebView, calling
  `load`/`loadUrl`, `stopLoading`, presenting or dismissing a view controller or an Activity — is the
  SDK's own to schedule there. A host that gets this wrong crashes at launch (`A WebView method was
  called on thread …`, or UIKit's own main-thread checker), which is not a failure mode a contract may
  leave to be discovered.
- **The two openings are the exceptions, and that is not an inconsistency**: each takes the host's
  own UI object — a `UIViewController` to present from, a `Context` to start an Activity from — so a
  caller holding one is already in UI code. Requiring the main thread there asks for nothing a host
  is not already doing. What makes them the exceptions is that they present, not that they take a
  platform object: Android's `configure(context, …)` (§ 2.3) takes a `Context` too, presents nothing
  and keeps only the application context, so it stays callable from any thread like the rest of the
  table. The sequence `openMembership` may name (§ 3.5) changes nothing here: it is a string, read on
  the caller's thread like any other argument.
- **A method callable from any thread MUST still be observable the instant it returns.** Concretely:
  `configure` MUST store the configuration synchronously, so the documented `configure()` then
  `openGames()` sequence cannot fail with `not_configured` because the store was queued. Deferring
  the *whole* of `configure` is a correct-looking fix that breaks the contract above it.
- **Every callback, completion and event the SDK hands the host MUST arrive on the main thread**,
  whichever thread the call came from (§ 2.6, § 5.3, § 13.4). That half was already specified and is
  unchanged.
- **State the SDK exposes to the host** (`config`, `identity`) is written from the caller's thread and
  read from the main one, so implementations MUST make those reads safe — a lock or the platform's
  equivalent. State the SDK only ever touches on the main thread needs nothing, and confining it there
  is the preferred answer: it is a stronger guarantee than a lock and it cannot be forgotten halfway.

The warm-up (§ 11) — of whichever surfaces `prewarm` names (§ 2.1), the hub alone by default — is
scheduled rather than immediate, and that is normative too: **an implementation MUST NOT build or
load a prepared WebView before the host application has presented its first screen.** A
configuration that names nothing to prepare has nothing to wait for either.
A host configures the SDK from its launch path, so warming up inline puts the SDK in competition with
the host's first paint — and on a background launch there is no screen to be fast for at all. The
warm-up MUST still happen once the host is on screen: this is a deferral, not a removal, and the
startup gain may not be paid back as latency when the fan opens the hub. The gate binds every
warm-up, whatever schedules it — the one `configure` schedules on the slug path and the one the key
exchange's resolution triggers (§ 2.5) alike: a resolution that lands before the host is on screen
waits for the screen, and one that lands on a background launch prepares nothing until the
application comes to the foreground. On Android the gate reads the **process** lifecycle, not an
Activity's: the SDK has no Activity of its own before the hub is presented, and a host configures
from its `Application` or from a background entry point that has none either.

The Flutter bridge is unaffected: platform-channel calls already arrive on the platform thread, and
the plugin forwards them straight to the native core, which now carries the rule.

---

## 3. URL Construction

### 3.1 Environment base URLs

| Environment | Base URL |
|---|---|
| `production` | `https://fanzone.me` |
| `staging` | `https://staging.fanzone.me` |
| `development` | Integrator-provided (`developmentBaseUrl` on Dart and Kotlin, `.development(baseURL:)` on Swift) — MUST be `https` |

The configured base URL origin (scheme + host + port) is referred to below as the **Fanzone origin**. All origin comparisons MUST be exact (no subdomain wildcards) and case-insensitive on the host.

**The API base is a different host, and § 2.5's `{apiBase}` is this table** — it was used normatively there and defined nowhere, which left an integrator on an egress allow-list no way to know what the SDK dials:

| Environment | API base (`{apiBase}`) |
|---|---|
| `production` | `https://api.fastory.io` |
| `staging` | `https://api.staging.fastory.io` |
| `development` | the same `developmentBaseUrl` as the Fanzone base — an integrator serving a development Fanzone serves its API too |

Only the publishable-key path reaches it (`POST {apiBase}/sdk/auth/bootstrap`, § 2.5). The deprecated `fanzoneSlug` path calls no endpoint at all, which is what makes it safe to ship ahead of an API deployment.

### 3.2 Hub URL (WebView A)

```
{base}/{fanzoneSlug}?tab={hubTabSlug}&chrome=0&consent=0[&locale={locale}][&theme={theme}][&hostLogin=1]
```

`fanzoneSlug` is the configured one, or the one resolved from the publishable key (§ 2.5).

| Param | Value | Purpose |
|---|---|---|
| `tab` | `hubTabSlug` | Selects the hidden games tab of the Fanzone |
| `chrome` | `0` | Hides web navigation chrome (header/footer) |
| `consent` | `0` | Marks consent as handled by the host app; the web player suppresses its own cookie banner and does not assume analytics consent |
| `locale` | `locale` config value | Optional locale hint; omitted when not configured |
| `theme` | `light` \| `dark` | Optional appearance hint; omitted when not configured. The web side does not read it yet, so it is inert until it ships there |
| `hostLogin` | `1` | *Since 0.5.0.* Present only when the configuration declares `handlesLoginRequests` (§ 2.1), and then exactly once — never added a second time, never sent as `0`. The page keeps its sign-in entries and routes them to the host (§ 2.6); absent, it shows none |

Example: `https://fanzone.me/your-fanzone?tab=games&chrome=0&consent=0`

A hub that adopts the fan's session loads through a single-use session handoff first (§ 7), and lands on this address: the parameters above, `hostLogin` included, reach the page exactly as they would on a plain load.

### 3.3 Game URL (WebView B)

When the interception policy resolves `OPEN_GAME_SHEET` (§ 4), the SDK MUST load the intercepted URL in WebView B **augmented** with:

| Param | Value | Purpose |
|---|---|---|
| `embed` | `1` | Signals embedded rendering to the story player |
| `utm_source` | `sdk` | Attribution of SDK-originated traffic |
| `consent` | `0` | Same consent hint as the hub (§ 3.2), so the game player suppresses its own cookie banner |
| `locale` | `locale` config value | Optional; omitted when not configured |
| `theme` | `light` \| `dark` | Optional; omitted when not configured |
| `hostLogin` | `1` | *Since 0.5.0.* Present only when the configuration declares `handlesLoginRequests` (§ 2.1), never sent as `0`. The game keeps its sign-in entries and routes them to the host (§ 2.6); absent, it shows none |

Existing query parameters on the intercepted URL MUST be preserved, and a parameter above that the URL already carries MUST NOT be added a second time. This matters for `locale` and `theme` in particular: the fanzone builds its own game links, and the host's preferences MUST NOT overwrite a value the page already put on the link. It holds for `hostLogin` too: a link the page built from its own address may already carry it, and it is then left as it is.

Example: intercepted `https://fanzone.me/s/summer-quiz` → loaded as `https://fanzone.me/s/summer-quiz?embed=1&utm_source=sdk&consent=0`

### 3.4 Game slug extraction

The game `slug` reported in the `gameOpened` event is the first path segment after `/s/` (e.g. `summer-quiz` for `/s/summer-quiz` or `/s/summer-quiz/anything`).

### 3.5 Bot URL

```
{base}/embed/bot/{workspaceId}[?locale={locale}][&consent={0|1}][&sequence={sequenceId}][&hostLogin=1]
```

`workspaceId` is the workspace identifier the publishable-key exchange returns as `workspace.id` (§ 2.5).

| Param | Value | Purpose |
|---|---|---|
| `locale` | `en` \| `fr` \| `es` | Optional language of the page; it applies to this page only, and an unsupported value is ignored |
| `consent` | `1` \| `0` | `1` records that the host already collected the fan's analytics consent; `0` or absent records no analytics consent. The page never shows a consent banner of its own |
| `sequence` | sequence identifier | Optional, *since 0.5.0*. Opens the panel on that sequence of the workspace. Absent, the panel opens on its default screen; so does an identifier the panel does not carry — the page falls back rather than failing |
| `hostLogin` | `1` | *Since 0.5.0.* Present only when the configuration declares `handlesLoginRequests` (§ 2.1), and then exactly once — never added a second time, never sent as `0`. The panel keeps its sign-in entries and routes them to the host (§ 2.6); absent, it shows none |

Example: `https://fanzone.me/embed/bot/0vPWx-cZ?locale=fr&consent=1&sequence=2f8a1c64-5b3e-4d71-9a02-7c1e5d3b8f40`

The page renders the workspace's bot alone, filling its frame, with no close control: the host owns dismissal. The platform serves it to any embedding host, and **`openMembership` (§ 2, § 5.2) opens it since 0.5.0**.

The SDK composes this URL itself. The host names one part of it at the call, the sequence, and one through its configuration, `hostLogin`; the rest is the SDK's: `workspaceId` is the one the publishable-key exchange resolved, `consent` is always `0` — the banner is suppressed without asserting analytics consent, as on the hub and game URLs — `locale` is forwarded only when the configuration carries one, and `hostLogin` only when it declares `handlesLoginRequests`. `theme` is **not** forwarded: the page does not read it.

**The parameter is `sequence` and the argument is `sequenceId`** (§ 2.2–2.4, § 5.2). The two names are deliberate — the wire carries the page's vocabulary, the API reads as what a host holds, a string identifying a sequence — and this is the one place that says so. Three rules bind every implementation:

- The identifier is the host's own text and MUST travel as a **query value**, escaped by the SDK. A host passes it exactly as it holds it and escapes nothing: an identifier carrying `&` or `=` would otherwise mint a parameter nobody sent, and one carrying `+` would arrive as a different string — a bare `+` in a query value is read back as a space by the page's decoder, so it MUST travel as `%2B`.
- An identifier that is absent, empty or **blank** (whitespace only) MUST leave the parameter out of the URL entirely. An empty `sequence=` asks the page for a sequence with no identifier rather than for the default screen, and a host reading an empty field out of its own interface has named no sequence.
- An identifier the workspace does not carry opens the **default screen**, like a bare call. The page answers HTTP 200 and the SDK announces an ordinary opening, so a host receives no signal telling a wrong identifier from a right one — the same rule the two pages below follow, and for the same reason.

**A page prepared ahead of time is reusable only for the address being asked for** (§ 5.3). Exactly one address per surface can be prepared, and for this surface it is the default one — the SDK cannot know in advance which sequence a host will name. An opening that names a sequence therefore MUST load when it is asked for, rather than present the page held for the default screen, and **is slower than a bare opening by the cost of that load**. It is the prepared page that makes the bare call instant, not the panel being cheap, so this difference is inherent rather than a defect to report. **And the panel is prepared only when the host asks for it** (`prewarm`, § 2.1): left out of the set, the first bare opening loads when it is asked for too, and the page it leaves on closing, once that page has loaded, is what the next bare opening reuses (§ 11).

A workspace that has not enabled the corresponding add-on receives an explicit refusal page with HTTP 200, never an HTTP error, and a workspace with nothing published yet receives a "nothing to show" page, HTTP 200 as well — so a host WebView that reads a non-2xx status as a failed load sees neither as one. Both therefore commit like any other document and are announced as an ordinary opening (§ 9.1): **a host receives no signal distinguishing them**, by design. Only an identifier that matches no workspace answers with HTTP 404, which is a failed load like any other.

---

## 4. Navigation Interception Policy (URLPolicy)

Every main-frame navigation request in WebView A and WebView B MUST be evaluated **by URL** against the following ordered rules. The first matching rule wins.

| # | Condition | Decision | Behavior |
|---|---|---|---|
| 1 | (Origin == Fanzone origin OR origin is a **stories origin**) AND path starts with `/s/` | `OPEN_GAME_SHEET` | Cancel navigation; open (or replace content of) the game bottom sheet with the URL per § 3.3; emit `gameOpened{slug}` |
| 2 | Origin == Fanzone origin (any other path) | `ALLOW` | Let the WebView navigate in place |
| 3 | Any other `http(s)` origin | `OPEN_EXTERNAL_BROWSER` | Cancel navigation; open the URL in the system browser; emit `externalLink{url}` |
| 4 | Non-`http(s)` scheme (`mailto:`, `tel:`, `intent:`, `market:`, …) | `OPEN_EXTERNAL_BROWSER` | Cancel navigation; hand the URL to the OS (`UIApplication.open` / `Intent.ACTION_VIEW`); emit `externalLink{url}` |

The **stories origins** are the Fastory story-player domains games may be served from:
`https://story.tl` and `https://staging.story.tl` (exact `https` host match, default port). Any
stories-origin URL whose path does not start with `/s/` follows rule 3 (external).

### 4.1 Examples (production, `fanzoneSlug=your-fanzone`)

| URL | Rule | Decision |
|---|---|---|
| `https://fanzone.me/s/summer-quiz` | 1 | `OPEN_GAME_SHEET` |
| `https://fanzone.me/s/wheel-of-fortune?ref=hub` | 1 | `OPEN_GAME_SHEET` |
| `https://story.tl/s/summer-quiz` | 1 | `OPEN_GAME_SHEET` |
| `https://fanzone.me/your-fanzone?tab=games&chrome=0&consent=0` | 2 | `ALLOW` |
| `https://fanzone.me/your-fanzone/legal` | 2 | `ALLOW` |
| `https://www.instagram.com/your-fanzone` | 3 | `OPEN_EXTERNAL_BROWSER` |
| `https://story.tl/x/abc` | 3 | `OPEN_EXTERNAL_BROWSER` |
| `mailto:support@fastory.io` | 4 | `OPEN_EXTERNAL_BROWSER` |
| `tel:+33100000000` | 4 | `OPEN_EXTERNAL_BROWSER` |
| `intent://play#Intent;...;end` | 4 | `OPEN_EXTERNAL_BROWSER` |
| `market://details?id=com.x` | 4 | `OPEN_EXTERNAL_BROWSER` |

### 4.2 Interception points

- **iOS**: `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)` for link navigations, and `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)` for `window.open` (MUST return `nil` and route through URLPolicy).
- **Android**: `WebViewClient.shouldOverrideUrlLoading` and `WebChromeClient.onCreateWindow` (with `setSupportMultipleWindows(true)`), both routed through URLPolicy.
- `window.open(url, '_self')` from the hub MUST be intercepted like any main-frame navigation.
- Sub-frame (iframe) navigations MUST NOT be intercepted; they load in place.
- Rule matching for `/s/` MUST match the path prefix exactly: `/s/` followed by a non-empty segment. `/story/`, `/sea/` etc. do not match.
- If a game (WebView B) navigates to another `/s/` URL, the current sheet MUST load the new game in place (emitting `gameClosed` then `gameOpened{slug}` when the slug changes).

---

## 5. Platform Channel Contract (Flutter)

### 5.1 Channels

| Channel | Type | Name |
|---|---|---|
| Methods | `MethodChannel` | `fastory_sdk` |
| Events | `EventChannel` | `fastory_sdk/events` |

Both channels use the standard method codec (`StandardMethodCodec`).

### 5.2 Methods

#### `configure`

Argument: a `Map<String, Object?>`:

```json
{
  "publishableKey": "fpk_live_...",
  "fanzoneSlug": null,
  "environment": "production",
  "hubTabSlug": "games",
  "locale": "en",
  "theme": "dark",
  "developmentBaseUrl": null,
  "prewarm": ["hub"],
  "handlesLoginRequests": false
}
```

- Every key is always present; unset optional fields are sent as `null`, so a native side can parse a stable shape regardless of which plugin version calls it.
- Exactly one of `publishableKey` / `fanzoneSlug` MUST be non-null (§ 2.1). The Dart side rejects the bad combinations before the channel; the native side re-checks, since a host may call the channel directly.
- `environment` MUST be one of `"production"`, `"staging"`, `"development"`.
- `theme` MUST be `"light"`, `"dark"` or `null`.
- `developmentBaseUrl` MUST be present and non-null when `environment == "development"`, ignored otherwise.
- `prewarm` (since 0.5.0) is a list of surface names — `"hub"`, `"game"`, `"membership"`, the names `surfaceLoadFailed` carries (§ 5.3) — because the codec carries no set; order and repetition mean nothing. The Dart side always sends it, in declaration order. A native side MUST read a `prewarm` that is absent, `null` or not a list as the default, `["hub"]` — what a caller that predates the key asks for — and MUST ignore an element that names no surface, as it reads an unrecognised `theme` as none. Neither is an `invalid_config`: the set chooses what to prepare, and an unknown name has nothing to prepare.
- `handlesLoginRequests` (since 0.5.0) is a boolean, and the Dart side always sends it — `false` when the host declared nothing. A native side MUST read a value that is absent, `null` or not a boolean as `false`, never as `true` and never as an `invalid_config`: the key is a declaration, and a declaration nobody can read is not one — reading it as `true` would hand the fan sign-in entries no host listens for (§ 2.6).
- Returns `null` on success. A rejected configuration MUST fail with `invalid_config` (§ 5.4).

#### `openGames`

Argument: `null`. Presents the hub. Returns `null` once presentation has started.

Errors (`PlatformException.code`):

| Code | Meaning |
|---|---|
| `not_configured` | `configure` was never called |
| `already_open` | **Reserved, and emitted by no platform.** A hub already presented makes `openGames()` a silent no-op returning `null` (§ 2.1), which is what both natives do and what the Dart surface therefore sees. The code is kept declared rather than removed: it is part of a channel contract that ships inside third-party integrations, and § 2.6 froze a surface ahead of its behavior for the same reason |
| `invalid_config` | Malformed configuration (bad URL, empty slug) |

#### `openMembership` (since 0.5.0)

Argument: a `Map<String, Object?>` naming the sequence to open, or naming none:

```json
{ "sequenceId": null }
```

Presents the membership panel (§ 3.5). Returns `null` once presentation has started.

- The key is always present, as on `configure` and `identify`: unset, it is sent as `null`, so a native side parses a stable shape whatever plugin version calls it. A native side MUST also accept **no argument at all** — the shape a host driving the channel directly sends — and read it as no sequence.
- `sequenceId` MUST be a string or `null`. Blank is `null` (§ 3.5): the parameter is left out of the URL and the panel opens on its default screen. A value of neither shape — a host driving the channel directly is not bound by Dart's own type — MUST be read as no sequence too, on both natives, rather than raise or crash: it mints no more of a code than a blank or unknown identifier does (§ 5.4).
- The value crosses the channel as the host wrote it. Escaping belongs to whoever composes the URL (§ 3.5), and doing it twice is how an identifier reaches the page with `%` sequences in it.

Errors (`PlatformException.code`):

| Code | Meaning |
|---|---|
| `not_configured` | `configure` was never called |
| `publishable_key_required` | The configuration in force names a fanzone slug. A slug names a fanzone; this surface is addressed by the workspace a publishable key resolves (§ 2.5), so there is nothing to open. The two refusals are distinct on purpose: a host told only "not configured" calls `configure` again with the same slug |

A call arriving while either full-screen surface is presented or launching is a silent no-op returning `null`, exactly as for `openGames` — no code is minted for it (§ 5.3).

**A sequence mints no code either, and that is why the table above gains no row.** A blank identifier and one the workspace does not carry both open the default screen and return `null` (§ 3.5), so there is nothing for a host to catch and nothing to branch on: a host that needs to know an identifier is good checks it where it comes from, not here.

#### `close`

Argument: `null`. Dismisses the sheet then the hub (no-op if nothing is open). Returns `null`.

#### `identify` (since 0.4.0)

Argument: a `Map<String, Object?>` naming exactly one mode (§ 2.6):

```json
{ "mode": "anonymous", "jwt": null }
```

- `mode` MUST be one of `"anonymous"`, `"fanId"`, `"hostToken"`. Any other value MUST fail with
  `invalid_identity_mode`.
- `jwt` MUST be a non-blank string when `mode == "hostToken"`, and `null` otherwise. A blank or absent
  one MUST fail with `invalid_host_token`; a `jwt` supplied alongside another mode MUST be ignored, not
  rejected — the mode is the discriminator.
- Every key is always present, as with `configure`: unset fields are sent as `null` so a native side
  parses a stable shape whatever plugin version calls it.
- Returns the resolved identity, `{"mode": "anonymous", "fanId": null}`. The Dart side re-checks the
  mode before the channel and the native side re-checks it after, since a host may drive the channel
  directly.

#### `logout` (since 0.4.0)

Argument: `null`. Erases the Fastory session per § 7.4 and returns `null`. Idempotent, and never fails.

#### `setBridgeReply` (since 0.4.0)

Argument: a `Map<String, Object?>` naming a request type and the answer it stands for (§ 13.8):

```json
{ "type": "fastory:user-token", "payload": { "token": "…" } }
```

- `type` MUST be a registry string of § 13.8.3. Any other value MUST fail with
  `invalid_bridge_request_type` — the Dart side cannot produce one (the enum is closed) so this
  covers a host driving the channel directly, exactly as `configure` and `identify` do.
- `payload` MUST be an object or `null`. `null` **clears** the standing answer, after which the type
  is answered `unavailable` rather than with silence (§ 13.8.2). A payload that the platform cannot
  serialise to JSON MUST be refused **here**, not at request time — while there is still a caller to
  report it to.
- The value that crosses the channel is the registry string, never the host language's enum case
  name: `userToken` is a Dart spelling, `fastory:user-token` is the contract.
- Returns `null` on success. This call is the only direction in which a reply is configured; nothing
  is ever pushed into a page as a result of it.
- The argument order is `(type, payload)` on all three surfaces. Swift spells it
  `setBridgeReply(for:payload:)` so it reads as a sentence; the order is the same.

#### `setHostTokenProvider` (since 0.5.0)

Registers — or clears — the closure the SDK calls to obtain a fresh host assertion when a delegated
session needs renewing (§ 2.6.3).

```json
{ "hasProvider": true }
```

- `hasProvider` MUST advertise whether a provider now exists. The provider itself never crosses the
  channel; only whether one is registered does. `false` clears it, after which the SDK stops asking
  and lets an expiring session lapse to anonymous.
- Returns `null`. Registering a provider does not itself renew anything — it is consulted only when a
  session nears expiry or a refresh is refused.

##### `requestHostToken` (native → Dart, since 0.5.0)

The one call that travels **native → Dart**. When the SDK needs a fresh assertion and a provider is
registered, the native side invokes `requestHostToken` (no arguments) over the same method channel;
the Dart side calls the registered provider and returns its result.

- The response MUST be the fresh JWT as a string, or `null` when the host cannot supply one. A `null`,
  an error, or no handler MUST all read as "no token" — the SDK then revokes with `reason: expired`.
- The call is asynchronous and non-blocking: the native side MUST NOT stall the SDK waiting for it, and
  a host that never answers is treated as `null`.

### 5.3 Events

Each event is a `Map<String, Object?>` with a `type` discriminator:

| `type` | Payload | Emitted when |
|---|---|---|
| `hubOpened` | `{"type": "hubOpened", "slug": "your-fanzone"}` | Hub view is presented on a page that loaded. `slug` is the fanzone actually opened: the configured `fanzoneSlug` on the deprecated path, and the `workspace.slug` the exchange returned on the publishable-key path (§ 2.5) — which the host never typed anywhere |
| `hubClosed` | `{"type": "hubClosed"}` | Hub view is dismissed. Emitted once per presentation, when the container is asked to leave; nothing further is emitted for that presentation, whatever its page does while it leaves the screen |
| `membershipOpened` | `{"type": "membershipOpened"}` | Membership panel is presented on a page that loaded. It carries no slug: the panel is addressed by the workspace the key resolved, not by a fanzone — *since 0.5.0* |
| `membershipClosed` | `{"type": "membershipClosed"}` | Membership panel is dismissed, under the same rule as `hubClosed` — *since 0.5.0* |
| `gameOpened` | `{"type": "gameOpened", "slug": "summer-quiz"}` | Game sheet is presented (or replaced) |
| `gameClosed` | `{"type": "gameClosed"}` | Game sheet is dismissed |
| `externalLink` | `{"type": "externalLink", "url": "https://..."}` | A URL is handed to the system browser / OS |
| `bridgeMessage` | `{"type": "bridgeMessage", "bridgeType": "fastory:ready", "payload": {}}` | A web surface posted a valid bridge envelope (§ 13) — *since 0.4.0* |
| `identityResolved` | `{"type": "identityResolved", "mode": "anonymous", "fanId": null}` | `identify` resolved an identity (§ 2.6) — *since 0.4.0* |
| `surfaceLoadFailed` | `{"type": "surfaceLoadFailed", "surface": "hub", "reason": "rejected", "code": "sdk_key_revoked", "statusCode": null}` | A surface did not load (§ 9.1). `surface` is `"hub"`, `"game"` or, since 0.5.0, `"membership"` — *since 0.4.0* |
| `identityRevoked` | `{"type": "identityRevoked", "reason": "expired", "code": null}` | The SDK dropped a delegated identity **on its own** (§ 2.6.3): a session that expired with no way to renew, or a background re-exchange the API refused. `reason` is `expired` (no `code`) or `rejected` (with the API's `code` when it named one). The fan is now anonymous — *since 0.5.0* |

Ordering guarantees:

- `hubOpened` … `hubClosed` MUST bracket every session, and `membershipOpened` … `membershipClosed`
  every membership presentation — once each, across a container the platform rebuilds as well
  (§ 2.1).
- **Only one of the two full-screen surfaces may be presented at a time** (since 0.5.0). `openGames`
  and `openMembership` share one reservation, so a call for either while the other is up or
  launching is the same silent no-op § 2.1 already defines, and the two pairs above can never
  interleave. `close()` dismisses whichever is presented.
- **An opening event announces a surface that loaded, not a container that reached the screen**
  (§ 9.1). `hubOpened` MUST NOT be emitted for a hub whose main document has not committed, and
  `gameOpened` MUST NOT be emitted for a game whose main document has not committed. A surface that
  failed instead emits `surfaceLoadFailed` and **no** opening event — and, having never opened, owes
  **no** closing event when its container goes away. A retry that succeeds opens the session
  normally.
- Warming a surface ahead of time — the hub, or the panel when `prewarm` names it (§ 2.1) — is an
  optimisation, not a presentation: it MUST emit nothing of its own, and it MUST NOT suppress the
  opening event of the presentation that later reuses the warmed page. **The warm-up MUST record whether its page has committed** — observed from its own
  navigation callbacks and never inferred from the WebView's URL: the URL a WebView reports is the
  active or the committed document depending on the platform, and neither tells a page still on its
  way from one that committed — **and MUST hand that to the presentation together with whether a
  load is still in flight.** A presentation taking the slot then meets one of three states, and each
  is normative. A page that **committed** starts committed and announces itself immediately: for it
  the rule above must not be implemented as "wait for a commit callback", which never arrives. A
  page whose load is **still in flight** MUST be reused as it is, without a second load — the
  presentation installs its own navigation delegate on it and announces on the commit that load
  delivers, which does arrive. Only an **empty** slot loads cold. Reading the slot as "the page has
  a URL, so it committed" collapses the second state into the first, and the presentation either
  loads the page again or announces a document that has not rendered. **A committed error document
  is none of the three** (since 0.5.0). Where a platform commits the error document — the server's
  body for a status ≥ 400, its own page for a connection that never came up — a commit proves no
  load, so a page whose last attempt failed MUST NOT reach the slot as committed, nor as in flight:
  the presentation that follows meets an empty slot and loads cold (§ 9.1). **All three states are read
  for the address the presentation asked for**: a prepared page carrying another address is another
  document, so it is loaded rather than shown as what it is not, and whatever it already committed
  announces nothing for this presentation. **The address a slot carries MUST be the one its page was
  asked for**, never the one a navigation left it on: a fan browsing a surface moves the page's own
  address, so a slot stamped with where it ended would match no opening, and a surface reopened after
  any navigation would reload a document already rendered. That is where the membership panel opened
  on a named sequence meets this rule (§ 3.5).
- `gameOpened` / `gameClosed` MUST be properly nested inside the session that opened the game —
  a hub session, or a membership session since 0.5.0: the four URLPolicy rules of § 4 are indexed by
  URL and not by which WebView asked, so a `/s/` link followed from the panel opens the game sheet
  over it exactly as it does over the hub.
- Closing a surface while a game is open MUST emit `gameClosed` before that surface's closing event.
- `bridgeMessage` carries no ordering guarantee of its own: it is emitted whenever a web surface
  posts, and MUST NOT displace, delay or replace any of the five events above.
- `identityResolved` MUST be emitted **once per successful resolution**, and **before** any `hubOpened`
  or `gameOpened` for a surface loaded with that identity (§ 2.6.2). It is not bracketed by a hub
  session: it may be emitted with nothing open, and it MUST NOT be re-emitted when a hub or game opens
  afterwards under the same identity. A refused `identify` emits nothing.
- `identityRevoked` (since 0.5.0) MUST be emitted **only** for a revocation the SDK performs on its own
  (§ 2.6.3): a session that expired unrenewably, or a background re-exchange the API refused. A
  host-driven drop MUST NOT emit it — `logout()` and a replacing `configure()` are actions the host
  already knows about, and an explicit `identify` that fails reports through its own return, not here.

### 5.4 Error semantics

All failures surface as `PlatformException` on the method channel. The SDK MUST NOT throw uncaught native exceptions across the channel boundary.

Identity failures (`identify`, since 0.4.0) — one code per outcome, so hosts branch on the code and
never on the message:

| Code | Meaning |
|---|---|
| `not_configured` | `configure` was never called. Deliberately the same code `openGames` uses, not a new one |
| `identify_mode_unavailable` | An identified mode — `fanId` or `hostToken` — asked of an SDK configured by fanzone slug rather than publishable key (§ 2.6): the slug path carries no key to prove the caller with and no workspace to exchange against |
| `invalid_identity_mode` | The `mode` argument is not one of the three names |
| `invalid_host_token` | The `hostToken` JWT is absent or blank. A malformed or expired one is not caught here — the SDK does not validate the token (§ 12); it comes back as `identify_rejected` with the API's code |
| `login_cancelled` | The fan dismissed the system-browser login (`fanId`) |
| `identify_rejected` | The API refused the identity. The `details` carry its machine-readable `code` when the refusal named one — e.g. a `hostToken` the API could not verify — and no `code` when it did not, as in § 2.5 |
| `identify_network_error` | The identity could not be reached. Distinct from `identify_rejected`: nothing was refused |

Every one of them leaves the SDK **anonymous**, per § 2.6.1 — a code returned here is never a code
returned *instead of* cleaning up. The three that are **pre-flight** (`not_configured`,
`identify_mode_unavailable`, `invalid_host_token`) are the exception the other way: decided before the
exchange, they leave the **current** identity exactly as it was.

Bridge failures (`setBridgeReply`, since 0.4.0):

| Code | Meaning |
|---|---|
| `invalid_bridge_request_type` | The `type` argument is not a registry string of § 13.8.3 |
| `invalid_bridge_reply_payload` | The `payload` argument is present and is not an object, or is an object the platform cannot serialise to JSON |

A refused `setBridgeReply` MUST leave the **current** standing answer untouched. Clearing it on the way
to reporting an error would sign the fan out of the next game as a side effect of a host's typo — and
`null` already means "clear", so a value that is neither an object nor `null` is never a clear.

Note what is **not** here: nothing a *web surface* does reaches this table. A request the SDK cannot
answer is answered — with an `error.code` inside the reply envelope (§ 13.8.2) — and never surfaced to
the host as a channel failure, for the same reason § 13.1 refuses to raise on a malformed message: the
web side deploys on its own schedule, so "I cannot answer that" is a normal outcome, not the host's
problem.

---

## 6. Android Back Button Behavior

On back press (system back gesture or hardware button), in order:

1. If the game toaster is open → close the toaster (emit `gameClosed`). The presented surface stays open.
2. Else if the presented surface's WebView `canGoBack()` → `goBack()` in it.
3. Else → close the full-screen view (emit that surface's closing event).

The three steps are the same for the hub and for the membership panel (§ 3.5), and step 2 is what
makes the panel's back behaviour hierarchical: its page pushes a history entry per tab and per
sub-screen it opens, so back walks a fan out of a sub-screen, then back through the tabs, and closes
the panel only once there is nothing left to leave. The SDK does not drive that — it only dismisses
what it presented — so a page that pushes nothing closes on the first press, which is the correct
behaviour for a page with nowhere to go back to.

Step 2 walks the navigation made since the SDK last loaded the page, and nothing from before that
load. A page taken from the warm slot (§ 11) may still carry the history of the presentation that
handed it back, so a presentation that **loads a document** into it — an address the page does not
carry (§ 3.5), the hub of an identified fan (§ 2.6), a Retry that loads again — MUST clear that
history once that document commits, and only then: cleared with the load, it keeps the outgoing
document's entries; cleared any later, it erases entries the new page pushed on its own. A history
update the outgoing document makes before that commit is not the commit. Until it, the page has
nothing of this presentation to go back to, so step 2 does not apply and back closes. A page
**presented as it stands** has not been loaded again and keeps its history: it shows the fan the
screen they left, and back walks the way they came. The rule binds Android alone, since nothing on
iOS walks a WebView's history.

Implementations MUST use `OnBackPressedDispatcher` (androidx) rather than overriding `onBackPressed` directly, so predictive back keeps working.

iOS has no system back button; the hub MUST provide a native close affordance, and the sheet is dismissible by swipe-down (emitting `gameClosed`).

---

## 7. Session & Web-Storage Model

**The two WebViews do not share a session, and no store configuration can make them.** The hub and
the game are different sites (`fanzone.me`, `story.tl`), and they do not even agree on what a session
*is*: the hub reads a **cookie**, while the game — loaded with `embed=1` (§ 3.3) — takes its session
from its **host page**, not from storage. It asks that page for a token, and in an SDK WebView the
game *is* the top-level document, so it has no host page. A shared cookie jar therefore shares
nothing that matters. The game page still reads and writes storage — its **own** cookies and web
storage, on its own site, as any page does; what it never reads there is a session.

**A shared store does not make the game session-aware.** Following that design to the letter is a
correct implementation of something that has no effect, and it leaves a reader believing the game
already knows the fan.

What each surface does today, with no identity involved (§ 2.6):

| Surface | Session comes from | Consequence |
|---|---|---|
| Hub (WebView A) | a per-origin device-visitor **cookie** the web page mints itself | survives across `openGames()` sessions and app restarts |
| Game (WebView B) | no session — an anonymous visitor the page mints itself | nothing the hub knows about the fan carries over; the page keeps its own cookies and web storage on its own site, so what the game stores stays with the game |

The SDK's part in this is to be **able to address** each origin's store — to scope it and to erase it
per origin (§ 7.4) — not to merge the two.

> *Informative, not normative.* **Two visitors for one account is not a defect to work around.**
> Points are account-scoped, so a fan recognised on both surfaces is recognised once regardless of
> how many visitors the web minted — which is why sharing the store would buy nothing even where it
> worked.

**With a fan identified, each surface takes the session its own way, and the hub on screen follows
it** (since 0.5.0). A game asks the SDK for it over the bridge (§ 13.8) and learns that it changed
through the session-change signal (§ 13.9). The hub reads a cookie and cannot ask: it adopts an
identified fan's session **when it loads**, through a single-use **session handoff** the SDK mints at
that moment — the Fanzone origin exchanges it for the page's own session cookie, then lands on the
hub's § 3.2 address. A handoff that cannot be minted falls back to that address, unadopted: an
anonymous hub is better than a hub that does not open.

A hub already on screen when the identified fan changes would otherwise keep showing the previous fan,
or nobody, for as long as it stays open — over cookies § 7.4 may have erased under it. Implementations
MUST therefore reload the presented hub when an identity transition changes the identified fan, and
only then. The identified fan is the `fanId` of the identity in force — there is none when the SDK is
not identified, and none when it is anonymous (§ 2.6.2) — compared before and after the transition:

| Transition | Presented hub |
|---|---|
| No fan → a fan: an `identify` resolving `hostToken` or `fanId` | MUST reload, signed in as that fan |
| Fan A → fan B | MUST reload, signed in as B |
| A fan → no fan: `logout()`, a § 2.6.3 revocation, an `identify(anonymous)`, or an `identify` that fails and lands anonymous (§ 2.6.1) | MUST reload, anonymous |
| The same fan identified again (§ 2.6.1) | MUST NOT reload |
| The § 2.6.3 renewal — same fan, fresh session | MUST NOT reload |
| Not identified ↔ anonymous | MUST NOT reload — nobody is identified on either side |

- **The reload starts once the erasure the transition carries (§ 7.4) has completed**, and goes
  through a handoff minted for the session in force then — or to the plain § 3.2 address when there
  is none. Reloading earlier would load the previous fan's cookies, or have the erasure remove the
  new fan's.
- **It is not a new presentation.** It emits no opening or closing event (§ 5.3), and a reload that
  fails is a failure after the surface opened (§ 9.1). It is a new document, though: the fan's place
  in the page — its scroll position, a tab its address does not carry — is not kept, and the hub
  being reloaded is covered until the new document has painted, as § 9 requires of an opening that
  loads a page, so the previous fan's hub is not shown meanwhile.
- **Nothing presented, nothing reloaded.** The next opening loads with the session in force, the
  warm page having been discarded by the transition (§ 7.4).
- **The hub is the only surface reloaded.** A game learns the change from the signal (§ 13.9) and
  keeps the fan's progress, which a reload would throw away; the membership panel is not reloaded,
  and a panel on screen keeps the session it opened with until it is closed.

### 7.1 iOS

- Both `WKWebView` instances MUST use `WKWebViewConfiguration.websiteDataStore = WKWebsiteDataStore.default()`.
- The SDK MUST NOT assume this store is its own: it is shared with every other `WKWebView` in the
  host app. That is what makes § 7.4's erasure rules mandatory rather than merely careful.
- The SDK MUST NOT set a shared `WKProcessPool`. It has been deprecated since iOS 15 and "no longer
  has any effect", so setting one is a no-op the compiler warns about. WebKit decides process sharing
  on its own at the SDK's iOS 15 floor.

### 7.2 Android

- Cookies are process-global via `CookieManager.getInstance()`; the SDK MUST call `CookieManager.getInstance().setAcceptCookie(true)`.
- The SDK MUST call `CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)` on **both** WebViews.
- The SDK MUST flush cookies (`CookieManager.getInstance().flush()`) when the hub closes.
- There is no per-instance store on Android: `CookieManager` and `WebStorage` are process-global and
  shared with the host app. As on iOS, this is a constraint on erasure, not a detail.

### 7.3 Persistence

Cookies MUST persist across `openGames()` sessions within the same app install (default persistent
stores on both platforms). Outside the erasure of § 7.4, the SDK MUST NOT clear cookies or web
storage.

### 7.4 Erasure on identity transition (since 0.4.0)

An identity transition (§ 2.6) MUST leave no trace of the previous fan on either surface. Two rules
make that achievable, and both are correctness rules rather than precautions:

1. **Erasure MUST be scoped to the SDK's own origins, by enumeration.** A blanket wipe is
   **forbidden**: `WKWebsiteDataStore.default()`, `CookieManager` and `WebStorage` are shared with the
   host application, so `removeAllCookies()`, `WebStorage.deleteAllData()` or a `.default()` wipe
   would sign the partner out of *their own* services. Implementations MUST delete per origin and
   MUST NOT call any all-origins API.
2. **Cookies MUST be erased by name, from a list the implementation declares.** They cannot be
   discovered: `CookieManager.getCookie(url)` returns only the JS-readable cookies, and the
   identified-fan session cookie is `httpOnly`, so it is invisible to enumeration and can only be
   expired **by name**. Web storage needs no list — per-origin deletion removes it wholesale.

That list is **part of this contract**, not an implementation detail: a cookie the Fastory web
surfaces write and the list does not carry is a fan who survives a logout. Every platform declares
the same names, so a fan signed out on one is signed out on all.

Origins in scope: the configured Fanzone origin **and** both stories origins (§ 4). Erasing only the
Fanzone origin leaves half the fan behind.

Alongside the stores, a transition MUST discard every warm page — the hub's, and the membership
panel's when one is held — and flush the game preloader (§ 11). A warm hub is built on the
configuration's schedule — at `configure()` on the slug path, when
the exchange resolves on the key path (§ 2.5) — so it may be built after an `identify()`, and it
carries whatever session was rendered into it. Two obligations follow: a preparation still pending
when an erasing transition begins MUST be abandoned, so its page never reaches the slot, and one that
completed before it MUST be discarded by the transition. A `WKWebViewConfiguration` is copied at
init, so a live WebView's store cannot be swapped afterwards either way.

**And it MUST drop the standing bridge answer** (§ 13.8.6). That one is not storage the fan's browser
holds — it is a credential the *native* side holds and hands to the game on request, so no amount of
per-origin erasure reaches it. Erasing the stores while keeping it signs the fan out of every surface
that reads a cookie and keeps identifying them to the one that asks the SDK instead.

> **iOS 17's per-identifier store is deliberately not used.** `WKWebsiteDataStore(forIdentifier:)`
> would give atomic isolation, but the SDK floors at iOS 15, so the enumerated path above has to exist
> regardless — and it is the only path Android can have at all. Adopting the store would add a second,
> asymmetric strategy that is untestable below iOS 17, changes nothing about *what* must be erased, and
> resets the session of every existing integration once (the store changes identity). Adopting it later
> changes neither this section's public behavior nor the declared list.

---

## 8. Safe Areas

The two platforms hold the safe area differently, and each rule below is normative for the platform it names:

- **iOS: the SDK holds the top and the sides of the safe area natively, and the hub's page runs to the bottom edge** (the safe area since 0.4.5, the bottom edge since 0.5.0). The hub view MUST pin WebView A to the safe area at the top and on the sides — below the status bar, notch and Dynamic Island included, and clear of the edges the system reserves at the sides in landscape — so the page starts below the status bar from its very first frame, prepared off screen or not. A page prepared off screen is handed its `env(safe-area-inset-*)` values only after its first layout in a window, so a layout that left the page to pad its top painted the first frame of a prepared hub under the status bar; held natively, the top and side insets the page reads are zero, and native and web margins never add up. At the bottom the hub view MUST pin WebView A to the bottom edge of the view, under the home indicator, in portrait, in landscape and on iPad alike: the hub page keeps its last content clear of the indicator itself, from `env(safe-area-inset-bottom)`, and no band is painted there. The SDK MUST disable the WebView's automatic content-inset adjustment: a scroll view that adjusted for the insets would absorb the bottom one, which would then reach the page not at all, or twice. The status bar sits on a band the hub view paints in the system background colour, as do the side edges the system reserves in landscape. When the host application sets the status bar style itself rather than per view controller (`UIViewControllerBasedStatusBarAppearance` set to `NO`), that band MUST follow the style in force when the hub appears — black under light text, white under dark text — so the status bar stays legible. The hub's error view (§ 9) MUST reach the bottom edge of the view too, so no strip of the page shows beneath it, and MUST keep its message and its actions inside the safe area. The game sheet MUST pin WebView B to the safe area on every edge, the bottom included: presented as a sheet in portrait it has no top inset to give, so a game's content ends above the home indicator, on a band in the system background colour — the sheet's band does not follow the host's status bar style, since it leaves no band under the status bar; where the sheet fills the screen, in landscape, the side insets apply as on the hub.
- **Android: the SDK lays its WebViews out edge-to-edge.** The chromeless Fanzone (`chrome=0`) applies its own `env(safe-area-inset-*)` padding, so the web content stays clear of the cutout and the gesture bar. The hub view MUST lay out WebView A edge-to-edge (pinned to the view bounds, not the safe area) so the Fanzone fills the screen top and bottom, and MUST show a black background only during load. The game bottom sheet fills its window edge-to-edge the same way, under the status bar included, the page padding itself there as it does under the cutout.
- The native close affordances — the hub's, and the game sheet's own — MUST remain inside the safe area, on both platforms.
- **The membership panel** (since 0.5.0) is presented the way the hub is (§ 2.2), so every rule above that names the hub view binds the panel's view the same way, on both platforms — its close affordance and its band included — save the bottom edge on iOS. The panel's page pads nothing for the home indicator, so on iOS the panel's view MUST pin its WebView to the safe area on every edge, the bottom included, and its error view stops at the safe area with it; the band then also fills the strip behind the home indicator, in the colour the band under the status bar takes.

---

## 9. Error & Offline Handling

- If a main-frame load fails in **WebView A (the hub)** (no network, DNS failure, HTTP error ≥ 400 on the initial document), the SDK MUST hide the WebView content and show a **native error view**: a short localized message ("Something went wrong" / no-connection variant) and a **Retry** button. Implementations MUST ship the message in English, French and Spanish and resolve it in that order: the first of the device's preferred languages the implementation carries, else the configured `locale` when carried, else English; the two variants MUST be distinct and MUST carry the same text on every platform for the same situation.
- Retry MUST reload the failed URL in the WebView. Where the failure was the publishable-key exchange (§ 2.5) there is no loaded URL to reload, and Retry MUST re-run the exchange instead. **Holding this rule and § 2.1's together is what the implementation actually has to do, so it is written down here rather than left to be re-derived.** The resolver remembers the exchange's outcome per configuration, failure included, and that memory is not a defect: it is what keeps a `configure` carrying the configuration already in force from paying for a round trip and from throwing away a warm hub that has nothing wrong with it (§ 2.1). An explicit retry is therefore told apart from every other caller asking for the same resolution — the fan's retry discards a **failed** outcome, an `openGames()` reads it. The consequences of drawing the line there, rather than at "stop remembering failures": only a failure is discarded, so a resolved workspace stays resolved and a page-level retry on it sends nothing; an exchange already in flight MUST be left to land rather than duplicated, so a fan tapping Retry twice still sends one request; and neither the warm hub nor the preloaded games are touched, because a retry is a request the fan asked for and not an invalidation of what is already rendered.

  **And `sdk_rate_limited` MUST NOT be re-armed at all** — the error view stays and no request leaves the device. This is § 2.5's "MUST NOT present it as such" applied to the one surface that could contradict it: a refusal answers in milliseconds, so the button is back under the fan's thumb at once, and the sanction behind that code escalates on the caller's **address** rather than on the key. Everyone behind one carrier NAT or one venue's wifi shares that address, and a third sanction blocks it with no expiry. A button that spends a request there makes the SDK itself the looping client § 2.5 tells a host not to be. The other refusals cost one request per tap and may legitimately change while the app runs — a key re-issued, an application identifier declared — so they are re-armed. Narrowing § 2.1's stamp is the wrong way to reach the same place — the two rules are held apart there on purpose. The **deprecated slug path is unaffected** (there is always a URL to reload), as is any failure of a surface's own document.
- **Since 0.4.0 the game sheet (WebView B) renders the same error view**, with the sheet's own close affordance still reachable. Until then it showed nothing: a game that 404'd was a black sheet, and the fan had no way to tell a broken game from a slow one.
- **Since 0.5.0 the membership panel renders the hub's error view**: it is presented in the hub's container (§ 2.1), so every rule of this section that names the hub — the error view, Retry, the way out — binds the panel the same way.
- The error view MUST keep a way out visible — the hub's native close affordance, the sheet's own.
- Transient sub-resource failures (images, XHR) MUST NOT trigger the error view.
- The SDK SHOULD show a native loading indicator until the first meaningful load commits.
- **A presentation MUST NOT show what an earlier one left on the page** (since 0.5.0). A page taken
  from the warm slot (§ 11) still shows the screen the presentation that handed it back ended on,
  and one that is loaded again — an address it does not carry (§ 3.5), the hub of an identified fan
  (§ 2.6) — would show that screen until the new document draws. Implementations MUST therefore
  cover a page that carries a committed document with an opaque native view, under the loading
  indicator, the error view and the close control, from the start of the presentation — before the
  address is resolved, which for an identified hub is a round trip — and MUST take the outgoing
  screen out of the screen reader's reach for as long; the loading indicator shows over the cover
  while it waits. Whether the page carries a document is read from its committed history, never
  from its address, which can be the active one from the instant a load starts: a page still on
  its first load — a first opening during the warm-up — shows nothing yet and is not covered. The
  cover comes down when the page proves to be the one asked for, has committed, and is presented
  as it stands, in the same turn so that reopening stays instant — a page reused while it still
  loads over an earlier document stays covered, since until it commits that document is what it
  draws; when the document this presentation loaded has painted content; or when the load fails
  and the error view takes over. Painted, not merely committed, shown or finished: the browser keeps
  the previous page's last frame on screen until the new one paints content, and the native
  callbacks (`onPageCommitVisible`, `didFinish`) can come first, so a cover lowered on them shows
  the outgoing screen again for a frame or more. The page's own Paint Timing entry
  `first-contentful-paint` marks the moment; once the document is shown (Android) or finished
  (iOS), implementations wait for it by the read-only query § 12.1 bounds, polled on a native timer,
  with a native deadline of two seconds after which the page is shown anyway. The loading indicator
  stays over the cover until it goes, and a Retry's wait is announced over only then. A wait started
  for one cover MUST NOT lower another, nor touch a page once its cover is down. A load callback of
  the outgoing document — one that arrives before the latest resolution has answered, or the end of
  an outgoing load its own interrupted — MUST NOT lower the cover. The hub's reload after an
  identity change (§ 7) is not a new presentation, but it loads a document into a page that shows
  one, so it follows this rule too; the address of an earlier resolution does not count as known. A cover rather than a hidden page: a WebView taken off screen may hold back its
  own drawing, and with it the signal that the new document is ready. It is purely visual: the
  opening events (§ 9.1) are decided as before.
- No automatic retries, no offline caching in v0.1. A load the platform's rebuild starts is not a retry of the failed one: a game sheet rebuilt with its screen reloads its page, and since 0.5.0 a container the platform rebuilds while it shows the error view loads its surface again, as its first opening did (§ 2.1).

### 9.1 Reporting a failed load to the host (since 0.4.0)

Showing the error view is half the answer, and until 0.4.0 it was the only half: the fan saw a screen
that did not belong to the app they were in, and **the host application knew nothing**. It could not
log it, alert its team, or fall back to something else. Every implementation MUST therefore also
report the failure, through the `surfaceLoadFailed` event (§ 5.3).

Implementations MUST report:

| Situation | `reason` | `code` | `statusCode` |
|---|---|---|---|
| The publishable-key exchange was refused (§ 2.5) | `rejected` | the API's `code` | `null` |
| The exchange was refused with no `code` in its body | `rejected` | `http_<status>` | `null` |
| The exchange could not be formed: no readable application identifier | `rejected` | `sdk_application_id_required` | `null` |
| The exchange could not be reached | `network` | `null` | `null` |
| The exchange answered a shape the SDK cannot read | `unknown` | `null` | `null` |
| The main document answered a status ≥ 400 | `rejected` | `null` | that status |
| The main document's load failed at the transport level | `network` | `null` | `null` |
| The load failed in a way the SDK cannot classify | `unknown` | `null` | `null` |

- **`reason` is a classification, `code` and `statusCode` are the cause.** Three reasons, not one per
  cause: a host that only needs "was anything reachable at all" answers it from `reason` alone,
  without matching the codes below, while a host that wants to tell a revoked key from an absent fanzone
  reads the code or the status. The reason set is closed and `unknown` is what keeps the other two
  meaning exactly what they say.
- **`code` names a refusal; it MUST NOT be an invented name for a non-answer.** That is the line, and
  it is not the same as "the code is always the API's". An unreachable endpoint and an unreadable
  response are non-answers: implementations mint `sdk_unreachable` and `sdk_malformed_response` for
  them internally, and those two MUST become a `reason` with a **nil** code, or an integrator branches
  on a string no contract defines. A refusal, on the other hand, is a fact even when the API did not
  name it — so the three rows above with a non-nil `code` are exhaustive and **two of the three are
  synthesised**:
  - `http_<status>` — the exchange answered a non-2xx whose body named no `code`, whether that body is
    JSON, something else, or absent (a proxy error page in front of the API is the case).
    Implementations MUST read the status before requiring the body to parse. Dropping the status would leave the host with `rejected` and
    nothing at all.
  - `sdk_application_id_required` — the SDK could not read the host's application identifier, so there
    was no well-formed request to send. It refuses in the API's place rather than sending a request it
    knows will be rejected. Reachable on iOS only in practice (`Bundle.main.bundleIdentifier` is
    optional; a package name is not), but both platforms MUST classify it, and MUST classify it
    identically.

  An integrator matching `code` therefore matches § 2.5's four API names **plus the two rows above**,
  and treats anything else in this field as a defect rather than as an extension of this rule.
  **The table above is the closed list**, and it is closed here on purpose: this is the document an
  integrator holds, so a `switch` written against this table is written against the whole field. A
  code an implementation can produce and this table does not name is a divergence to fix **here**:
  this table is what an integrator holds, so it is the table that has to become complete, never the
  field that quietly gets wider.
- **The event is a report, not a request.** The SDK MUST NOT retry on its own, and MUST NOT change
  what it shows because of it: the error view of § 9 comes up either way. The loads it starts
  without the fan answer the platform, not the report: a game sheet rebuilt with its screen reloads
  its page, and a container rebuilt over its error view asks for its surface again, as its first
  opening did (§ 2.1).
- **A transient sub-resource failure MUST NOT be reported**, exactly as it must not raise the error
  view. Only the main document counts.
- **A navigation the SDK's own URL policy cancelled MUST NOT be reported.** Rule 2 and rule 3 of § 4
  cancel a navigation on every game the fan opens and every external link they follow, and those
  cancellations arrive through the same platform callbacks as a real failure. Reporting them makes
  the event noise, and a host that learns to ignore it has lost the one signal this section adds.
- **One load attempt is reported at most once.** A single failure reaches an implementation through
  several callbacks — a cancelled response, then the cancellation itself — and a host counting
  failures must not count one page twice. A retry is a new attempt and may be reported again, and so
  is the load a container rebuilt over its error view starts (§ 2.1).
- **A failure after the surface opened is still reported.** An in-place navigation inside an open hub
  may fail; the hub did open, so the report is extra information rather than a contradiction, and it
  MUST NOT produce a second opening event.
- **Anything loaded ahead of time MUST watch its own load, discard what failed, and report
  nothing.** This binds the hub warm-up and the game preloading of § 11 equally. Nothing is on screen
  and no fan is waiting, so there is no failed surface to report — the presentation that follows
  loads cold and reports for itself. Discarding is the part that is not optional: an error **body**
  commits and finishes like any other document, so an implementation that only listens for "finished"
  keeps the web's own "not found" page, and the surface that later takes it announces itself open on
  it. That is the whole of this section defeated on the path every opening takes. **And a warm page
  that failed MUST leave the warm slot synchronously, in the callback that observed the failure** —
  only releasing the WebView may be deferred to a later turn — so a presentation in the same turn
  finds an empty slot and loads cold rather than presenting a page that never rendered under a
  loading indicator.
- **A page that failed MUST NOT return to the warm slot when its presentation ends either** (since
  0.5.0). The page a presentation hands back as it closes (§ 11) is bound by the rule above as much
  as a page loaded ahead of time. A page that failed is one left on what its failure produced — the
  error document, or a view the error view hid — and a surface closed on its error view, without a
  Retry that loaded, MUST NOT reopen on it, nor announce itself before a document that loaded is on
  screen. **A commit does not tell a page that failed from one that loaded.** Where a platform
  commits the error document — the server's body for a status ≥ 400, its own page for a connection
  that never came up — that document reaches the commit callbacks like any other, so a slot that
  takes the commit for a load hands the next opening a page that never rendered, which it presents
  as it stands and announces open over a blank screen. An implementation MUST therefore decide from
  the last attempt, never from the commit: a page whose last attempt failed is released when its
  presentation ends, and the next opening asks for its surface again, on a page the fan can see,
  and announces itself on the commit of the load that follows. A platform that refuses an error before it commits, and
  covers the page with its error view rather than hiding it, keeps nothing of the failure in the
  page and MAY hand it back with what it holds — the last document that loaded, or none (§ 5.3).
  The last attempt is the one that counts: a Retry that loaded ends the failure, and its page is
  kept like any page that loaded; a page closed before its load ended has not failed, and is never
  handed back as one that loaded. **What this rule binds today is every failure on Android, and on
  iOS a failure refused before its page commits** — the case the MAY above describes. A failure
  that reaches iOS after the page committed — the connection dropping while the document is still
  loading — is not yet kept out of the slot: once the surface is closed on its error view, the next
  opening presents that page as it stands, without the error view and without loading it again,
  and announces itself open on it.

---

## 10. Versioning & Distribution

- The SDK follows **Semantic Versioning 2.0.0** (`MAJOR.MINOR.PATCH`). The public API surface defined in § 2 and the platform channel contract in § 5 are the compatibility boundary: breaking either requires a MAJOR bump.
- Releases are tagged `sdk-vX.Y.Z` (e.g. `sdk-v0.1.0`).
- Distribution repository: **`KrashStudio/fastory-sdk-mobile`** (GitHub, **public, release-only**) — it receives the clean release package per version, with no development history. Each release carries **two tags on the same commit**: `sdk-vX.Y.Z`, canonical for the Flutter channel and the GitHub Release, and the bare `X.Y.Z`, which exists only because SwiftPM resolves nothing else. A host pinning `ref: sdk-vX.Y.Z` on the Flutter channel and a host whose SwiftPM requirement resolves `X.Y.Z` are on the same code.
- **Two channels ship from that repository, both live.** The **Flutter plugin** (`flutter/fastory_sdk`) since v0.1, and the **native Swift package** (root `Package.swift` + `Sources/FastorySDK`) since **v0.2.0** — `Package.swift` is at the root because SwiftPM cannot resolve a package held in a subdirectory. A native Kotlin artifact on Maven Central and a React Native wrapper follow in later versions; only those two are still unshipped.
- This spec version: **0.5.0**. The public names in § 2 and the channel contract in § 5 are locked (they ship in third-party integrations); any later normative change requires a new spec version and a coordinated SDK release.
- **Changes in 0.5.0.** One version carries the membership panel, the whole delegated-identity surface and a page's request to sign the fan in — six capabilities in one number, as 0.4.0 bundled five: `hostToken`, its renewal lifecycle, the session-change signal, `fanId`, the panel, and the sign-in request. A layout change and two fixes ride along, stated last in that order: on iOS the hub's page runs to the bottom edge (§ 8); and on Android, a page that failed no longer returns to the warm slot when its presentation ends (§ 9.1, § 11), and a container rebuilt over its error view loads its surface again (§ 2.1).

  **`fanId` resolves** (§ 2.6): the fan signs in to Fastory in the **system
  browser** — `ASWebAuthenticationSession` / Custom Tabs through the reference OpenID library — and
  the returned single-use code is exchanged, with PKCE and the caller's publishable key and
  application identifier, for the same fan session `hostToken` resolves. No public name moves and no
  channel shape changes: the signature, its errors (`login_cancelled` included) and the
  `identityResolved` event were all normative since 0.4.0. What moves the version is behavioral:
  the last reserved mode now resolves, `identify_mode_unavailable` narrows to the slug-path case
  (§ 2.6, § 5.4), and the browser leg's three normative properties enter § 2.6 — caller proven
  before the browser opens, redirect derived from the application identifier, dismissal landing on
  anonymous. On Android the OpenID library's redirect receiver requires the host to declare the
  `appAuthRedirectScheme` manifest placeholder as its own application id; on iOS the app declares
  its bundle identifier as a URL scheme. Both are integration steps, not API surface.
  **The bridge gains the session-change signal** (§ 13.9): when the standing
  answer changes — populated, replaced by the § 2.6.3 renewal, or revoked — the SDK dispatches one
  constant, payload-free event in the game WebViews it owns, and a page mid-game re-asks
  `fastory:user-token` instead of running its session to expiry. No public name moves, no channel
  shape changes, no new host event: a host has nothing to do, and a page that never listens behaves
  exactly as it did before the signal existed. § 12.1 gains its **second bounded
  exception**, because the signal is the first thing the SDK evaluates in a page at its own
  initiative. The exception is as narrow as the capability — one byte-for-byte constant statement,
  carrying no data — and every value a page learns still arrives on the § 13.8 reply path. Delivery is
  best-effort and traced (§ 13.6): a page keeps its own expiry guard for the signal that never comes.
  **The delegated session gains a lifecycle** (§ 2.6.3): the SDK renews it before it
  expires, and drops it cleanly when it cannot. Two additions to the surface — `setHostTokenProvider`
  (§ 5.2), the closure the SDK calls back for a fresh assertion, and the `identityRevoked` event
  (§ 5.3), which tells a host the fan lapsed to anonymous and why. Both are additive: the method is new
  and the event enters the sealed `FastoryEvent`, source-breaking a Dart exhaustive `switch` exactly as
  the events 0.4.0 added did, called out in the changelog. What an implementation now does: renew the
  embed session ahead of expiry (a `/embed/auth/refresh` while it is still valid, a fresh assertion
  from the provider re-exchanged when it is not), keep the verified identity across launches and
  rehydrate it at `configure` without re-announcing it, and — this is the **behaviour change** to name,
  not merely an addition — a session that expires unrenewably does not linger silently but lands the
  SDK on anonymous with an `identityRevoked`. Renewal never blocks the host and the
  SDK never inspects the host's token (§ 12); it reads only the `exp` of its own embed session.
  **The `hostToken` identity mode resolves** (§ 2.6). No public name moves and no
  channel shape changes — the mode and its errors were frozen in 0.4.0 — so this is additive in
  behaviour and source-compatible in all three languages. What an implementation now does: forward the
  host's JWT to the delegated identity exchange (never validating it — § 12), bind the resulting
  session to the games through the standing bridge answer (§ 13.8.6, now populated automatically) and
  to the hub through a session handoff, apply the § 2.6.1 difference rule so the same fan is
  idempotent and a different one erases the previous, and land a refusal or a network failure on
  anonymous. Two edges a host meets: `hostToken` requires configuration by publishable key and fails
  `identify_mode_unavailable` on the deprecated slug path (§ 5.4); and the base mode's session lives
  for the token's lifetime, renewed by the SDK only when a host registers a token provider — the
  session lifecycle above.

  **The SDK opens the membership panel** (§ 3.5). `openMembership` joins the public surface as a seventh operation (§ 2, § 5.2), `membershipOpened` and `membershipClosed` join the event stream as a ninth and tenth (§ 5.3), `surfaceLoadFailed` gains the `membership` surface (§ 9.1), and the channel gains one error code, `publishable_key_required` (§ 5.2). Three rules follow the surface rather than the method: only one full-screen surface is presented at a time and the two openings share one reservation (§ 2.1, § 5.3); § 4's four rules are unchanged and apply to the panel's WebView as they do to the hub's, so a game followed from the panel nests inside it; and § 6's back sequence now names the presented surface rather than the hub, and walks only the navigation made since the SDK last loaded the page, since a page kept warm can now be loaded with another address — which is also why § 9 now forbids showing what an earlier presentation left on that page while the new one loads, and why § 12.1 gains a third bounded exception, the read-only paint query that tells when the new page has painted. § 2.1's rule for a container the platform rebuilds, § 8's layout and § 9's error view, all written for the hub, bind the panel the same way, save the bottom edge on iOS (§ 8). The native listeners gain their two callbacks with a no-op default, so a conformer keeps compiling; **the Dart surface is source-breaking in three places**, as in 0.4.0 — two new `FastoryEvent` subtypes and a third `FastorySurface` case break an exhaustive `switch` with no `default:`. **That third place is not Dart-only**: `FastorySurface` is a plain public enum on iOS and Android as well, so a Swift `switch` or a Kotlin `when` used as an expression that already covers `hub` and `game` exhaustively stops compiling on the native channel too, the moment it is built against this version.

  **That panel opens on a sequence the host names** (§ 3.5), and the argument arrives with the
  method rather than after it. `openMembership` takes an optional `sequenceId` on all three surfaces
  (§ 2.2–2.4), the channel call carries a `Map` rather than `null` (§ 5.2), and the URL grammar gains
  `sequence`. § 3.5 holds the whole rule — the two names, the escaping the SDK owes, blank read as
  absent, an unknown identifier landing on the default screen with nothing reported. Naming none is
  the ordinary form: the panel opens on its default screen, which is the workspace's own setting. **Two obligations arrive with it and
  neither is about the signature.** A prepared page is reusable only for the address being asked for
  (§ 5.3): one address per surface can be prepared and it is the default one, so an implementation
  that reads its warm slot by surface alone swallows the sequence on the first opening — the page
  right, the address wrong, nothing failing. And a **named opening is slower than a bare one** by the
  cost of that load, which is why it is stated for integrators rather than left to be measured.
  § 2.7 is unchanged in force: the two openings were already main-thread-only, and its prose now
  names both where it named one.

  **What is prepared ahead of the first opening is the host's choice** (§ 2.1). `FastoryConfig`
  gains `prewarm`, a set of `FastorySurface` values, on all three surfaces (§ 2.2–2.4), and the
  `configure` payload gains the same key as a list of surface names (§ 5.2). It defaults to the hub
  alone, so a host that sets nothing prepares what it prepared before the panel existed; the panel
  is prepared only when it is named. A prepared page is paid for on every launch — a resident
  WebView, a renderer process on Android, and its page's requests — so a host that only ever opens
  the games must not carry the panel's. Four obligations follow. Prepare exactly the named surfaces
  the configuration can address and none other: `membership` is ignored on the deprecated slug path,
  which resolves no workspace, and `game` prepares nothing by itself, since games follow the hub's
  page (§ 11). Accept an empty set, which prepares nothing and still starts the exchange at
  `configure`. Count the field in configuration equality, so changing it replaces the configuration
  and repeating it keeps what is warm. And, on the channel, read an absent or malformed `prewarm` as
  the default and ignore a name no surface carries, rather than refusing the configuration. What the
  set does **not** govern is keeping a page after it closes: a panel opened without being prepared
  loads cold and, once its page has loaded, is warm from then on (§ 3.5, § 11). § 2.5, § 2.7 and
  § 5.3 now name the prepared surfaces where they named the hub, and § 7.4 every warm page where it
  named the warm hub.

  **A page asks the host to sign the fan in** (§ 2.6, § 13.3). No page the SDK presents ever shows a
  login form: a sign-in entry on the hub, the membership panel or a game either asks the host or is
  not shown, and the host decides which. `FastoryConfig` gains `handlesLoginRequests` on all three
  surfaces (§ 2.1–2.4), `false` by default and last among the Kotlin parameters, and the `configure`
  payload gains the same key (§ 5.2). Declared, it reaches the pages as `hostLogin=1` on the hub,
  panel and game URLs (§ 3.2, § 3.3, § 3.5): their sign-in entries stay, and a fan's tap posts
  `fastory:login-requested`, the second type of the § 13.3 registry, to which the host answers by
  signing the fan in and calling `identify`. Not declared, the pages show no sign-in entry, so no host
  ships a control that does nothing. Three obligations arrive with it. Deliver the message and do
  nothing else with it: it is receive-only, has no reply, and opens, closes or navigates nothing
  (§ 13). Accept it from an Android sub-frame like any registry type — bounded, since its payload
  asserts nothing (§ 13.7). And reload the presented hub, through the session handoff, when an
  identity transition changes the identified fan — never for the same fan, the § 2.6.3 renewal or a
  move between not identified and anonymous; the membership panel is not reloaded (§ 2.6.1, § 7).
  Additive on every channel: a defaulted field, a defaulted initializer parameter and a new registry
  string, and a native side reads a `handlesLoginRequests` it cannot read as `false` rather than
  refusing the configuration.

  **On iOS the hub's page runs to the bottom edge** (§ 8). Since 0.4.5 the hub's WebView was pinned
  to the safe area on every edge, so the hub ended above the home indicator, on a plain band in the
  system background colour. It now runs to the bottom edge of the view, under the home indicator,
  with no band there, and the hub page keeps its last content clear of the indicator from
  `env(safe-area-inset-bottom)` — the arrangement Android already had. The top and the sides stay
  pinned to the safe area, for the reason § 8 gives, and the automatic content-inset adjustment stays
  disabled, now so that the bottom inset reaches the page exactly once. The hub's error view reaches
  the bottom edge with the page. The membership panel keeps its WebView inside the safe area on every
  edge, since its page pads nothing for the home indicator, and the game sheet is unchanged. No public
  name moves and no channel shape changes: a host has nothing to do.

  **A page that failed no longer returns to the warm slot when its presentation ends** (§ 9.1,
  § 5.3, § 11). § 9.1 kept a failed page out of the slot only when it had been loaded ahead of time,
  and § 11 filled the slot with whatever a presentation handed back. On a platform that commits the
  error document, a surface closed on its error view therefore went back counted as loaded: the next
  opening presented it as it stood — on Android a page the error view had hidden, so a blank screen
  with only the close control — and announced the surface open over it, opening after opening. 0.4.5
  shipped this for the hub, and the panel inherits the container. A page whose last attempt failed
  is now released instead of handed back, so the next opening starts over on a fresh page and
  announces itself only on the commit of the load that follows; a Retry that loaded ends the failure, and its page is kept as
  before. On iOS a failure that arrives after its page committed is not covered yet (§ 9.1).
  **A container rebuilt over its error view loads its surface again** (§ 2.1) rather than
  standing on the failed page: like the game sheet's, whose page already reloaded with a rebuilt
  screen and is the precedent, it is a load the SDK starts without the fan's Retry, an exception
  § 9 and § 9.1 now name. No name, signature or event moves; a host counting openings stops
  receiving them for surfaces that never loaded.
- **Changes in 0.4.5.** One capability reaches the path every new integration takes and brings
  obligations with it, one section is rewritten to what iOS now does, and one sentence that recorded
  a defect as the implementation's state is replaced by the rule — which is why the version above
  moves.

  **On iOS the hub and the game sheet are laid out inside the safe area** (§ 8). The section required
  an edge-to-edge hub on a black background, the page padding itself from `env(safe-area-inset-*)`.
  A page prepared off screen is handed those insets only after its first layout in a window, so the
  first frame of a prepared hub was painted under the status bar, and the game sheet's bottom edge
  sat under the home indicator. § 8 now requires, on iOS, both WebViews pinned to the safe area on
  every edge, with the system bars on a band in the system background colour — the hub's following
  a status bar style the host application forces; Android keeps its edge-to-edge layout, hub and
  sheet alike, and the page keeps padding itself there. The sheet's former height suggestion is
  gone: neither platform sizes it that way. An integrator has nothing to do on either platform.

  **A container the platform rebuilds continues the presentation** (§ 2.1). The section said that
  Android surfaced a rebuilt hub as a `hubClosed` immediately followed by a `hubOpened`, and that
  telling a rebuild from a dismissal was not in 0.4.0. It is in 0.4.5, and it is now the rule: a
  rebuilt hub, and a game sheet rebuilt with it, MUST emit nothing — save a game that opened after
  the platform saved the hub's state, which is reported closed and reopened — and the presentation
  ends on a dismissal, one `hubClosed` preceded by one `gameClosed` when a game was open, or when
  the platform drops the saved container and the next `openGames()` starts a new one. § 5.3's count
  of one opening and one closing event per presentation now holds across a rebuild.

  **Configured by key, the hub is prepared ahead of the first opening.** Until now only the deprecated
  slug path warmed the hub: § 2.5 said no warm-up was possible before the exchange resolved, and no
  platform prepared anything once it had. The first opening of a hub configured by key therefore
  always loaded cold, under a loading indicator, while the second was instant. § 2.5 now requires the
  warm-up to start when the exchange resolves, behind exactly the gates the slug path already had —
  § 2.7's first screen, no hub presented, an empty slot, the configuration still in force — plus one
  the slug path never needed: a resolution that lands after an identity transition erased storage
  MUST prepare nothing (§ 7.4). A resolver failure warms nothing and reports nothing; the next
  presentation loads cold and reports for itself. § 7.4 no longer says the warm hub precedes every
  `identify()`, since on the key path it may not: a pending preparation MUST be abandoned by an
  erasing transition and a completed one discarded by it. § 2.7 states that the first-screen gate
  binds the resolution-triggered warm-up too, and that Android reads it on the process lifecycle.

  **Android gains `configure(context, config, listener)`** (§ 2.3), because the key path could not be
  prepared without it: the exchange needs the application identifier, which the context-less form
  cannot supply, so it waited for the first `openGames(context)` and nothing could be warmed before
  that. The new overload starts the exchange at `configure` and prepares the hub behind the gate
  above; the context-less form is deprecated, keeps behaving exactly as before for the whole 0.x
  line, and is removed in 1.0. § 2.7's threading table is unchanged — the overload presents nothing
  and stays callable from any thread; `openGames` remains the one main-thread method.

  **A warm page that failed MUST leave the slot synchronously** (§ 9.1). Discarding a failed warm-up
  was already required; *when* was not, and an implementation that emptied the slot a turn later let
  a presentation in that turn take a page that never rendered. The release of the WebView may still
  be deferred; the slot may not.

  **A warm page still in flight MUST be reused as it is, and the warm-up MUST know whether its page
  committed** (§ 5.3). The ordering rule said a warmed page announces itself immediately because it
  has committed, and said nothing about a page taken from the slot between the start of its load and
  its commit — an implementation that told the two apart by whether the WebView had a URL loaded the
  in-flight page a second time, or announced it before it rendered. The warm-up now records the
  commit from its own navigation callbacks, never from the URL, and hands the presentation both that
  and whether a load is in flight: a committed page starts committed, a page in flight is reused
  without a second load and announces on the commit that load delivers, and only an empty slot loads
  cold.

  What an implementation must do: subscribe to the exchange's resolution once at `configure`, run the
  slug path's warm-up from it under the slug path's gates plus the identity check, empty the warm
  slot in the failure callback itself, carry "committed" and "load in flight" on the warm slot from
  the warm-up's own callbacks, and — on Android — expose the `Context`-taking `configure`.
  § 2.1's teardown rule is unchanged in force and restated in the present tense: the warm-up now waits
  on two things rather than one, and the teardown still waits on neither.

  **Two signatures were corrected to what has always shipped, at constant obligation.** § 2.3
  declared `FastoryEnvironment` as a sealed class carrying the development base URL; the Kotlin
  type is an enum and the URL is `FastoryConfig.developmentBaseUrl`, as the same section's
  `FastoryConfig` and § 2.1's table already said. § 2.2 names the `invalidIdentityMode` case of
  `FastoryIdentifyError`, whose code § 5.4 already listed. No implementation has anything new to do.

  **One alignment carries no new obligation and is recorded because it is observable.** § 13.1 has
  always required that neither platform decode an envelope the other rejects, and this is the first
  version where that holds for the valid JSON the two platforms' parsers used to read differently.
  The readings both platforms now share: a name repeated within one object is read at its first
  occurrence, and two spellings of one name that are canonically equivalent are that same name
  repeated; a number too large to be finite, held by an object member, makes the message ignored —
  answered `malformed` on the reply channel — while in an array it is read; and a number one
  platform's parser cannot represent is refused on both — an integer written in full past about
  3.4 × 10^165, a decimal of more than 17 digits whose scale cannot be held, an exponent of more
  than four characters, sign included.
- **Changes in 0.4.3.** Two changes of different natures ship together, and the second is why the
  version above moves.

  **The document was corrected without changing what it requires.** Two sentences said the opposite
  of what they meant: § 3.3 wrote `MUST` where the sense required `MUST NOT` — a parameter the
  intercepted URL already carries is not added a second time — and § 13.8.4 had a development
  environment recognising a stories origin the environment does not have. Both now state what every
  shipped implementation already did. The rest is wording. § 2.4 counted three native API surfaces
  where there are two. Four sentences deferring to material outside this package were restated as
  rules this document holds itself, and § 9.1 no longer tells a host in one paragraph to enumerate no
  codes and in the next that its table is the closed list. Sentences that described how Fastory works
  rather than what you integrate against — § 2.1's, § 2.5's and § 9.1's — are gone. And § 2 now says
  which sense of *surface* a sentence carries where two of them could be confused. On their own, none
  of these would have moved the version.

  **§ 9's Retry rule is implemented on the publishable-key path for the first time**: the button
  re-runs the exchange, as this document has required since 0.4.0 and no platform did. That much
  needed no new obligation — but closing it created two, and they are what moves the version. Both
  live in § 9 and both exist to stop the button becoming a loop: an exchange already in flight MUST be
  left to land rather than duplicated, and **`sdk_rate_limited` MUST NOT be re-armed at all**, because
  that code's sanction escalates on the caller's address and a fast refusal puts the button straight
  back under the fan's thumb. Neither was owed before, since no implementation retried anything. The
  same section now also states, as a consequence rather than a rule, that an ordinary resolution keeps
  reading the remembered failure — that is § 2.1's cache, written down because every reader was
  re-deriving it. **This is the entry not to skip**: unlike 0.4.1 and 0.4.2, this release asks
  something of an implementation.

  One behaviour change carries no obligation with it, and is recorded here because it is observable:
  both native platforms now give the exchange the same 15 s budget without progress. iOS used to
  inherit `URLSession`'s 60 s default; Android already declared 15 s of its own. This document has
  never specified that wait and still does not — the platforms' phases differ (one inactivity budget
  against a connect budget plus a read budget), so only the budget is shared, not the worst case.
- **Changes in 0.4.2. None — and that is stated rather than left to be inferred.** The release
  rewrote how this document reads, not what it requires: internal references were removed, two rules
  were reworded at constant obligation, and a paragraph forbidding an unspecified future exception
  was dropped because the standing rule of § 12.1 already forbids it. No implementation has anything
  new to do, so the version above does not move. A reader who tracks that number to decide whether
  to re-read the contract can skip this one.
- **Changes in 0.4.1.** No public name moves and no behaviour a host depends on changes. Three normative clarifications, each written because the code already did this and the document did not say so: **a rejected configuration MUST leave the one already in force untouched** — not storing the rejected one is only half of the rule, since the previous configuration keeps applying; **a typed, catchable error MUST be reachable for every rejection**, with the entry point it sits on left to the platform; and **the failure-code table in § 9.1 is itself the closed list**, in place of the files it used to name. A shipped document must not make an authority of anything outside the package it ships in, so the table is now the authority. Nothing here changes what an implementation must do; it changes what this document is willing to be read as saying.
- **Changes in 0.4.0.** One release, **five** capabilities and one removal: everything specified since 0.3.0 arrives at once, because none of it was released separately. An integrator debugging a break still needs to know *which* capability broke them, so each is stated on its own below — the bridge, the identity API surface, the reply channel, a failed load reaching the host (§ 9.1), and the four normative corrections. It was planned as four; § 9.1 entered last, which is why any statement of "four" elsewhere is out of date rather than counting something different. Read the three source breaks first: they are the only reasons an integrator who upgrades has anything to do.
  - **Source breaks.** (1) **Dart's `FastoryEvent` is `sealed`** (§ 2.4) and this version adds three subtypes, `bridgeMessage`, `identityResolved` and `surfaceLoadFailed` — an exhaustive `switch` with no `default:` stops compiling until the host adds all three cases. Deliberate, under SemVer § 4 for a `0.y.z` line, and the last such break planned before 1.0. The two native API surfaces are unaffected: each new callback is defaulted to a no-op (Swift protocol extension § 2.2, Kotlin interface default body § 2.3), so an existing conformer keeps compiling. (2) **Android's reply channel needs `androidx.webkit`** and a WebView of Chrome 85 or later (§ 13.8): `addWebMessageListener` is the only API that reports the posting frame and its origin, and a reply carries a fan credential, so answering an unidentified frame is not an option. Below that floor the reply channel is simply absent and the surface stays anonymous — the rest of the SDK is unaffected. (3) **`workspaceId` is removed from `FastoryConfig`** on all three platforms and from the `configure` channel payload (§ 2.1–2.5, § 5.2). It was a host-declared cross-check against the workspace a key resolves to; a key resolves exactly one workspace, so it duplicated — opt-in, and from the side that does not hold the truth — a refusal the API already makes unconditionally through the key's declared application identifiers (§ 2.5). A host passing it deletes the argument; nothing replaces it, because nothing it protected is now unprotected.
  - **The versioned JS ↔ native bridge** (§ 13). Web surfaces post `{v, type, payload}` envelopes; the SDK ignores anything outside envelope version 1 and its type registry, traces the drop at debug level, and delivers the rest as a sixth event (`bridgeMessage`, § 5.3). Registered on every SDK WebView by native registration alone — **no JavaScript is injected**, which is what keeps § 12.1 intact. Additive in behavior: the bridge takes no part in the § 4 navigation policy, and a web surface that never posts behaves exactly as it did in 0.3.0. The `postMessage` non-goal is retired accordingly (§ 12).
  - **The identity API surface** (§ 2.6), specified and **frozen**: one `identify` method with three mutually-exclusive modes plus `logout`, their channel methods and error codes (§ 5.2, § 5.4), a seventh event `identityResolved` (§ 5.3), and the per-origin erasure contract (§ 7.4). Only `anonymous` resolves; `fanId` and `hostToken` are normative signatures that fail with `identify_mode_unavailable` until their own releases, so shipping them later is not a source-breaking change. The surface had to land before its behavior because adding an enum case or an associated value later breaks source in all three languages.
  - **The bridge's reply channel** (§ 13.8): a web surface may ask the native side a question and receive an answer, correlated by a mandatory `requestId`, on a second entry point (`fastoryRequest`) registered on every SDK WebView. Added because the game needs it — with `embed=1` it asks its host page for the fan's identity rather than reading a session from storage (§ 7), and in an SDK WebView there is no host page. The public surface gains one method, `setBridgeReply` (§ 2.2–2.4, § 5.2), a closed `FastoryBridgeRequestType` registry holding one type (§ 13.8.3), and one channel error code (§ 5.4). **§ 12.1 is not amended**, deliberately: both platforms answer on the channel the request arrived on (WebKit's reply handler, Android's reply proxy), so nothing is evaluated in the page. Pushing into a page unprompted stays out.
  - **A surface that does not load now reaches the host** (§ 9.1, new; § 5.3 gains `surfaceLoadFailed` and the ordering rule behind it). Two halves that were failing in opposite ways. The first was **already normative and unimplemented**: § 2.5 has required since 0.3.0 that a refused publishable key surface the API's machine-readable `code`, and no platform did — a revoked key, an application identifier the workspace never declared and a phone in a tunnel produced one identical error view and told the host nothing, so an integrator could not tell "revoke the key in the back-office" from "the fan is in a tunnel". The second is genuinely new surface: a hub or game whose own document fails had no contract at all, and the game sheet did not even look — it had neither a response policy nor a navigation-failure callback, so a 404 game was a black sheet nobody could see the cause of. It now renders the error view § 9 always promised the hub. The event also fixes the inverse defect: `hubOpened` used to fire on a hub showing the error view, which is worse than silence because the host concludes the opposite of the truth — an opening event now announces a surface that loaded, and a surface that never opened owes no closing event.
  - **Four normative corrections**, no surface change of their own — each closes a gap where the spec said less than the implementations needed it to. **§ 13.8.6**: the standing bridge answer is revoked by `logout()`, by an `identify` resolving a different fan, and by a `configure` replacing the configuration, with § 2.6.1 and § 7.4 pointing at it — declared "standing" and given no end, it would keep answering a game with the previous fan's token and serve a production token to a staging page. **§ 2.1 gains the re-configuration rule**: a `configure` whose configuration differs MUST first discard what the previous one produced, and MUST NOT make that teardown conditional on having something to prepare in exchange — the condition that would let the publishable-key path keep a warm hub rendering the previous fanzone. **§ 2.7 is new**: which thread a host may call from was never stated, while `identify` and `logout` returned to the main thread and `configure` did not, so a background bootstrap crashed the host app; every method is now callable from any thread except `openGames`, which takes the host's own UI object, and the hub warm-up is deferred past the host's first screen. **§ 2.1 also gains the idempotence rule for `openGames()`**, and § 2.3 the `singleTop` launch mode that backs it on Android: asking for the games while a hub was up stacked a second one, so a double tap emitted two `hubOpened` for one visible hub, `close()` finished only the top instance, and the page the hidden one stashed on its way out overwrote the other's without releasing it.
- Changes since 0.1.0: stories origins added to rule 1 (§ 4); hub and game WebViews are kept warm across sessions (behavioral); the consent hint is now `consent=0` on both hub and game URLs (§ 3.2/§ 3.3) — banner suppressed without asserting analytics consent; the `hubOpened` event carries the `fanzoneSlug` (§ 5.3). Changes in 0.1.2: the default `hubTabSlug` is `games` (was `games-app`). Changes in 0.1.3: closing the game sheet discards the played WebView (fresh state guaranteed, audio stops immediately) and the SDK preloads the hub's games via a read-only discovery query (§ 11 — Non-Goals renumbered to § 12). Changes in 0.1.4: preload discovery (§ 11.1) additionally collects direct game URLs — absolute http(s) URLs with an `/s/` path — from the embedded payload, covering hubs whose tiles are plain links rather than `Experience` components. Changes in 0.3.0: `configure` takes a workspace publishable key, exchanged at `/sdk/auth/bootstrap` for the fanzone to open (§ 2.1, § 2.5); `fanzoneSlug` is deprecated but accepted for the whole 0.x line; an optional `theme` (`light`/`dark`) and the existing `locale` are forwarded to the hub and game URLs (§ 3.2, § 3.3); the configure channel payload gains `publishableKey`, `workspaceId` and `theme` (§ 5.2). Changes in 0.2.0: presenting a game sheet releases the warm pool and abandons the load in flight, and closing rebuilds it (§ 11.2) — warm games otherwise hold memory and graphics contexts away from the game on screen; and the staging stories origin is `https://staging.story.tl` (§ 4, § 11.1) — the SDK previously named a host the platform does not serve, so staging games failed rule 1 and were handed to the system browser.

---

## 11. Game Preloading & Fresh Game State (since 0.1.3)

Goal: tapping a game tile presents an **already-rendered** game (like the warm hub), and closing a game **actually ends it**.

**The full-screen surfaces each have one warm slot** — the hub's, and since 0.5.0 the membership panel's. A slot is filled two ways: ahead of the surface's first opening, only when `prewarm` names it (§ 2.1); and by the page a presentation hands back when it closes, whatever `prewarm` names — a page that loaded, or one whose load had not ended, never a page that failed (§ 9.1). The games below are the one thing preloaded from a page rather than from the configuration: they are discovered from the hub's, so they follow `hub`.

### 11.1 Discovery

- After each completed hub load (including retries and in-place navigations), the SDK discovers the games of the current hub tab by evaluating a script against the hub document that reads the fanzone's embedded SSR payload (`__NEXT_DATA__`), in two passes: visible `Experience` tiles and `Crusher` blocks of the active tab (`fanzoneData`), in display order; then (since 0.1.4) any **direct game URL** — an absolute http(s) URL string whose path starts with `/s/` — found anywhere in the payload: hubs whose tiles are plain links (e.g. `website` buttons) reference games by direct URL, with no `Experience` component at all. Game URLs never appear in the hub DOM (tiles call `window.open` from JS), so the embedded payload is the only reliable source.
- The discovery script MUST be strictly **read-only**: no DOM mutation, no event listeners, no storage access, no behavior change. It is one of the bounded exceptions to the no-JavaScript rule (§ 12.1), which states their bounds.
- Component games replicate the web's own link construction (`{storiesOrigin}/s/{slug}?utm_source=fanzone`, § 3.1 origins: production `https://story.tl`, staging `https://staging.story.tl`, development falls back to the page origin); direct game URLs are collected verbatim — a tap would navigate to exactly that URL. All discovered URLs are augmented per § 3.3 and MUST be validated against § 4 — only URLs resolving to `OPEN_GAME_SHEET` may be preloaded (the payload scan may over-collect, e.g. `/s/` paths on foreign origins; § 4 validation is authoritative). Component games precede direct-URL finds, and duplicates of the same game keep the first occurrence, so hubs using `Experience` components keep their preload order.

### 11.2 Preloading

- Games are preloaded **sequentially** — at most one background load at a time — and never while a game sheet is presented, so preloading cannot compete with the hub or a live game.
- Per discovery, at most **12** games are loaded (bounding background data usage); the first **3** stay alive in a pool of prewarmed WebViews, the rest are released after loading (which still warms the HTTP disk cache, making their cold open fast).
- **A preload that has not finished in 30 s is abandoned**, its WebView destroyed and the queue moved on — the same path a failed load takes, and nothing is reported to the host (§ 9.1: nothing is on screen and no fan is waiting). Without a deadline one unreachable game stalls the whole sequential queue for as long as the platform's own network timeout allows, so every game behind it stays cold. Both platforms carry the figure and it is deliberately generous: this is a backstop against a stuck load, never a latency budget.
- Pool priority: the game the player closed last, then hub display order. A lower-priority pooled game is evicted when a higher-priority one finishes loading.
- Opening a game with a pooled WebView MUST present it as-is (no reload — it is fresh by construction, § 11.3). A game without one falls back to a normal load.
- Presenting a game sheet MUST release the whole pool and abandon the load in flight (since 0.2.0). A pooled WebView is detached, so the engine throttles its timers — but it keeps its page, its textures and its graphics contexts resident, and every WebView shares one content process and therefore one memory budget. Warm games would otherwise take that budget away from the game on screen, which is measurable on WebGL/3D experiences. The sheet takes its own WebView out of the pool first, so opening stays instant.
- Closing the sheet MUST rebuild the pool released above, in the § 11.2 priority order (the game just closed first). Reopening a *different* game in the seconds that follow may therefore be a cold open — deliberate: a smooth game on screen outranks an instant second open.
- All preloaded WebViews and pending loads MUST be dropped under system memory pressure, when the configuration changes, and on an identity transition (§ 7.4) — a preloaded game holds the previous fan's rendered page.

### 11.3 Fresh state on close

- Closing the game sheet MUST immediately silence and end the played game: media playback is paused at dismissal and the played WebView is discarded — its page (timers, audio, state) dies with it. Game state MUST NOT survive a close.
- After a close, the SDK re-preloads that game ahead of everything else, so reopening it is instant **and** lands on the start screen.
- Session state stored in cookies is unaffected (§ 7): a fresh load reuses that origin's persisted cookies. An identity transition is the one thing that does clear them (§ 7.4), and it flushes the pool with them.

---

## 12. Non-Goals

What the SDK does not do. A non-goal tied to a version decays into a roadmap, so this table states
what the SDK does not do, full stop; § 10 carries what changed when.

| Non-goal | Notes |
|---|---|
| Host-app session sharing | The SDK never reads or writes the host application's own session. `logout()` (§ 2.6) signs the fan out of Fastory only — it MUST NOT touch the host app's session, and signing out of the host app does not sign the fan out of Fastory |
| Verifying identity assertions | The SDK carries a `hostToken` to the API; it never validates one. Signature, audience and expiry are checked server-side, so a host MUST NOT treat a successful `identify` call as proof it minted a valid token |
| Analytics | No SDK-side tracking; only `utm_source=sdk` attribution on game URLs |
| Push notifications | — |
| OTA / remote configuration | Configuration is compile-time via `configure` |
| JS ↔ native `postMessage` bridge | **Shipped in 0.4.0 — see § 13**, reply direction included (§ 13.8): the web posts, and the web asks and is answered. Since 0.5.0 the native side may also *signal* — one constant, data-free event (§ 13.9). What stays out of scope is native pushing of **data** into a page — plus haptics and share |
| Deep links into a specific game | `openGames()` always lands on the hub |
| Tablet-specific layouts | Phones first; tablets render the phone layout |

### 12.1 No behavior-modifying JavaScript

**The SDK MUST NOT inject or evaluate behavior-modifying JavaScript in any WebView it owns.**

This is not a v0.1 limitation and not a scoping choice — it is a durable constraint, stated here
rather than as a row in the table above, which would understate it. It has two independent reasons:
a WebView container that runs script inside a third party's page assumes that page's security
responsibility, and doing so is a documented ground for rejection in store review. So the rule
outranks convenience: where a feature could be built either by injecting script or by a native
mechanism, **the native mechanism is the design**, at a higher cost if necessary. The § 13 bridge is
the worked example — both platforms expose it by native registration alone and inject nothing.

Its reply channel (§ 13.8, since 0.4.0) is the second worked example, and the sharper one, because it
delivers native → web data without touching this rule. It could only do so because it answers **on the
channel the request arrived on**: WebKit hands the handler a reply block, and Android's
`WebMessageListener` hands it a reply proxy that exists only because a page posted. Both are the
platform's own return path, so nothing is evaluated in the document. That is why the reply direction
needed no amendment here, and it is the line any exception sits on the far side of:
answering is bounded by the request, pushing is not.

The session-change signal (§ 13.9, since 0.5.0) is the one capability on the far side of that line,
and its shape is what keeps the line meaningful: the SDK speaks first, but what it evaluates is a
data-free constant — a knock, not a delivery. Everything the page then learns still travels on the
§ 13.8 reply path, answered on the channel the page's own request arrived on.

Exactly three exceptions exist, each bounded rather than general:

- **The read-only preload discovery query (§ 11.1).** It reads the hub document's embedded SSR payload
  and MUST NOT mutate the DOM, register listeners, access storage, or alter page behavior in any way.
- **The session-change signal (§ 13.9, since 0.5.0).** The SDK MAY evaluate, in a game WebView it
  owns, exactly the constant statement § 13.9 fixes — the dispatch of one named, payload-free event.
  The statement is a byte-for-byte constant: it interpolates no data, so nothing the SDK holds can
  travel by it — no token, no identifier, no state. It MUST NOT read anything back, mutate the DOM
  beyond dispatching that event, register a listener, or access storage.
- **The read-only paint query (§ 9, since 0.5.0).** While a presentation — or the hub's reload after
  an identity change (§ 7) — covers what was on its page, the SDK MAY evaluate in that page exactly the constant expression
  `performance.getEntriesByName('first-contentful-paint').length > 0` — byte-for-byte, the same on
  both platforms — and read back its one boolean. It is repeated on a native timer, at most every
  50 ms and for at most two seconds per cover, and never once the cover is down. It MUST NOT mutate
  the DOM, register a listener or a timer in the page, access storage, or carry anything in. It
  exists because neither platform has a public callback for the moment a new document has painted,
  and the native ones (`onPageCommitVisible`, `didFinish`) come before it.

A future capability that cannot be built any other way is **not** licence to widen this rule ahead of
time: it would be delivered as an amendment to this section in the same release, with the same bounded
shape — a named payload, a stated effect, no general capability. Widening the existing exception
quietly is the failure this paragraph exists to prevent.

Any other script evaluation is a spec change, not an implementation decision.

---

## 13. JS ↔ Native Bridge (since 0.4.0)

The web surfaces the SDK hosts (the hub, the membership panel and any game) MAY send the host
application typed messages through a **versioned envelope**, and MAY ask it questions the native side
answers (§ 13.8). Two properties are normative and constrain everything below:

- **Data, never at the SDK's initiative.** A message travels web → native. Data travels native → web
  **only as the answer to a request the page just made**, on the channel that request arrived on. The
  SDK pushes no data into a page unprompted, because that would mean evaluating it as script, which
  § 12.1 forbids. Since 0.5.0 the SDK may speak first in exactly one way — the **session-change
  signal** (§ 13.9), a constant, payload-free event covered by § 12.1's second bounded exception. It
  tells a page *that* the standing answer changed, never what it became: a page that wants the new
  value asks for it (§ 13.8) and is answered on its own request's channel. *"The bridge is
  receive-only"* would be the shorter wording of this rule, and it is deliberately not the one used:
  answering, signalling and pushing are different capabilities with different costs, and only the
  last one remains forbidden.
- **Additive.** The bridge MUST NOT participate in navigation. A received message MUST NOT cancel,
  delay, replace or otherwise influence the § 4 URLPolicy decision for any navigation, and a web
  surface that never posts MUST behave exactly as it did before 0.4.0 — same URLs, same five
  events, same ordering. URL interception remains the mechanism by which games open and external
  links leave; the bridge is a side channel next to it, never a substitute for it. A reply is bound by
  the same rule: answering a request MUST NOT emit a host event, open a sheet, or influence a
  navigation.

### 13.1 The envelope

Every message is a **JSON object serialised to a string**:

```json
{ "v": 1, "type": "fastory:ready", "payload": { } }
```

| Field | Type | Required | Rule |
|---|---|---|---|
| `v` | integer | yes | The envelope version. MUST equal the integer `1`. A different value, a non-integer, or a missing field ⇒ the message is ignored |
| `type` | string | yes | The message type. MUST be present in the registry (§ 13.3), else the message is ignored |
| `payload` | object | no | Type-specific data. Absent or `null` ⇒ an empty object. Present and **not** an object ⇒ the message is ignored |

Decoding rules, all normative:

- A message longer than **65 536 UTF-16 code units** MUST be ignored **before** it is parsed. The
  page is not trusted to be small, and on Android the entry point is reachable from any frame
  (§ 13.7) — an unbounded parse is an unbounded cost on a thread the host app needs. The bound is
  counted in UTF-16 code units (Kotlin `String.length`, Swift `utf16.count`) so that it is the same
  number on both platforms and O(1) on both.
- The version match MUST be **strict**: the string `"1"`, the boolean `true`, the float `1.0` and the
  number `2` MUST all be ignored. A wrongly typed version is a wrong version, never a coerced one —
  including a float that happens to equal the current version, which the two platforms' JSON parsers
  type differently and would otherwise decide differently.
- Unknown types are **ignored, not rejected** — the allow-list is what lets the web side ship a new
  message type against an already-published SDK: an older SDK drops it, and nothing breaks.
- A message that is not valid JSON, is a top-level array, or is not a string at all MUST be ignored.
- The decoder MUST NOT throw. Nothing about a malformed message may surface as an uncaught native
  exception, a crash, or an error on the host's event stream (§ 5.4 applies symmetrically).
- The envelope version is bumped only by a coordinated web + SDK release. Because unknown versions
  are ignored on both sides, a bump is a hard cut for that message, not a negotiation.

The rules above are what is normative, and they bind both platforms identically: neither may decode
an envelope the other rejects. A **request** carries
the same envelope plus one field
and is decoded by the same rules, with one deliberate difference in what a violation means — it is
answered rather than ignored (§ 13.8.2).

### 13.2 Transports

The SDK registers the receiving end on **every WebView it owns** — the hub, the game sheet, and
preloaded games. Neither platform injects any JavaScript to do it (§ 12): the entry point exists by
native registration alone.

| Platform | Native mechanism | Reached from the page as |
|---|---|---|
| iOS | `WKUserContentController.add(_:name:)` | `window.webkit.messageHandlers.fastory.postMessage(json)` |
| Android | `WebView.addJavascriptInterface(_, "fastory")` | `window.fastory.postMessage(json)` |

The two access paths differ because the platforms differ; the name (`fastory`) and the envelope do
not. Web callers SHOULD feature-detect:

```js
function postToFastory(message) {
  const json = JSON.stringify(message);
  if (window.webkit?.messageHandlers?.fastory) {
    window.webkit.messageHandlers.fastory.postMessage(json);
  } else if (window.fastory?.postMessage) {
    window.fastory.postMessage(json);
  }
  // Neither present: not running inside the SDK. Callers MUST tolerate this.
}
```

The payload MUST be posted as a **string**. On iOS a non-string body is ignored; on Android the
interface signature admits nothing else.

This is the **receive-only** channel, and it keeps this exact shape: the reply channel of § 13.8 is a
second, separately named entry point on the same WebViews. One name per direction is what makes the
receive-only channel provably untouched — a request cannot arrive here and a message cannot be answered
there.

### 13.3 Message type registry

The registry is defined by this spec, not by the host application. As of 0.5.0 it holds exactly two
types:

| `type` | Direction | Payload | Meaning |
|---|---|---|---|
| `fastory:ready` | web → native | — (reserved for future keys) | The Fastory web surface has rendered and speaks this envelope version |
| `fastory:login-requested` | web → native | — (reserved) | A fan asked to sign in; the host signs them in, then calls identify |

`fastory:ready` is a liveness signal, not a lifecycle event: the SDK's own § 5.3 events remain the
source of truth for what is open. A host MAY use it to confirm the embedded surface is alive; it
MUST NOT depend on receiving it, since the web side may be deployed at a version that never posts.

`fastory:login-requested` (since 0.5.0) is posted by a hub, a membership panel or a game when a fan
taps one of its sign-in entries, and only when the host declared `handlesLoginRequests` (§ 2.1,
§ 2.6). **It has no reply**: the host's answer is to sign the fan in its own way and call `identify`
(§ 2.6), and what the pages see of it is that identity — the presented hub reloads (§ 7), the games
are signalled (§ 13.9). It is not a request type either: sent to the reply channel, it is outside
the request registry and answered `unsupported` (§ 13.8.2), exactly as `fastory:ready` is. **The SDK
only delivers it** (§ 13.4): under the *Additive* rule of § 13 it opens no screen, starts no sign-in
and influences no navigation, so a host that ignores it changes nothing on screen — which is why
declaring the capability obliges the host to listen (§ 2.6).

Adding a type is a spec change plus a MINOR SDK release. Removing one is a breaking change.

**Request types live in their own registry (§ 13.8.3), and the two MUST be disjoint.** A type that
appeared in both would be reachable on either channel, which would let one be used to reach the
other's surface: a page could get an answer delivered as a host event, or assert an event payload by
asking for it. Every platform is held to the disjointness rather than assuming it.

### 13.4 Delivery to the host

A message that passes § 13.1 is delivered once, on the **main/platform thread**:

| Channel | Surface |
|---|---|
| iOS | `FastoryEventsDelegate.fastoryBridgeMessage(type:payload:)` — defaulted to a no-op, so a host written against the five v0.1 events keeps compiling |
| Android | `FastoryEventsListener.onBridgeMessage(type, payload)` — default no-op body |
| Flutter | `FastoryBridgeMessage(type, payload)` on `Fastory.events`; the channel event is `{"type": "bridgeMessage", "bridgeType": …, "payload": …}` (§ 5.3) |

The channel key is `bridgeType` rather than `type` because `type` is already the event
discriminator. The Dart side re-applies the registry allow-list, for the same reason the native side
re-checks `configure`: a host can drive the channel directly.

On Android the JavaScript interface is invoked on the WebView's JavaBridge thread; implementations
MUST hop to the main thread before calling the host, since both the listener and the Flutter
`EventChannel` require it.

### 13.5 Performance

A bridge round trip — decode plus delivery to the host callback — MUST average **≤ 16 ms** per
message: one frame. The three platforms are held to the same number rather than to one of their own.
Nothing on this path may block: no network call, no disk access, no synchronous work beyond the
decode.

**The same number governs a request and its reply** — decode, decide, and encode the answer — rather
than a second budget of its own: 16 ms is one frame whichever way the message is travelling, and two
constants would drift. It is also what makes the standing answer of § 13.8.2 the only workable shape:
an answer the native side had to go and fetch could not meet it.

The figure is a **coarse bound, not a measurement**: the real cost is microseconds, so it exists to
catch an order-of-magnitude regression — something blocking put on the path — and nothing finer. It
also stops at the SDK boundary: what the JS → native transport itself costs is only observable on a
real device.

### 13.6 Diagnostics

An ignored message MUST be traceable, and MUST be traced as a **debug-level diagnostic, not an
error**: a web surface can be at any deploy version, so "ignored" is a normal outcome the host never
has to handle. **Every** drop path logs a reason — body not a string, posted from a sub-frame, over
the size bound, bad JSON, version mismatch, unknown type, invalid payload — plus an excerpt of the
raw message. No silent drop: the report that needs a diagnostic most is the message that arrives on
one platform and vanishes on the other.

The same rule covers the reply channel, where it matters more, because two of its outcomes look
identical from the page: **every failed answer and every refused caller MUST be traced**, with the
`error.code` or the refusal reason and the caller's origin. A request that got no envelope at all
(§ 13.8.4) is otherwise indistinguishable from an SDK that never received it, and that is precisely the
report an investigation on a real device has to be able to resolve.

| Platform | Sink | Off by default because | Turn it on with |
|---|---|---|---|
| iOS | `os.Logger(subsystem: "io.fastory.sdk", category: "bridge")`, `.debug` | debug entries are not persisted | `log stream --level debug --predicate 'subsystem == "io.fastory.sdk"'` |
| Android | `Log.d("FastorySDK", …)`, gated on `Log.isLoggable` | the tag is not loggable at DEBUG unless enabled | `adb shell setprop log.tag.FastorySDK DEBUG` |
| Flutter | `debugPrint`, guarded by `kDebugMode` | stripped from release builds | run a debug build |

The SDK ships inside third-party applications: it MUST NOT write to the system log in a release
build by default. Raw message text MUST NOT be logged at a privacy level that a log collector would
capture — on iOS it is interpolated as `.private`; on Android and Flutter the gates above are what
keep it off a production device. Because the text comes from a web page, implementations MUST also
**flatten newlines and truncate** it before logging: an un-escaped newline in a hostile message would
forge an additional log line under the SDK's own tag.

### 13.7 Security boundary

- **The registry is the boundary.** A type outside it is dropped before anything reaches the host,
  so a page that gains the ability to post cannot make the SDK do anything the spec does not name.
- **Only SDK-owned WebViews carry the bridge.** Their **main frame** only ever loads the Fanzone
  origin or a stories origin — every other origin leaves for the system browser by rule 3 of § 4.
  Sub-frames are a different matter: § 4.2 deliberately does not intercept them, so an iframe inside
  a game may be any origin at all.
- On iOS the SDK MUST accept messages from the **main frame only** (`WKScriptMessage.frameInfo`), so
  a third-party iframe inside a game cannot speak for the Fastory surface. On the **receive-only**
  channel, Android's `addJavascriptInterface` exposes the object to every frame and reports no frame
  identity, so this gate does not exist there — a known asymmetry, bounded rather than closed. What an
  arbitrary sub-frame can therefore achieve on Android is exactly: emit a registry type with a payload
  of its choosing, up to the § 13.1 size bound, at a rate the main looper absorbs. **Do not add a
  receive-only type whose payload a sub-frame must not be able to assert until that gate exists**, and
  do not let a host branch on a bridge payload for anything security-relevant.
- **That includes `fastory:login-requested`** (since 0.5.0, § 13.3). On Android any sub-frame — an
  iframe inside a game, typically — can post it, with or without a fan's tap. It is admitted under the
  rule above because its payload asserts nothing: the worst a sub-frame achieves with it is the host
  showing its own sign-in when nobody asked — a nuisance, not an escalation. A host MUST NOT decide
  anything sensitive on this message: it may offer the fan a sign-in, never grant one, and never treat
  it as proof of who tapped.
- **The reply channel does not inherit that asymmetry, and MUST NOT** (§ 13.8.4). Its outcome is data
  the SDK hands the page rather than a claim the page makes, so the same gap would be an exfiltration
  surface instead of an assertion surface: an iframe inside a game could read the fan's token. Both
  platforms therefore gate it on frame identity **and** origin, which is why Android uses a different
  mechanism there.
- The Android `postMessage` entry point is public on the JVM because the WebView reaches it by
  reflection and Kotlin mangles the name of an `internal` member. A host calling it directly gains
  nothing: it already owns the listener the message would be delivered to.

### 13.8 The reply channel (since 0.4.0)

A web surface MAY **ask** the native side a question and receive an answer. This is a distinct channel
from § 13.2, with its own entry point, its own registry and its own decision rules — added because the
game needs it: with `embed=1` it reads no session from storage (§ 7) and asks its **host page** for the fan's
identity, and in an SDK WebView the game *is* the top-level document, so that host page does not exist.
The native side answers in its place.

What this channel is not: a way for the SDK to speak first. A reply exists only because a request
arrived, and it leaves on the channel that request arrived on — see § 12.1 for why that distinction is
load-bearing rather than cosmetic.

#### 13.8.1 Transports

The SDK registers the answering end on **every WebView it owns**, alongside the receive-only channel,
and again injects no JavaScript to do it: both mechanisms below are the platform's own, exposed by
native registration alone (§ 12.1).

| Platform | Native mechanism | Reached from the page as | Reply arrives as |
|---|---|---|---|
| iOS | `WKUserContentController.addScriptMessageHandler(_:contentWorld:name:)` (`.page` world) | `window.webkit.messageHandlers.fastoryRequest.postMessage(json)` | the resolved value of the returned promise |
| Android | `WebViewCompat.addWebMessageListener(webView, "fastoryRequest", allowedOriginRules, listener)` | `window.fastoryRequest.postMessage(json)` | a `message` event on `window.fastoryRequest` |

The name (`fastoryRequest`) and the envelope are identical on both; the way the answer comes back is
not, because the platforms differ. iOS correlates by promise, Android by the `requestId` the reply
echoes — which is why the field is mandatory on both rather than only where it is needed.

Android requires `WebViewFeature.WEB_MESSAGE_LISTENER`; a WebView too old for it simply has no reply
channel. That is a degradation, not a failure: the page's feature detection finds nothing and falls
back to whatever it does without a host, exactly as it would outside the SDK.

```js
async function askFastory(type, requestId, payload = {}) {
  const json = JSON.stringify({ v: 1, type, requestId, payload });
  if (window.webkit?.messageHandlers?.fastoryRequest) {
    return JSON.parse(await window.webkit.messageHandlers.fastoryRequest.postMessage(json));
  }
  if (window.fastoryRequest?.postMessage) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('fastory: no reply')), 1000);
      window.fastoryRequest.addEventListener('message', function onMessage(event) {
        const reply = JSON.parse(event.data);
        if (reply.requestId !== requestId) return;
        clearTimeout(timer);
        window.fastoryRequest.removeEventListener('message', onMessage);
        resolve(reply);
      });
      window.fastoryRequest.postMessage(json);
    });
  }
  return null; // Not running inside the SDK. Callers MUST tolerate this.
}
```

Web callers MUST bound their wait, as the snippet does. The SDK answers on the request path itself and
never defers, so an unanswered request means no channel — an old SDK, an old WebView, or no SDK at all —
and a caller that waits forever on that is waiting for something that is not coming.

#### 13.8.2 The request and its reply

A request is the § 13.1 envelope plus one mandatory field:

```json
{ "v": 1, "type": "fastory:user-token", "requestId": "r-1", "payload": { } }
```

| Field | Type | Required | Rule |
|---|---|---|---|
| `v` | integer | yes | As § 13.1, matched just as strictly |
| `type` | string | yes | MUST be in the **request** registry (§ 13.8.3) |
| `requestId` | string | yes | Non-blank, at most **64 UTF-16 code units**, inclusive. Echoed by the reply, so an unbounded one would let the page choose the size of the answer — and it is logged, so it is untrusted text |
| `payload` | object | no | As § 13.1 |

Every accepted request produces exactly one reply, a JSON object serialised to a string:

```json
{ "v": 1, "type": "fastory:user-token", "requestId": "r-1", "ok": true,  "payload": { "token": "…" } }
{ "v": 1, "type": "fastory:user-token", "requestId": "r-1", "ok": false, "error": { "code": "unavailable" } }
```

- `ok` is the discriminator. A successful reply carries `payload` and no `error`; a failure carries
  `error` and no `payload`.
- `requestId` MUST be echoed whenever the request carried a usable one — **including on failure**. A
  failure the page cannot attribute to a request is, from its side, a lost reply.
- `type` MUST be echoed only when it is a registry type. A request naming an unknown type gets its
  `requestId` back but not its `type`: reflecting arbitrary web-supplied text into the document buys
  nothing and is a habit worth not forming.

Failures, and there are exactly three:

| `error.code` | When |
|---|---|
| `malformed` | The envelope broke § 13.1 or the `requestId` rule above: not a string, over the size bound, not JSON, a top-level array, a wrongly typed `v`, no usable `requestId`, a non-object `payload` |
| `unsupported` | Well-formed, but the `type` is outside the request registry — typically a web surface asking an SDK older than the type it wants |
| `unavailable` | A registry type the native side has no standing answer for. Not an error state: it is what "nobody is identified yet" looks like from the page |

Normative, and the reason the list is this short:

- **A recognised caller is never met with silence.** Every request from a caller the SDK recognises
  (§ 13.8.4) MUST be answered, malformed ones included. An SDK that dropped an unparseable request
  would leave the page waiting on a reply that is not coming, which is indistinguishable from a hung
  native side. A reply the platform fails to deliver MUST be traced (§ 13.6) — that is the one case
  the SDK cannot turn into an answer, so it has to be visible in the log instead.
- **The answer MUST be produced on the request path**, with no timer, no queue and no I/O — § 13.5's
  budget applies to the round trip. This is what makes the bound structural rather than timed.
- **The answer is a standing value, set by the host** through `setBridgeReply` (§ 5.2, § 2.2–2.4), not
  resolved on demand. The game asks while it is booting, so an answer that had to be fetched would
  stall its first paint; and the native side is the one holding the credential, so it has nothing to
  fetch. Clearing the standing value MUST make the type answer `unavailable`, never fall silent.
- **Standing is not permanent.** The SDK itself drops the value at the points § 13.8.6 enumerates —
  they are normative, because a value that outlives the fan it names is a fan served to the next one.
- **A payload the platform cannot serialise MUST be refused when it is set** (§ 5.2), not when it is
  asked for. At request time there is no one left to tell.
- The decoder MUST NOT throw, exactly as in § 13.1.

The rules above bind both platforms identically: the request registry, the allowed origins, the
standing payload and the request-id length limit are shared values no platform may hold differently,
and what a reply may name is fixed by this section rather than by either implementation.

#### 13.8.3 Request type registry

Defined by this spec, not by the host application, and **disjoint from § 13.3** (see the note there).
As of 0.4.0 it holds exactly one type:

| `type` | Direction | Reply payload | Meaning |
|---|---|---|---|
| `fastory:user-token` | web → native → web | `{ "token": "…" }`, plus whatever the consumer agrees | The stories-origin fan token the game would otherwise ask its host page for |

The SDK does not interpret the payload: it carries what the host set, and the receiving web surface
verifies the token **server-side** before trusting any claim inside it. A reply is an assertion by the
native side, never a proof.

Because the registry is a security boundary, it is expressed on each platform as a **closed type**
(`FastoryBridgeRequestType`) rather than a string: a host cannot name a type outside it, and the
compiler says so. Adding a type is a spec change plus a MINOR SDK release; removing one is breaking.

#### 13.8.4 Recognised callers

**A reply MUST NOT be addressed to a caller whose origin the SDK does not recognise.** This is the one
place on the whole bridge where silence is the specified outcome, and it is not symmetric with § 13.7's
tolerance of an unidentified sender: a received message is a claim the SDK may discard, while a reply
is *data the SDK hands out*. The same gap that is an assertion surface inbound would be an
exfiltration surface outbound.

A caller is recognised when **both** hold:

- it is the **main frame** — § 4.2 does not intercept sub-frames, so an iframe inside a game may be any
  origin at all;
- its origin is one of the SDK's own: the configured environment's fanzone origin, or its stories
  origin. Exactly the two surfaces rule 3 of § 4 keeps inside a WebView. A development environment has
  no known stories origin, so its fanzone origin is the only origin recognised there.

Consequences that MUST hold:

- An unconfigured SDK recognises **nobody** and answers nothing. Fail closed: the failure mode of a
  default-allow here is answering everyone.
- An unrecognised caller receives **no envelope**. On iOS the reply handler MUST still settle — WebKit
  requires it, and an unsettled handler is a promise that never resolves — so the request is *rejected*
  rather than answered: the page sees a failed promise carrying no data.
- On Android the origin allow-list is passed to `addWebMessageListener`, so the entry point is only
  injected into matching frames and the gate is enforced by the WebView itself; implementations MUST
  **also** re-check the reported origin and frame at message time, against the *current* configuration,
  so a listener attached under an earlier configuration cannot answer under a later one.

#### 13.8.5 Non-regression

The receive-only channel of § 13.1–13.7 is unchanged, and that MUST stay assertable rather than
assumed:

- a message posted to `fastory` behaves exactly as it did in 0.3.0 — same registry, same drops, same
  single host event;
- answering a request emits **no** host event and no navigation effect (§ 13's *Additive* rule);
- a web surface that never asks anything is indistinguishable from one running against an SDK with no
  reply channel at all.

#### 13.8.6 Invalidation of the standing answer (since 0.4.0)

The standing answer is a **fan credential the SDK hands out**, so it MUST die with the identity that
justified it. "Standing" names how long a value waits to be used, never that it outlives its fan: a
channel that declared the first and left the second unsaid would let `logout()` erase the fan's
per-origin storage (§ 7.4) and drop the warm hub while the next request was still answered with that
same fan's token. The invalidation points below are therefore part of the channel's contract, not a
later hardening of it.

Since 0.5.0 the value is also **populated automatically**: a `hostToken` that resolves sets the
standing answer for `fastory:user-token` to the session it minted, so the games read the fan's token
with no `setBridgeReply` call from the host. `setBridgeReply` remains the way a host sets or clears it
by hand. Both feed the same slot, and every invalidation point below applies to it however it was set.

Implementations MUST drop every standing answer at each of these points:

| Point | Why |
|---|---|
| `logout()` | It is the one call whose entire purpose is that nothing of the fan is left. Unconditional: it MUST revoke **even when no `identify` ever resolved** — the answer may have been set by hand (`setBridgeReply`) with no identity behind it, and gating the revoke on there being one would leave that credential standing |
| An `identify` that resolves an identity **different** from one previously resolved | The § 2.6.1 difference rule, applied to this channel: a new fan MUST NOT inherit the previous one's answer. "Previously resolved" is load-bearing — see the first-identify row below |
| A `configure` that **replaces** an existing configuration with a different one | The value was minted for the environment and the workspace in force when it was set. Served under the next one, a production token reaches a staging page, and one club's fan reaches another club's game |

And MUST NOT drop it at any of these:

- **An `identify` that resolves the identity already in force.** Same fan, so the answer still
  describes them; revoking would make the idempotency of § 2.6.1 observable as a lost credential.
- **A pre-flight rejection** (`not_configured`, `identify_mode_unavailable`, a malformed token).
  § 2.6.1 already requires such a call to leave the current identity untouched; this channel is part
  of what "untouched" means, so a mode refused before anything was attempted MUST NOT sign a fan out
  here either.
- **The first `identify`,** when no identity was resolved before it. There is no previous fan for the
  answer to have belonged to, so a value the host set by hand before identifying survives into the
  session it was set for. Note that such a call *does* emit `identityResolved` (§ 2.6.2): the two
  rules read the same word differently on purpose, and an implementation MUST NOT derive one from the
  other. A `hostToken` first-identify then populates the slot with its own session, replacing that
  hand-set value with the fan it just resolved.
- **The first `configure`.** There is no previous configuration to invalidate, and a host MAY declare
  the answer before configuring — this section only requires it to be there before the game asks.

Two consequences a host has to be able to act on, so they are stated rather than left to be derived:

- **After any of the three points above, the next request is answered `unavailable`** (§ 13.8.2) —
  explicitly, never with silence. A host that wants the game identified after a `logout()` or a
  reconfiguration MUST call `setBridgeReply` again.
- **The rule is coarser than a credential's actual scope, deliberately.** Any configuration
  difference revokes, including one that changes no origin — a `theme` switch, for instance. Erring
  the other way means comparing the parts of a configuration that "matter" to a credential the SDK
  cannot read, and being wrong there is a leak; being wrong this way costs one `setBridgeReply`.

> **Not a new event.** The SDK does not announce the revocation to the **host**: all three points are
> calls the host just made, so it already knows. An event would add a `FastoryEvent` subtype —
> source-breaking on Dart (§ 2.4) — to tell a host something it caused. The **pages** are another
> matter: since 0.5.0 they learn of it through the session-change signal (§ 13.9), because no call of
> theirs preceded it.

### 13.9 The session-change signal (since 0.5.0)

The standing answer can change while a game is on screen: the § 2.6.3 renewal replaces it, a
revocation clears it (§ 13.8.6, § 2.6.3), an `identify` resolves a fan into it. A page reads its
session once, at boot (§ 13.8), so without a signal it would run a stale session to expiry — and past
that point its writes degrade silently rather than fail, which is how a fan loses the points a game
kept counting. The signal closes that gap: the SDK tells the page **that** the truth changed, and the
page re-asks.

#### 13.9.1 The statement

When the signal fires, each targeted WebView evaluates exactly this statement, byte for byte, on both
platforms:

```js
window.dispatchEvent(new Event('fastory:session-changed'))
```

This is the whole of what § 12.1's second exception licenses. The statement is constant: it carries no
payload, interpolates nothing, reads nothing back. It names a fact — the standing answer is no longer
what the page last read — and nothing else. The new value, where the caller may have it, arrives only
through the § 13.8 reply path, gated as every reply is (§ 13.8.4).

#### 13.9.2 When it fires

The signal follows the truth the standing answer describes, and fires exactly when that truth changes:

| Transition | Signal |
|---|---|
| The answer is **populated** — an `identify` resolves a fan where none or a different one stood, or the host sets it (§ 5.2) | fires |
| The answer is **replaced** by the § 2.6.3 renewal — same fan, fresh session | fires |
| The answer is **revoked** — `logout()`, an `identify` resolving a different fan (§ 13.8.6), the § 2.6.3 lifecycle revocation, or the host clearing it (§ 5.2) | fires |
| A call **re-asserts what already stands** — an `identify` resolving the identity in force, or a pre-flight rejection (§ 2.6.1) | MUST NOT fire |
| A `configure` **replaces the configuration** | MUST NOT fire — the § 2.1 teardown destroys the pages a signal would reach, and the § 13.8.6 revocation it implies is not observable by a page that no longer exists |

The same-fan row holds even where the resolution re-minted the session behind the answer: § 2.6.1
makes a same-fan `identify` observable as nothing, and this channel is part of that nothing — the
page's session stays valid for its own lifetime either way. The § 2.6.3 renewal is the deliberate
exception, because it exists precisely to replace a session that is about to stop being valid.

#### 13.9.3 Where it fires

In the **game surfaces** the SDK owns, and no others: the presented game sheet, and the preloaded game
pages of § 11.2 — a preloaded page adopted its answer at load time and will be presented later still
carrying it. Never the hub: its session does not come from the standing answer (§ 7), and a capability
§ 12.1 licenses this narrowly MUST NOT be exercised one surface wider than its reason.

#### 13.9.4 What it MUST NOT do

The § 13 *Additive* rule binds the signal as it binds a reply: dispatching it MUST NOT emit a host
event, open or close a sheet, or influence a § 4 navigation decision. It carries no delivery
guarantee: evaluation is best-effort on the transition path — non-blocking, no I/O, no retry — and a
WebView that fails to evaluate is traced (§ 13.6) and left alone. A page that never listens is
indistinguishable from one running against an SDK without the signal, and a page MUST keep its own
expiry guard for the signal that never comes — an old SDK, a throttled page, no SDK at all.

#### 13.9.5 What a page does with it

Re-request `fastory:user-token` (§ 13.8) and adopt the answer: a token means the session was renewed
or the fan changed; `unavailable` means the fan is gone, and the page falls back to its anonymous
behaviour. The reply tells the page everything the signal deliberately does not.
