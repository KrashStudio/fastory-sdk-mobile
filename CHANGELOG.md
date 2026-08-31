# Changelog

All notable changes to the Fastory Mobile SDK are documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org),
tags `sdk-vX.Y.Z`.

## 0.4.2

### Changed

- **The published documentation now addresses only you.** Wording that only meant something inside
  Fastory — issue identifiers, repository paths, build tooling — told you nothing you could act on,
  and it is gone from every file this release publishes. No public name moves and no behaviour
  changes.
- **Known limitations are still documented, in the terms you meet them in**: what you observe, what it
  costs you, the workaround when there is one, and whether a fix is planned. Only our own tracking
  references are out.
- **`QA_CHECKLIST.md` is no longer published.** It was the device-matrix sign-off sheet for our own
  release process, never a document you were meant to run, and nothing in it described SDK behaviour
  that `README.md` and `SPEC.md` do not already carry. A link to it on the default branch now answers
  404; a link pinned to `sdk-v0.4.1` or earlier still resolves.
- **The `android/` and `ios/` README files inside the plugin now say what each directory holds** — the
  SDK's native implementation, compiled into your app — instead of how those sources are maintained.

## 0.4.1

A correction release. **No public name moves and no behaviour you depend on changes** — five defects
found by consuming the published 0.4.0 packages from outside our own repository, four of which are
things we told you that were not true. Nothing here asks you to change code, with one exception
called out below: the iOS install instruction, which you should update in your own project.

### Fixed

- **Android: the SDK's R8 keep rule is now actually handed to your application.** The rule that keeps
  the bridge's JavaScript entry point alive under shrinking has shipped with the Android module since
  the bridge did — but no Gradle file declared `consumerProguardFiles`, which is the only thing that
  passes a library's rule to the app consuming it, so R8 never read ours. **Nothing broke, and it
  matters that you know why:** Flutter's Gradle plugin adds AGP's default rule file to every shrinking
  release build, and that file carries an equivalent rule, so the bridge survived whatever your own R8
  configuration said. If you read the FAQ's *Do we need ProGuard / R8 rules?* and wrote no keep rule
  of your own, you were protected by your build chain rather than by us. You are now protected by us,
  which is what that FAQ answer has always claimed. Nothing to change on your side.
- **iOS: the install instructions now pin up to the next *minor*, and you should follow them again.**
  They previously told you to pick *Up to Next Major Version*, or `from:` in your `Package.swift`.
  Both mean `>= 0.4.0, < 1.0.0`: Swift Package Manager gives a leading zero no special meaning, unlike
  the caret in some other ecosystems, so that range spans every future 0.x minor. This SDK ships
  source breaks in minors while it is on 0.x — *Upgrading from 0.3.0* in the README lists three —
  which made the recommended range one a future release could stop compiling in, without you asking
  for it. **Change your dependency to *Up to Next Minor Version*, or `.upToNextMinor(from:)` in your
  manifest.** If you want the Swift channel to be as immovable as the Flutter one, which pins a tag,
  use SwiftPM's `exact:` requirement instead. The demo project we ship as "resolve it exactly as an
  integrator does" carried the old range too, and now carries the new one.
- **The README now says what `configure()` does with a configuration it refuses, on each channel.**
  It said nothing at all, while its configuration table claimed `configure` *throws* when
  `developmentBaseUrl` is missing in development — which describes the Flutter channel and cannot
  describe the Swift one, where neither the initializers nor `configure(_:)` are declared to throw.
  The behaviour is unchanged and deliberate; only the silence about it is fixed. On Flutter,
  `configure()` throws a catchable `ArgumentError` before it reaches the platform channel. On native
  iOS, `configure(_:)` cannot throw: a **debug** build trips an assertion and terminates, and a
  release build returns having changed nothing. A Swift host that would rather handle it calls
  `try config.validate()` first. **The same section also states what a refusal is not**: it is not a
  rollback. The configuration already in force keeps applying on both channels, so only a host whose
  *first* `configure()` is refused ends up unconfigured — refuse a later one and `openGames()` opens
  the previous fanzone as though nothing had happened. The README's new *When `configure()` refuses
  your configuration* carries both channels side by side, because the mistake this catches — a
  publishable key and an environment that disagree — is exactly the one the staging-to-production
  move makes easy.
