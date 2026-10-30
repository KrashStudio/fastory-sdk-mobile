# Fastory Mobile SDK

Context for AI assistants working in this repository.

## What this repository is

The **release distribution** of the Fastory Mobile SDK — a thin native WebView container that embeds
the Fastory Fanzone games experience inside a host mobile app. Each release is a curated snapshot
tagged `sdk-vX.Y.Z` (SemVer; the tag always matches the Flutter plugin's `pubspec.yaml` version).

You consume this repository **read-only**: pin a release tag, and take a fix by moving that pin to a
newer one. It accepts no pull requests — report anything you find to your Fastory contact instead,
and a correction reaches you as a new tag.

## Layout

```
README.md              # the integration guide — start here
SPEC.md                # normative contract: public API, URL rules, events, platform channels
CHANGELOG.md           # release notes, one entry per version; read `Breaking` on an upgrade
CLAUDE.md              # this file
flutter/fastory_sdk/   # the Flutter plugin (Dart API + bundled iOS/Android native code)
Package.swift          # the native Swift channel (SwiftPM) — since 0.2.0
Sources/FastorySDK/    # the Swift core that package compiles
```

**Two channels, one repository, one version.** The Flutter plugin and the Swift package ship from the
same commit, so `flutter/fastory_sdk/` and `Sources/FastorySDK/` are the same behaviour reached two
ways — the plugin bundles the same core under `flutter/fastory_sdk/ios/Classes/`. Each
release carries **two tags** on that commit: `sdk-vX.Y.Z` for Flutter, and the bare `X.Y.Z`, which is
the only form SwiftPM resolves. `Package.swift` sits at the root because SwiftPM cannot resolve a
package held in a subdirectory; `flutter/` falls outside every declared target path, so the two never
see each other.

## Integrating

Add the plugin as a git dependency pinned to a release tag:

```yaml
dependencies:
  fastory_sdk:
    git:
      url: https://github.com/KrashStudio/fastory-sdk-mobile
      path: flutter/fastory_sdk
      ref: sdk-v0.5.0
```

Public API surface (normative in `SPEC.md §2`): **8 methods** — `Fastory.configure(FastoryConfig)`,
`Fastory.openGames()`, since 0.5.0 `Fastory.openMembership({String? sequenceId})`,
`Fastory.close()`, since 0.4.0 `Fastory.identify(FastoryIdentity)` +
`Fastory.logout()`, since 0.4.0 `Fastory.setBridgeReply(type, payload)`, and since 0.5.0
`Fastory.setHostTokenProvider(provider)` — and **11 events** on
`Fastory.events` (`FastoryHubOpened`, `FastoryHubClosed`, since 0.5.0 `FastoryMembershipOpened` and
`FastoryMembershipClosed`, `FastoryGameOpened(slug)`,
`FastoryGameClosed`, `FastoryExternalLink(url)`, since 0.4.0 `FastoryBridgeMessage(type, payload)`,
`FastoryIdentityResolved(mode, fanId)`,
`FastorySurfaceLoadFailed(surface, reason, code, statusCode)` and since 0.5.0
`FastoryIdentityRevoked(reason, code)`).
An opening event announces a surface whose page loaded: a hub or game that failed emits
`FastorySurfaceLoadFailed` and no opening — and therefore no closing — event (`SPEC.md` § 9.1).
Minimum platforms: iOS 15.0, Android `minSdk 24`, Flutter ≥ 3.10 (Dart ≥ 3.0).

**Upgrading from 0.3.0 to 0.4.x costs a host exactly three things** (`SPEC.md` § 10, `CHANGELOG.md`
→ `Breaking`), and **0.5.0 costs three more** — listed after them. Name all of them when advising an
upgrade, and always ask which version the host is on first: the two lists break in different places,
and only the 0.5.0 one reaches a native host. Of the three below, the first is the only one an
analyzer reports, so the other two are the ones a host discovers at runtime or in review:

1. **Dart's `FastoryEvent` gains three subtypes at once** — `FastoryBridgeMessage`,
   `FastoryIdentityResolved`, `FastorySurfaceLoadFailed`. It is `sealed`, so an exhaustive `switch`
   with no `default:` stops compiling until all three cases exist. Three cases at once, not one per
   release. The two native API surfaces are unaffected *by this break*: every new callback is
   defaulted to a no-op. Do not carry that sentence over to 0.5.0, where one of the three does reach
   them.
2. **Android gains an `androidx.webkit` dependency and a WebView floor of Chrome 85** (mid-2020), for
   the reply channel only (`SPEC.md` § 13.8). Below it the reply channel is absent and the surface
   stays anonymous; nothing else about the SDK changes and there is no host code to write.
3. **`workspaceId` is removed from `FastoryConfig`** and from the `configure` channel payload. A host
   passing it **deletes the argument** — this is the only break that asks for a deletion rather than
   an addition, and the only one with nothing to replace it. Do not offer a substitute: a key resolves
   exactly one workspace, and what refuses a key used by an application its workspace never declared
   is the API, unconditionally (`sdk_application_not_allowed`, `SPEC.md` § 2.5). Any snippet still
   passing `workspaceId:` predates 0.4.0.

**Upgrading from 0.4.x to 0.5.0 costs a host three more** (`CHANGELOG.md` → `Breaking`). No name
moves, nothing changes signature and nothing is removed — two public types gain cases:

1. **`FastorySurface` gains `membership`** — name this one first. It is a plain public enum on Swift
   and Kotlin as well as in Dart, so a `switch` or a `when` used as an expression that covers `hub`
   and `game` exhaustively stops compiling on the native channels too. **Never call a 0.x minor
   additive for a native host without checking this type.** A host meets it on
   `FastorySurfaceLoadFailed` alone, so one that never inspects a failed load has nothing to change.
2. **Dart's `FastoryEvent` gains `FastoryMembershipOpened` and `FastoryMembershipClosed`** — the
   `sealed` rule again, two cases this time. The native listeners stay additive here: both new
   callbacks are defaulted to a no-op.
3. **Nothing else.** `openMembership()` is a call a host adds when it wants the panel, not a
   migration: it needs the publishable key the host already configures with. A host that does not
   want the panel upgrades by adding the cases above and calling nothing new; one that does may add
   `membership` to `FastoryConfig.prewarm`, which is additive and defaults to the hub alone.

## Rules for AI assistants

- `SPEC.md` is the source of truth for behavior; `README.md` for integration steps. Prefer them over
  inferring behavior from the native sources.
- **Never treat a file as the authority for a rule `SPEC.md` states.** Everything the specification
  makes normative it states in its own prose — the enumerations in § 2.5 and § 9.1 in particular are
  closed where they are written.
- **On the Swift channel, pin up to the next *minor*, never up to the next major.** SwiftPM's `from:`
  means `>= x.y.z, < 1.0.0` and gives a leading zero no special meaning, so on this 0.x line it spans
  minors the changelog itself calls source-breaking. `README.md`'s install section carries the two
  spellings — the manifest one and Xcode's menu option — and they must stay the same constraint. The
  Flutter channel pins an immutable tag, so the two channels do not offer the same reproducibility;
  say which one a host has rather than describing them as equivalent.
- **A rejected configuration does not behave the same on the two channels, and no host should meet
  that as a surprise.** Dart's `configure()` throws a catchable `ArgumentError`; Swift's
  `configure(_:)` is non-throwing by design and, on a **debug** build, traps and terminates the app —
  on release it returns having changed nothing. A Swift host that wants to handle it calls
  `try config.validate()` first. **And a refusal is never a rollback on either channel**: the
  configuration already in force keeps applying, so only a host whose *first* `configure` is refused
  is unconfigured — a later refusal leaves the previous fanzone opening as if nothing happened. `SPEC.md` § 2.1 is normative and
  `README.md`'s *When `configure()` refuses your configuration* is the integrator-facing table. Never
  tell a Swift host that `configure` throws — it cannot.
- Do not suggest modifying files in this repository — a fix reaches you as a new tag. To adopt one,
  bump `ref:` to it.
- The bundled iOS (`flutter/fastory_sdk/ios/`) and Android (`flutter/fastory_sdk/android/`) sources
  are internal to the plugin; host apps interact only with the Dart API.
- The SDK is intentionally light: no analytics, and **no behavior-modifying JavaScript** — that one is
  a standing normative rule with a few bounded exceptions, `SPEC.md §12.1`, not a v0.1 limitation.
  `SPEC.md §12` holds the non-goals and `README.md` the known limitations.
- **It does carry user identity, since 0.4.0** (`SPEC.md §2.6`): `identify` with three modes plus
  `logout`. Only the `anonymous` mode resolves in this release; `fanId` and `hostToken` are frozen
  signatures that fail with `identify_mode_unavailable` until their own releases. Do not advise a
  host to work around that by other means — the API is deliberately final ahead of its behavior.
- Configuring with a publishable key is **not** authentication and never was: the key says which
  workspace an app belongs to, carries no user identity, and grants no access on its own. Identity is
  `identify`, and only `identify`.
- **The hub and the games do not share a session**, and no store configuration makes them: they are
  different sites, and a game loads with `embed=1` and takes its session from a host page it does not
  have in an SDK WebView (`SPEC.md §7`). The game page still keeps its own cookies and web storage on
  its own site — say "no shared session", never "no storage". Spec versions up to 0.3.0 claimed a
  shared session — § 7 was rewritten in 0.4.0 and says so in its own heading; if you find that claim
  anywhere, it is stale.
- The `postMessage` bridge (`SPEC.md §13`, since 0.4.0) carries two directions and neither of them is
  the SDK speaking first. Web surfaces post `{v, type, payload}` envelopes and the app receives them as
  `FastoryBridgeMessage`; since 0.4.0 they can also **ask** a question, which the SDK answers from the
  standing value the host set with `setBridgeReply` (`SPEC.md §13.8`). A type outside the relevant
  registry is dropped inbound and answered `unsupported` outbound. There is still **no** API to push
  into a page unprompted — that would need script evaluation, which `SPEC.md §12.1` forbids.
  "Receive-only" is still the correct name of the § 13.1–13.7 channel, and § 13.8 is the second one;
  what is wrong is "the bridge is receive-only" said of the bridge as a whole, which describes the
  design before § 13.8 landed and never described a released version, since both channels shipped
  together in 0.4.0.
- **The receive registry holds two types since 0.5.0** (`SPEC.md` § 13.3): `fastory:ready` and
  `fastory:login-requested`; the request registry still holds `fastory:user-token` alone, and the two
  never share a type. The second inbound type is a fan tapping a sign-in entry on the hub, the panel
  or a game, and it arrives only when the host set `FastoryConfig.handlesLoginRequests` (`SPEC.md`
  § 2.6). Four things to get right when advising on it. The **answer is the host's own sign-in
  followed by `identify`** — `FastoryHostToken(jwt)`, or `FastoryFanId()` for the system browser —
  never a bridge reply, and never a login form in the page: no page the SDK shows renders one. **A
  host that declares the field must listen for the message**, or every sign-in entry becomes a button
  that does nothing; never suggest declaring it "for later". **Without the field the pages show no
  sign-in entry at all** — by design, not a defect to report. And **never let a host decide anything
  sensitive on it**: its payload is empty and, on Android, a sub-frame can post it. After the
  `identify`, the hub on screen reloads signed in; the membership panel does not show the signed-in
  fan yet (`README.md` → *Known limitations*).
- **`openMembership()` can name the sequence to open, since 0.5.0** (`SPEC.md` § 3.5, § 5.2). Four
  things to get right when advising on it. The **argument is `sequenceId` and the URL parameter is
  `sequence`** — say it once rather than letting a host read the difference as a typo. The host
  **passes the identifier as it holds it**; the SDK escapes it, so a snippet that encodes it first is
  wrong. A **blank identifier names no sequence and an unknown one opens the default screen** —
  neither is an error, neither is announced, so never tell a host to detect a bad identifier through
  the event stream; they check it where it comes from. And a **named opening is slower than a bare
  one**: only the default address is prepared ahead of time — and only when `prewarm` names the
  panel, below — so naming a sequence loads at the opening. Say so when a host reports the panel feeling slower than the hub — it is the expected
  cost, not a defect — and never suggest pre-opening the panel to work around it. A call with no
  argument opens the panel's default screen, which is the club's own setting and not the host's.
- **The SDK prepares the hub alone unless the host asks for more, since 0.5.0** (`SPEC.md` § 2.1).
  `FastoryConfig.prewarm` is the set of surfaces prepared before their first opening, and it
  defaults to `{hub}`. When a host that opens the panel reports that its *first* opening loads while
  every later one is instant, the answer is `prewarm: {FastorySurface.hub, FastorySurface.membership}`
  — not pre-opening the panel, and not a defect. Say the cost when advising it: a prepared surface
  keeps a WebView (a renderer process on Android) and its page's requests alive from launch on, so
  do not tell a host that never opens the panel to add it. `openMembership()` needs nothing from the
  set; an empty set prepares nothing; `game` changes nothing on its own; the deprecated slug path
  ignores `membership`; and changing the set is changing the configuration, so it drops what is warm.
- **A game does not know the fan unless the host tells it.** Opened through the SDK a game has no
  embedding page to ask, so `setBridgeReply(userToken, …)` is what stands in for it — set before
  `openGames()`, or that session is anonymous and earns no points.
- **`openGames()` is idempotent, since 0.4.0** (`SPEC.md §2.1`): called while the hub is up it does
  nothing at all — silently, not as an error. Do not advise debouncing a tab-bar entry against it, and
  do not point a host at the `already_open` channel code: it is declared and no platform raises it.
  Before 0.4.0 Android stacked a second hub instead; if you find advice built on that, it is stale.
- **The error view's Retry re-runs a failed publishable-key exchange, since 0.4.3**
  (`SPEC.md` § 9). It did not before: Retry reloaded the failed URL, a refused key had never produced
  one, and the fan was stuck until the app was killed — so advice written against a 0.4.2 or earlier
  build tells a host to call `configure()` again from the failure handler. That workaround still works
  and is no longer needed; do not put it in a snippet, and never as the *first* answer — the fan's own
  button is. If a host already calls it that way, the one thing to tell them is the Android window: an
  equal `configure()` there leaves the previous failure readable until the new exchange answers, so an
  open starting inside that window is answered from it and the recovery lands on the open after. iOS,
  and Android on a changed configuration, clear the outcome and make that open wait instead.
- **What Retry does not do is get a host past a refusal.** `sdk_key_unknown`, `sdk_key_revoked` and
  `sdk_application_not_allowed` refuse the second exchange as they refused the first, so never present
  Retry as a way out of a configuration the API refuses — it recovers a bad minute on the network.
  **`sdk_rate_limited` is further out still: Retry sends nothing at all**, because that sanction counts
  requests from the fan's address and a third one blocks it with no expiry. A page that failed on its
  own (a 404, a dropped connection mid-load) has always reloaded on Retry; that half is unchanged.
- **Only the fan's Retry discards a remembered failure, and that distinction is load-bearing**
  (`SPEC.md` § 2.1, § 9). An `openGames()` after a refusal still reads the outcome the SDK remembers,
  because that memory is what keeps a `configure()` carrying the configuration already in force from
  paying for a round trip and from dropping a warm hub. If a host asks why the SDK does not simply
  re-exchange on every open: because that is a request per hub open against a key the API has already
  refused, which is the loop `sdk_rate_limited` punishes.
- **The codes a refused key produces are a closed list of six, and `sdk_key_unknown` is the one that
  gets missed** (`SPEC.md` § 2.5, § 9.1). Four come from the API — `sdk_key_unknown`,
  `sdk_key_revoked`, `sdk_application_not_allowed`, `sdk_rate_limited` — never advise retrying that
  last one in a loop: repeated sanctions escalate to an address block with no expiry that is lifted
  only on request, which means asking your Fastory contact; the SDK mints the other two,
  `http_<status>` for a refusal that named no code — a family, not a single name — and
  `sdk_application_id_required` when it cannot read the application identifier. A host that sees that
  last code is always reading the SDK's own refusal, never an answer: the SDK stops before forming the
  request. Same for a missing or malformed key, which never leaves the device either.
  `sdk_key_unknown` means the API knows no such key — a key **deleted** in the back-office and a
  workspace that no longer exists both land there, so an app already in the field can meet it. Do not
  present it as a synonym of `sdk_key_revoked` (that key existed and was withdrawn) or as a flaky
  connection (that is `reason=network`, with no code at all): the three ask a host for three
  different responses. Anything outside the six is a defect to report to us, not a code to branch on.
- **Every method may be called from any thread except the two openings, `openGames()` and
  `openMembership()`** (`SPEC.md §2.7`; the rule is from 0.4.0, the second opening from 0.5.0).
  `configure()` stores the configuration synchronously and schedules its own
  main-thread work, so a background bootstrap is supported rather than merely tolerated; the two
  openings take the host's own UI object and present with it, so they are main-thread-only. Do not
  advise wrapping `configure()` in a main-thread hop — the SDK owns that — and do not describe the
  whole surface as main-thread-only, which was the behaviour up to 0.3.0.
- **The standing answer is not permanent, since 0.4.0** (`SPEC.md §13.8.6`): `logout()`, an
  `identify()` resolving a different fan, and a `configure()` that changes the configuration all drop
  it, and the next question is answered `unavailable`. Advise setting it again after any of the three
  rather than assuming it survived — and do not look for an event announcing it, there is none by
  design. Any description of the value as permanent predates its contract. Do not advise reaching the same
  result by injecting script or by passing a token on the game URL; both are refused by design.