- **Flutter: a refused publishable key no longer appears in the exception message.** `configure()`
  still throws `ArgumentError` for the same reasons; the message now names the rule that was broken
  and the environment expected, instead of quoting your key at the end of the sentence. Logging a
  failed `configure()` is the ordinary thing to do, and it was sending the key to your crash reporter
  and your log aggregator for no purpose. A publishable key is not a credential — `SPEC.md` § 2.5 —
  so nothing was exposed by this; the value was simply useless in a third party's logs, and the Swift
  guard never did it. **If you match on the message text of this exception, it has changed** — and so
  have its `name` and `invalidValue` properties, which are now null for this one field, because
  `invalidValue` is where the key used to sit. The `ArgumentError` type itself, and every
  configuration this refuses, are unchanged. The other fields `configure()` refuses — a blank
  `fanzoneSlug` or `hubTabSlug` — still carry the offending value, deliberately: they are identifiers
  you chose, and seeing which one was blank is the point.
- **`SPEC.md` no longer points you at files this repository does not contain.** Four of its lines
  named files you have no way to open, and one of them made such a file *the* authority — § 9.1 told
  you to treat any unlisted failure `code` as a defect to report, and then said the closed list was
  that file. **The table in § 9.1 is the closed list**, and it always held the same values; a
  specification you hold now says so itself.

## 0.4.0

Everything specified since 0.3.0, released at once: a message bridge between your app and the web
content the SDK hosts, the identity surface, the bridge's reply channel, a surface that fails to load
now telling your app so, and four defects a pre-release audit found. Plus one removal,
`workspaceId`.

It arrives as one upgrade, but it is five separate capabilities and they break in different places —
so each has its own section below, in that order, and the three source breaks are listed first.
**Read `Breaking` and you are done**: nothing else here asks anything of you.

### Breaking

- **Dart: `FastoryEvent` gains three subtypes.** It is a `sealed` class, so an exhaustive `switch` with
  no `default:` stops compiling until you add a case for **all three** — `FastoryBridgeMessage` (the
  bridge), `FastoryIdentityResolved` (the identity surface) and `FastorySurfaceLoadFailed` (a hub or
  game that did not load). The analyzer points at each. Deliberate, under SemVer § 4 (anything may
  change in a `0.y.z` line), and the last such break planned before 1.0. The two native channels are
  purely additive: each new callback is defaulted to a no-op, so an existing delegate or listener
  keeps compiling untouched.
- **Android: the reply channel adds a dependency and a WebView floor.** The SDK now depends on
  `androidx.webkit`, because the reply channel needs the one Android API that reports which frame
  posted a message and from which origin — `addJavascriptInterface`, which the receive-only channel
  uses, reports neither. A reply carries a credential, so answering the wrong frame is not an
  acceptable failure: an `<iframe>` inside a game must not be able to read it. On a device whose
  WebView predates that API (Chrome 85, mid-2020) **the reply channel is simply absent** and the
  surface falls back to anonymous — everything else works as before.
- **`workspaceId` is gone from `FastoryConfig`**, on all three platforms. If you pass it, delete the
  argument; there is nothing to replace it with, and nothing it protected is now unprotected. It was
  an optional cross-check against the workspace your publishable key resolves to — but a key resolves
  exactly one workspace, so it was asking you to confirm something the key already settles. What
  actually stops a key opening a workspace it does not belong to is the exchange being bound to your
  application identifier, which the API refuses unless the owning workspace declared it on that key
  (`sdk_application_not_allowed`). That refusal is unconditional and happens on the side that holds
  the truth; the field was an opt-in copy of it, and could only ever be weaker.

### Added — the JS ↔ native bridge

The web content the SDK hosts can talk to your app, through a versioned message envelope.

- A Fastory web surface (the hub, or a game) can post `{"v": 1, "type": "…", "payload": {…}}` and your
  app receives it as a **sixth event**: `FastoryBridgeMessage` on `Fastory.events` (Flutter),
  `onBridgeMessage` (Android), `fastoryBridgeMessage(type:payload:)` (iOS). The callback is a no-op by
  default on every platform, so upgrading without touching your call site changes nothing.
- **Additive, and no part of navigation.** The hub, the games and the external-link routing behave
  exactly as they did in 0.3.0 whether or not the web side posts anything.
- **Versioned, with an allow-list.** Anything that is not envelope version `1` carrying a type the SDK
  knows is silently ignored — so a later web release can introduce a message type without breaking an
  app already in the stores. Malformed input never throws.
- **One type today:** `fastory:ready`, a liveness signal meaning the embedded Fastory surface has
  rendered and speaks this envelope. Do not depend on receiving it.
- **No JavaScript is injected.** The entry point exists by native registration alone
  (`window.webkit.messageHandlers.fastory` on iOS, `window.fastory` on Android).
- **Bounded input.** A message over 65 536 characters is refused before it is parsed, and every drop
  is traced at debug level with its reason (see `SPEC.md` § 13.6 for how to turn the diagnostics on —
  they are off in release builds, as an SDK inside your app should be).
- Full contract in `SPEC.md` § 13. It carries a ≤ 16 ms budget for decode plus delivery; treat that as
  a regression tripwire rather than a latency figure, since the real cost is microseconds.

### Added — the identity surface

Tell the SDK who the fan is: one `identify` method with three modes, plus `logout`. Only the anonymous
mode resolves in this release; the other two are the final signatures, reserved.

- **`Fastory.identify(...)` and `Fastory.logout()`** — the whole identity surface, and it is now
  frozen: three mutually-exclusive modes behind one method. `anonymous` is what the SDK has always
  done (each surface's web page mints its own device visitor) and it is the only one that resolves
  today. `fanId` (a Fastory login through the system browser) and `hostToken(jwt)` (your backend
  asserts an identity it already authenticated, so the fan types nothing) ship in later releases and
  reject with `identify_mode_unavailable` until then. They are declared now on purpose: adopting them
  later must not be a breaking change for you.
- **`identityResolved`** — emitted once per successful `identify`, before any hub or game opening
  carrying that identity, so you never attribute a session to the wrong fan. A refused identification
  emits nothing; its error comes back from the call.
- **Calling `identify(anonymous)` twice gives you the same fan.** Repeated calls — across app launches,
  or defensively before every `openGames()` — are a no-op, not a new visitor each time.
- **An app that never calls `identify` behaves exactly as it did in 0.3.0**, and an app that starts
  calling `identify(anonymous)` keeps the visitor it already had. Nothing about the hub, the games or
  the URLs moves.
- **`logout()` signs the fan out of Fastory only.** It clears the Fastory session on the fanzone and
  story domains and nothing else: your own session, your own cookies and your own web storage are
  never touched. Symmetrically, signing a user out of your app does not sign them out of Fastory —
  call `logout()` for that.
- **The documented promise that the hub and the game share a session was wrong, and is withdrawn.**
  `SPEC.md` § 7 said the two WebViews shared a cookie store *"so the game inherits any session state
  established in the hub"*. They cannot: the hub and the game are different sites, and the game (which
  loads with `embed=1`) reads no storage at all. If you read that paragraph as "games already know who
  the fan is", they do not — that is what the identity work is for. § 7 now describes what actually
  happens, and § 7.4 specifies what a sign-out erases.
- **The shared `WKProcessPool` is gone on iOS.** Deprecated since iOS 15 and documented by Apple as
  having no effect, so it produced a deprecation warning and nothing else. WebKit decides process
  sharing on its own at the SDK's iOS 15 floor. No behavior change; one less warning in your build.

### Added — the bridge's reply channel

The web can ask the SDK a question and get an answer. One method for you, `setBridgeReply` — and the
first thing it unlocks is a game knowing who the fan is.

- **`Fastory.setBridgeReply(type, payload)`** — declares what the SDK answers the next time an
  embedded surface asks for something. Today there is exactly one thing it can be asked
  (`FastoryBridgeRequestType.userToken`), and it exists because a game has no way to know the fan on
  its own: when it runs inside a page it asks that page, and inside the SDK there is no page to ask.
  Set the answer before opening a game and the SDK stands in for the missing host.
- **A request always gets a reply.** If you have set nothing, if the surface asks for something this
  SDK version does not know, or if the message is malformed, the page is told so explicitly — it is
  never left waiting. That is deliberate: silence is indistinguishable from a hung SDK.
- **The bridge is registered on every SDK WebView** — hub, game sheet and preloaded games — and still
  injects no JavaScript into your users' pages. The answer travels back on the channel the question
  arrived on, which is the platform's own return path.
- **"The bridge is receive-only" is not the right description of it.** The SDK never speaks to a page
  first, but it does answer one that asks. Pushing data into a page unprompted remains out of scope.
- An app that never calls `setBridgeReply` is unaffected by this capability.

### Added — a surface that does not load now tells your app

Until this release, a Fastory surface that failed to load showed the fan an error screen that does not
belong to your app, and told your app nothing at all. You could not log it, alert your team, or offer
the fan something else.

- **`FastorySurfaceLoadFailed`** on `Fastory.events` — `onSurfaceLoadFailed` on Android,
  `fastorySurfaceLoadFailed(_:)` on iOS. It carries which surface failed (`FastorySurface.hub` or
  `FastorySurface.game`), a `FastoryLoadFailureReason`, and the cause: the API's own `code` when the
  refusal came from your publishable key, the HTTP `statusCode` when it came from the page itself.
- **Branch on the reason, read the cause.** `FastoryLoadFailureReason.rejected` means something
  answered and refused — `code` or `statusCode` says what. `network` means nothing answered: no
  connection, DNS, timeout. `unknown` is everything else. Three cases, so a simple "is Fastory
  reachable?" check does not have to enumerate every code we may add later.
- **A revoked key is now distinguishable from a phone in a tunnel.** They were not: a revoked key, an
  application identifier your workspace never declared, and no network produced one identical screen
  and one identical silence. The API had been answering `sdk_key_unknown`, `sdk_key_revoked`,
  `sdk_application_not_allowed` and `sdk_rate_limited` all along; the SDK was discarding them. Read
  `sdk_rate_limited` as a signal to back off, not to retry: repeated sanctions escalate to an
  address block with no expiry that only we can lift. With
  the two the SDK mints itself — `http_<status>` and `sdk_application_id_required` — that is six
  things `code` can carry and no others: five names, plus the `http_<status>` family for a refusal
  that named no code of its own. Cover those and you have covered the field. `sdk_key_unknown`
  is the one worth reading twice: it means we know no such key, which covers a key **deleted** in the
  back-office and a workspace that no longer exists, not only a typo in a build you never shipped. An
  app already in the field can meet it.
- **The game sheet now has an error view too**, with Retry — a game that failed to load used to be a
  black sheet. The hub has had one since 0.1.
- **An opening event no longer fires on a surface that failed.** `hubOpened` used to go out while the
  screen showed the error view, so an app counting it counted hubs that never loaded. It now announces
  a surface whose page actually loaded — and a surface that never opened sends no closing event
  either, so `hubOpened` … `hubClosed` still pair up. A hub that was pre-warmed still announces itself
  the instant it appears; nothing about the fast path changed.
- **Nothing is retried for you, and nothing is reported twice.** The SDK reports; you decide. A single
  failed load produces exactly one event, cancellations the SDK causes itself when routing a game or
  an external link produce none, and a failed image or XHR inside a page produces none.
- **Known limitation: Retry does not recover a refused publishable key**, and a fix is planned. The
  Retry button reloads the page that failed, and a key the API refused never produced one — the exchange's
  outcome is remembered for the configuration that asked for it, failure included, so Retry shows the
  same error again without asking the API a second time. The fan cannot retry their way out of it.
  What does re-arm the exchange is another `configure()`: **any second call, on both platforms**, with
  the configuration already in force or a new one — you do not have to vary it. If your app wants to
  recover from a transient failure of the exchange — a fan who opened the games in a tunnel — do it
  there, on `FastorySurfaceLoadFailed(surface: hub)`, rather than expecting the button to — and do
  not count on the very next open: on Android an equal `configure()` leaves the previous failure
  readable until the new exchange answers, so an open that starts inside that window is answered
  from it and the recovery lands on the one after. Pages
  that failed on their own, and the whole deprecated `fanzoneSlug` path, reload on Retry exactly as
  before.

### Fixed — four defects the pre-release audit found

One of them lets an identity outlive the fan it names.

- **`logout()` revokes the answer the SDK gives your games.** The value set through `setBridgeReply`
  had no end: signing a fan out erased their web session and dropped the warm hub, and the next game
  that asked for the fan's token was still handed the one you set for the fan who just left. The same
  value also survived a reconfiguration, so a token minted for production could be served to a staging
  page. It is dropped at three points — `logout()`, an `identify()` that resolves a *different* fan,
  and a `configure()` that replaces the configuration with a different one — and the next request is
  answered `unavailable` explicitly, never with silence.
  - **What you have to do:** if your app sets a standing answer, set it again after any of those three
    calls. The SDK does not announce the revocation, because all three are calls you just made.
  - **The rule is deliberately coarse on `configure()`:** *any* difference revokes, a `theme` switch
    included. Guessing which parts of a configuration a credential depends on would mean reading the
    credential, and being wrong in that direction is a leak.
  - `SPEC.md` § 13.8.6 is normative; § 2.6.1 and § 7.4 point at it. The three demo consoles show the
    revocation on screen when it happens.
- **Android: opening the games twice in a row no longer stacks two hubs.** `openGames()` was not
  idempotent on this platform, and the hub `Activity` declared no launch mode — so a double tap on
  your own "Games" tab, the most ordinary gesture there is, opened a second hub over the first. Your
  app then received two `hubOpened` for one hub the fan could see, `close()` returned them to the hub
  underneath instead of to your app, and the page the hidden hub kept warm on its way out overwrote
  the other one without releasing it, leaking a WebView per stack. Asking for the games while a hub is
  up now does nothing at all, exactly as it always has on iOS.
  - **Nothing to change on your side**, and nothing new to catch: it is a silent no-op, not an error.
    If you were counting `hubOpened` to drive your own UI, the count is now the one you expected.
  - **A `close()` issued in the instant between `openGames()` and the hub appearing is honoured too** —
    the hub finishes on arrival rather than showing up after you asked for it to be gone.
  - `SPEC.md` § 2.1 states the rule for both platforms and § 2.3 the Android launch mode that backs it.
- **iOS: re-configuring no longer opens the previous configuration's fanzone.** A second `configure()`
  with a different configuration replaced the configuration but kept the hub page already warmed for
  the old one, so the next `openGames()` showed the wrong fanzone — a multi-club app opened the wrong
  club, a staging switch opened production. It escaped notice because the teardown sat behind the
  warm-up, which does nothing at all when the SDK is configured by key: the fanzone to open is not
  known until the API answers. So the path that never cleaned up was the publishable-key path — every
  new partner, and the whole slug → key migration. Android already behaved correctly; `SPEC.md` § 2.1
  now states the rule for both, including that re-configuring with an *equal* configuration must keep
  the warm hub.
  - **A warm hub is only reused for the configuration its page was loaded under**, on both platforms.
    Dropping it at `configure()` time is not enough on its own: the hub is put back into the warm slot
    when it is closed, so closing it *after* a re-configure returned the previous club's page to the
    slot the teardown had just emptied. The same stamp applies to a cached publishable-key exchange, so
    a workspace resolved for one configuration can no longer answer for another.
  - **An equal `configure()` no longer costs you a cold hub open on iOS.** Warming up did not check
    whether anything was already warm, so a re-configure with the same configuration flushed every
    preloaded game and replaced the rendered page with one still loading. Android always had that
    guard. `SPEC.md` § 2.1 now binds the warm-up path as explicitly as the teardown.
- **`configure()` can be called from any thread, and no longer competes with your first screen.** It
  did the most thread-restricted work of the whole surface — allocating a WebView, loading it, stopping
  the loads in flight — and, unlike `identify()` and `logout()`, it did that work on whichever thread
  you called it on. Nothing in the contract said the main thread was required, so initialising the SDK
  from a background bootstrap crashed the host app at launch. It now stores your configuration on your
  thread and schedules the restricted work itself.
  - **The hub is warmed once your app is on screen, not during `configure()`.** Building the hub
    WebView at `configure()` put the SDK in competition with your app's first paint — every launch, for
    every integration on the deprecated `fanzoneSlug` path, which is every production integrator. It is
    deferred to the first frame, and a background launch warms nothing at all. Opening the hub is
    unchanged: this is a deferral, not a removal.
  - **`SPEC.md` § 2.7 is new** and states which thread each method may be called from. One method still
    requires the main thread — `openGames()` — because it takes your own `UIViewController` / `Context`,
    so you are already in UI code when you call it. Everything else is callable from anywhere, and every
    callback still arrives on the main thread as before.

### Fixed — elsewhere

- **`hubOpened` was missing on iOS whenever the hub had been pre-warmed** — which, configured by
  `fanzoneSlug`, is every opening that goes well. The event carries the slug of the fanzone being
  opened, and the SDK only looked that slug up on the path it skips when the page is already loaded, so
  the better the warm-up worked the more reliably the event went missing. It now fires on every
  presentation whose page loaded, warmed or not, and `hubOpened` … `hubClosed` pair up again — a hub
  that fails to load sends `FastorySurfaceLoadFailed` and neither of the pair (see *a surface that
  does not load* above). Android and Flutter on Android were never affected by the missing event.
- **The two Android Gradle files can no longer drift apart.** The core and the Flutter plugin each
  declare their own dependencies, and nothing compared them — a library added to one would have failed
  to compile only on the other channel, at release time. A release check now fails on the difference.

### Notes

- **Erasure is scoped, by name and by origin, never wholesale.** On both platforms the cookie and
  web-storage stores are shared with your app, so the SDK expires a declared list of Fastory cookies on
  the Fastory origins rather than calling any "clear everything" API. That is a hard rule, not a
  precaution: the convenient call would sign your users out of your own services.
- An identity change also drops the warm hub and the preloaded games — they were rendered for the
  previous fan. Expect the next `openGames()` after a `logout()` to be a cold open.
- `identify` never blocks and never throws across the bridge. Every failure carries a machine-readable
  code (`identify_mode_unavailable`, `invalid_host_token`, `not_configured`, …) and leaves the SDK in a
  clean anonymous state — never half-identified. Branch on the code, never on the message.

## 0.3.0

Configure the SDK with a workspace publishable key instead of a fanzone slug, and tell the web
surfaces which appearance to render in.

### Added

- **`configure` by publishable key** — create one in the workspace settings and pass it as
  `publishableKey`; the SDK exchanges it for the fanzone to open. Pass `workspaceId` too and a key
  belonging to a different workspace is rejected instead of silently opening someone else's
  fanzone. A malformed key, a bare prefix, or a key minted for another environment fails **at
  configure time**, with a typed error — not later at the first network call.
- **`theme`** — `light` or `dark`, forwarded to the hub and game URLs alongside the existing
  `locale`. The web side does not read it yet, so setting it is inert until it ships there. Neither
  value ever overwrites one the fanzone already put on its own game links.

### Deprecated

- **`fanzoneSlug`** — still accepted, and still behaving exactly as in 0.1, for the whole 0.x line.
  Upgrading without touching your call site does not break: nothing becomes a compile error before
  1.0. Each platform flags it the way its language allows.

### Notes

- **The key exchange is served on staging, not yet on production.** `environment: staging` with an
  `fpk_test_…` key works today; an `fpk_live_…` key against production resolves nothing until the
  endpoint deploys there, and `openGames()` shows the hub's error view. Production integrations stay
  on the deprecated `fanzoneSlug` until then — that path calls no endpoint and is unchanged by this
  release.
- Configured by key, the hub cannot be warmed up before the exchange resolves — there is no URL to
  warm yet. The hub's existing loading state covers the round trip, and a rejected key lands on the
  existing native error view rather than a blank web view.
- Errors carry the API's machine-readable code (`sdk_key_revoked`, `sdk_application_not_allowed`,
  `sdk_rate_limited`, …). Branch on the code, never on the message.
- The key only bootstraps for the application identifiers declared on it — your iOS bundle
  identifier and Android package name. Create the key with them, or every call is refused.

## 0.2.0

Native iOS apps can now consume the SDK as a Swift package, and heavy games get the whole device
budget while they are on screen.

### Added

- **Swift package (SwiftPM)** — native iOS apps no longer need Flutter to embed the SDK. Add
  `https://github.com/KrashStudio/fastory-sdk-mobile` in Xcode, or `from: "0.2.0"` in your own
  `Package.swift`, and call `Fastory.configure(_:)` then `Fastory.openGames(from:)`. The Flutter
  plugin is unchanged and keeps its own install path. Every release now publishes both channels
  from the same commit: `sdk-vX.Y.Z` for Flutter, the bare `X.Y.Z` tag that SwiftPM resolves.

### Fixed

- **Heavy games no longer share the device with the games waiting behind them** — up to three
  preloaded games stayed fully resident while another was being played. Set aside, their timers
  are throttled, but they keep their page, their textures and their graphics contexts, and every
  web view shares one content process and therefore one memory budget. Presenting a game now
  releases the others and abandons the preload in flight; closing rebuilds them, the game just
  closed first. Opening from the hub stays instant. Reopening a *different* game in the seconds
  after a close may be a cold open — deliberate: a smooth game on screen comes first.
- **Games served from the staging environment open in the game sheet again** — the SDK expected a
  host the platform does not serve there, so a staging game was treated as an external link and
  handed to the system browser, losing the cookies shared with the hub and the `gameOpened` event.
  Production was never affected.

### Changed

- The package no longer ships its test suite. Nothing an integrator consumes changes.

## 0.1.4

Game preloading now also finds games referenced by direct link, not only by game components.

### Fixed

- **Games referenced by direct URL are preloaded again** — on hubs whose tiles are plain links
  (a button pointing straight at the game's `/s/…` URL) instead of game components, discovery
  found nothing, so no game was preloaded and every tap fell back to a cold load. Discovery now
  also collects direct game URLs from the hub page's embedded data (same read-only query, page
  behavior still never modified), so those hubs get warm, instant game opens too. Tiles linking
  to anything other than a game are unaffected: they still follow the URL policy and are never
  preloaded. (Spec §11.1, spec version 0.1.4.)

## 0.1.3

Games open instantly (hub-driven preloading) and closing a game now truly stops it.

### Changed

- **Closing a game actually ends it** — dismissing the game sheet pauses media playback right away
  and discards the played WebView: audio stops instantly and no game state survives the close.
  Previously the played page was kept and reloaded best-effort in the background, so a slow or
  failed reload could resurface the game mid-session, sometimes still playing sound.
- **Games are preloaded from the hub** — once the hub has loaded, the SDK discovers the games of
  the hub tab (read-only query of the page's embedded data; the page's behavior is never modified)
  and warms them one at a time in background WebViews: up to 12 games are fetched (warming the
  HTTP cache for all of them) and the first 3 stay alive, so tapping a tile presents an
  already-rendered game. A closed game is re-warmed first, ahead of untouched games. Preloading
  never runs while a game is being played, and everything is dropped under memory pressure.
  (Spec §11, spec version 0.1.3.)

## 0.1.2

Reopening a game now starts fresh, and `configure()` is safe to call straight from `main()`.

### Changed

- The default `hubTabSlug` is now **`games`** (was `games-app`), matching the Fanzone hub tab
  convention. Hosts passing an explicit `hubTabSlug` are unaffected.
- **Games restart on reopen** — closing the game sheet reloads the game in the background in the
  retained WebView. Reopening the same game is still instant, but the player lands on the start
  screen instead of back in the middle of a session. Visitor session and consent are preserved (the
  reload reuses the shared cookie store); media autoplay stays gesture-gated, so nothing plays while
  the reload happens off-screen.

### Fixed

- `configure()` now calls `WidgetsFlutterBinding.ensureInitialized()` itself. Calling `configure()`
  from `main()` before `runApp()` previously failed silently (unawaited platform-channel call), and
  every later `openGames()` rejected with `not_configured`.

## 0.1.1

Faster opens (warm hub and game WebViews), stories-domain game links, and a corrected consent hint.

### Changed

- **Instant hub** — the hub WebView is created and loaded as soon as `configure()` is called, and
  kept warm across sessions: `openGames()` presents an already-rendered page instead of reloading
  every time, with the scroll position preserved.
- **Warm game sheet** — the game WebView is retained across opens: reopening the same game is
  instant with its state preserved; opening another game reuses the warm webview and renderer
  process. The game WebView is only ever created when the first game sheet opens, never
  preemptively.
- Warm WebViews are dropped when the configuration changes and under system memory pressure.
- **Consent hint is now `consent=0`** on both the hub and game URLs (was `consent=1` on the hub in
  0.1.0). The web still suppresses its cookie banner, but the SDK no longer asserts analytics
  consent the host app never collected. (Spec §3.2/§3.3.)

### Added

- Game links served from the Fastory stories domains (`https://story.tl`, `https://test.story.tl`)
  with an `/s/` path now open in the game sheet; any other stories-domain path still opens in the
  system browser. (Spec §4.)
- Game URLs now carry the `consent` hint like the hub, so the story player no longer shows its own
  cookie banner inside the game sheet.
- The `hubOpened` event now carries the `fanzoneSlug` (`FastoryHubOpened(fanzoneSlug)` /
  `fastoryHubOpened(fanzoneSlug:)` / `onHubOpened(fanzoneSlug)`), mirroring how `gameOpened` carries
  the game slug. (Spec §5.3, spec version 0.1.1.)

## 0.1.0

Initial release — the "ultra-light" SDK: a native WebView container with a strict URL-interception
policy. No authentication, no analytics, no JavaScript injection.

### Added

- **Flutter plugin `fastory_sdk`** — public API: `Fastory.configure(FastoryConfig)`,
  `Fastory.openGames()`, `Fastory.close()`, plus a broadcast `Fastory.events` stream emitting
  `FastoryHubOpened`, `FastoryHubClosed`, `FastoryGameOpened(slug)`, `FastoryGameClosed`,
  `FastoryExternalLink(url)`.
- **Games hub (WebView A)** — full-screen native view loading the Fanzone's hidden games tab
  chromeless (`?tab=…&chrome=0&consent=1`), edge-to-edge with a native close button; native
  loading indicator and an error view with retry on load failure (offline, DNS, HTTP ≥ 400).
- **Game sheet (WebView B)** — native bottom sheet opening any Fanzone game (`/s/{slug}`), URL
  augmented with `embed=1&utm_source=sdk`; edge-to-edge, dismissible by swipe (iOS) or back
  (Android); in-place game-to-game navigation with correct `gameClosed`/`gameOpened` bracketing.
- **URL interception policy** — every navigation (including `window.open`) is decided natively:
  same-origin `/s/` → game sheet; same-origin → in place; any other origin or non-http(s) scheme →
  system browser with an `externalLink` event.
- **Shared session** — both WebViews share cookies and web storage (single `WKProcessPool` +
  `WKWebsiteDataStore.default()` on iOS, global `CookieManager` on Android), so consent and visitor
  session survive between the hub and the games and across app restarts.
- **Android back handling** — back closes the sheet first, then navigates the hub history, then
  closes the hub.
- **Environments** — `production` (`fanzone.me`), `staging` (`staging.fanzone.me`) and
  `development` (integrator-provided base URL). Config defaults: `production`, hub tab `games-app`.
- **Example app** — Flutter demo reproducing the pilot integration flow (bottom bar, Games entry).
- Platform floor: iOS 15.0, Android `minSdk 24`, Flutter ≥ 3.10 (Dart ≥ 3.0).
