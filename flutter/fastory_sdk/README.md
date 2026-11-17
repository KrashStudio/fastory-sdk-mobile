# fastory_sdk

Flutter plugin of the Fastory Mobile SDK. It opens a Fanzone's games hub in a full-screen native view
(WebView A), each game in a native bottom sheet (WebView B), and any external origin in the system
browser. The real logic is native — this package is a thin bridge over the same Swift and Kotlin cores
the native channels ship.

Scope: Fastory Mobile SDK v0.5.2 (ultra-light, WebView-based).

This file is the Dart reference: every method, event and error the plugin exposes. `README.md` at the
repository root is the full integration guide (it also covers the native iOS and Android channels), and `SPEC.md`
is the normative contract all channels conform to.

## Requirements

- Flutter ≥ 3.10, Dart ≥ 3.0
- iOS 15+ (the host app's Podfile must declare `platform :ios, '15.0'`)
- Android minSdk 24 (the host app must declare `minSdk = 24`)
- Android, since 0.5.0: the `appAuthRedirectScheme` manifest placeholder, set to your application id
  in `android { defaultConfig { … } }` of your app's Gradle file —
  `manifestPlaceholders += [appAuthRedirectScheme: applicationId]` in `build.gradle`,
  `manifestPlaceholders["appAuthRedirectScheme"] = "your.application.id"` in `build.gradle.kts`.
  The plugin depends on AppAuth, the OpenID library the `FastoryFanId` login runs through, and your
  build fails at manifest merge without it — whether or not you ever call `FastoryFanId`

The plugin depends on `androidx.webkit` since 0.4.0 — it is the only Android API that reports which
frame posted a message and from which origin, which the reply channel needs before it hands back a fan
credential. On a device whose system WebView predates that API (Chrome 85, mid-2020) the reply channel
is simply **absent**: a game that asks gets nothing back and stays anonymous. Nothing else about the
SDK is affected, and no host code changes.

## Installation (git dependency)

Consume the public distribution repo, pinned to a release tag:

```yaml
dependencies:
  fastory_sdk:
    git:
      url: https://github.com/KrashStudio/fastory-sdk-mobile
      path: flutter/fastory_sdk
      ref: sdk-v0.5.2
```

## Upgrading from 0.5.0: nothing in Dart

Your Dart code is not concerned: every name this package exports keeps working, unchanged. What
0.5.1 withdraws are names the plugin's Swift and Kotlin code made public without `SPEC.md` ever
declaring them. A Flutter app meets them only if its own native code imports the plugin's classes,
which the plugin never asked of it.

**Swift** — `URLPolicy` and `NavigationDecision`, the key-exchange error type,
`FastoryEnvironment.baseURL`, the two publishable-key prefix constants, the static
`FastoryConfig.validate(fanzoneSlug:hubTabSlug:)` and `FastoryIdentity.mode`.

**Kotlin** — `UrlPolicy` and its decision enum `NavigationDecision`, the bridge object
`FastoryBridge`, the hub `Activity` `FastoryHubActivity`, the game sheet `GameBottomSheet`,
`FastoryConfig.baseUrl`, its URL builders (`hubUrl`, `membershipUrl`, `staticHubUrl`) and its publishable-key
prefix constants, and the `wireName` of `FastorySurface` and `FastoryLoadFailureReason`. The
library's Android theme and ids become private too; the six strings an app may redefine stay public.

If your native code used one, write the value yourself: the surface and failure-reason names are the
lowercase strings of `SPEC.md` § 5.3 and § 9.1, the prefixes are `fpk_live_` and `fpk_test_`, and
the base URLs are the table in `SPEC.md` § 3.1.

## Upgrading from 0.4.x: four source breaks and one Android build line

0.5.0 adds `openMembership()` with its own pair of events, and `FastoryIdentityRevoked`. Nothing you
already call moves or changes signature, and nothing is removed — but two public types gain cases,
four in all, and your Android build needs one line it did not need before.

**1. `FastoryEvent` gains `FastoryMembershipOpened` and `FastoryMembershipClosed`.** It is `sealed`,
so an exhaustive `switch` with **no** `default:` stops compiling until both cases exist — the same
rule as 0.4.0, two cases this time.

**2. `FastorySurface` gains `membership`.** You meet it on `FastorySurfaceLoadFailed`, which now also
reports a membership panel that did not load. The same enum is public on Swift and Kotlin, so if you
also embed the native channel, an exhaustive `switch` or `when` there stops compiling as well. On
Swift that channel meets one more break, which Dart does not: `FastoryIdentifyError.rejected` now
carries `code: String?`.

**3. `FastoryEvent` also gains `FastoryIdentityRevoked`.** It tells you that a fan you identified
lapsed to anonymous, and why — see *Keeping a `hostToken` fan signed in*. A third new case of the
same `sealed` type, so the same exhaustive `switch` needs it too.

**And one build line: on Android, declare the `appAuthRedirectScheme` manifest placeholder** (see
*Requirements* above).
Without it your Android build fails at manifest merge, whether or not you call `FastoryFanId`. A
build line, not a source break; iOS needs nothing until you adopt `FastoryFanId`.

**Nothing else asks anything of you.** The panel needs the publishable key you already configure
with. If you open it, consider adding `FastorySurface.membership` to `prewarm` so its first opening is
instant — see *Preparing the panel ahead of time*.

## Upgrading from 0.3.0: three source breaks

Everything specified since 0.3.0 ships as 0.4.0, so all three arrive in one upgrade. Nothing else here
asks anything of you.

**1. `FastoryEvent` gains three subtypes.** It is `sealed`, so an exhaustive `switch` with **no**
`default:` stops compiling until you add a case for **all three** — `FastoryBridgeMessage`,
`FastoryIdentityResolved` and `FastorySurfaceLoadFailed`. Keeping a `default: break;` makes your call site forward-compatible;
dropping it turns the next new event into a compile error instead of a silently ignored case. Both are
reasonable — pick deliberately. The native channels are additive: each new callback has a no-op
default.

**2. Android gains an `androidx.webkit` dependency and a WebView floor** (see *Requirements* above).
Nothing to change in your code; on a device below Chrome 85 the reply channel is absent and the
surface stays anonymous.

**3. `workspaceId` is gone from `FastoryConfig`.** Delete the argument if you pass it — there is
nothing to replace it with. It was an optional cross-check against the workspace your publishable key
resolves to, and a key resolves exactly one workspace, so it asked you to confirm what the key already
settles. What stops a key opening a workspace it does not belong to is the exchange being bound to
your application identifier, which the API refuses unless the owning workspace declared it on that key
(`sdk_application_not_allowed`). That refusal is unconditional, so nothing it protected is now
unprotected.

## Configure

```dart
import 'package:fastory_sdk/fastory_sdk.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Fastory.configure(const FastoryConfig(
    publishableKey: 'fpk_live_...',
    theme: FastoryTheme.dark,   // optional
    locale: 'fr-FR',            // optional
  ));
  runApp(const MyApp());
}
```

| Field | Type | Default | Description |
|---|---|---|---|
| `publishableKey` | `String?` | — | Workspace publishable key, created in the workspace settings. **Preferred.** One of this and `fanzoneSlug` is required |
| `fanzoneSlug` | `String?` | — | **Deprecated** since 0.3.0, accepted for the whole 0.x line: the Fanzone to open, e.g. `your-fanzone` |
| `environment` | `FastoryEnvironment` | `production` | `production` (`fanzone.me`), `staging` (`staging.fanzone.me`), `development` |
| `hubTabSlug` | `String` | `games` | Hidden Fanzone tab used as the hub |
| `locale` | `String?` | `null` | Locale hint forwarded to the hub and game URLs, and the error view's fallback language; unset, the web Fanzone resolves its own |
| `theme` | `FastoryTheme?` | `null` | `light` or `dark`, forwarded to the hub and game URLs. The web side does not read it yet, so setting it is inert until it ships there |
| `developmentBaseUrl` | `String?` | `null` | Base URL, required when `environment` is `development` |
| `prewarm` | `Set<FastorySurface>` | `{FastorySurface.hub}` | The surfaces prepared before their first opening, so that opening shows them already rendered — *since 0.5.0*. Add `FastorySurface.membership` if you open the membership panel; an empty set prepares nothing. See *Preparing the panel ahead of time* |
| `handlesLoginRequests` | `bool` | `false` | Declares that your app listens for `fastory:login-requested` and `fastory:logout-requested`, signs the fan in itself, and signs them out itself once they confirm — the sign-in request *since 0.5.0*. Set, the sign-in and sign-out entries of the hub, the panel and the games ask your app; left `false`, the pages show neither. See *Signing the fan in and out from a page* |

Call `configure()` once before `openGames()`. If you call it straight from `main()`, call
`WidgetsFlutterBinding.ensureInitialized()` first so the platform channel has a binding.

Since 0.4.0 `configure()` no longer builds the hub WebView while your app is drawing its first
screen — it waits for the first frame, and warms nothing at all on a background launch. Opening the
hub is as fast as before, on both paths: configured by slug the page is prepared right after that
first frame, and configured by key it is prepared as soon as the exchange resolves, so
the first tap finds it ready like every later one. A re-`configure()` with a *different*
configuration also drops the warm hub, so the next `openGames()` shows the new fanzone rather than
the previous one.

### Preparing the panel ahead of time

By default the SDK prepares the hub alone. A prepared surface opens already rendered, and it costs a
WebView kept in memory from launch on — a renderer process on Android — plus the requests its page
makes, whether your fan opens it or not. So the membership panel is prepared only if you ask for it:

```dart
Fastory.configure(const FastoryConfig(
  publishableKey: 'fpk_live_...',
  prewarm: {FastorySurface.hub, FastorySurface.membership},
));
```

Leave `membership` out and `openMembership()` still works: its first opening loads while your fan
waits, and once that page has loaded it is kept when the panel closes, so every later opening is
instant — a panel closed on its error view keeps nothing and loads again. The same goes for the hub
if you remove it. An empty set prepares nothing ahead of time, and the key exchange still
starts at `configure()`. `FastorySurface.game` changes nothing on its own — games are preloaded from
the hub's page, so they follow `hub`. On the deprecated `fanzoneSlug` path `membership` is ignored:
that path names no workspace, so there is no panel to prepare. A `configure()` with a different
`prewarm` is a different configuration and drops what is warm; the same set again keeps it.

Pass **exactly one** identifier: a key or the deprecated slug, never both and never neither. A
publishable key must match its environment — `fpk_live_` in production, `fpk_test_` everywhere else —
and `configure()` throws an `ArgumentError` on every one of these before reaching the platform channel
or the network. **The message names the rule that was broken and the environment expected, never the
key you passed**, so logging the exception — the ordinary thing to do with a failed `configure()` —
does not put your publishable key in your crash reporter.

A refused `configure()` changes nothing at all — including the configuration you had already set,
which keeps applying. Refuse your *first* call and you are unconfigured; refuse a later one and the
SDK keeps running on the previous configuration, so `openGames()` opens that fanzone rather than
reporting a problem. Do not read the exception as a rollback.

The native Swift channel does not behave this way, and it is worth knowing if you also ship a native
iOS app against the same SDK: `Fastory.configure(_:)` there is non-throwing and traps on a debug
build instead. The published integration guide's *When `configure()` refuses your configuration*
carries all three channels side by side.

Two things to know before you pick the key path:

- **Managing keys needs the Mobile SDK add-on on your workspace.** Without it the back-office screen
  presents the feature instead of listing keys, and creating or revoking one answers
  `403 sdk_addon_required`. The add-on gates management only: a key already shipped in an app keeps
  resolving if it is later removed.
- **The key exchange runs in production as well as on staging**, so build on the key from the start.
  Keys are minted per environment — `fpk_live_…` for production, `fpk_test_…` elsewhere — and
  `configure()` refuses a key that disagrees with the `environment` you pass, before any network call.
  Change the two together. If a live key does not resolve, ask your Fastory contact whether its
  workspace is provisioned.

## Methods

| Method | Description |
|---|---|
| `Fastory.configure(FastoryConfig)` | Sets the configuration. Call once, before anything else — except `setHostTokenProvider`, which an app using `FastoryHostToken` registers first |
| `Fastory.openGames()` | Presents the hub full screen. Idempotent since 0.4.0: a call while the hub is up does nothing |
| `Fastory.openMembership({String? sequenceId})` | Presents the membership panel full screen. Needs a publishable key. One surface at a time: a call while the hub or the panel is up does nothing. `sequenceId` opens the panel on one of the club's sequences, no argument opens its default screen — *since 0.5.0* |
| `Fastory.close()` | Dismisses the game sheet then whichever surface is showing, and cancels an opening still waiting to be presented. No-op if nothing is open or waiting |
| `Fastory.identify(FastoryIdentity)` | Binds your user to a Fastory fan. Returns the resolved identity — see *Identity* |
| `Fastory.logout()` | Signs the fan out of Fastory only, and erases what the SDK stores for them. Idempotent, and never fails |
| `Fastory.setBridgeReply(type, payload)` | Declares what the SDK answers when a web surface asks — see *Answering the web content* |
| `Fastory.setHostTokenProvider(provider)` | Registers a `FastoryHostTokenProvider` the SDK calls back for a fresh host token when a delegated session needs renewing; `null` clears it — see *Keeping a `hostToken` fan signed in* — *since 0.5.0* |

```dart
await Fastory.openGames();
await Fastory.close();
```

`openGames()` presents the hub full screen. **It is idempotent since 0.4.0**: called while a hub is
already on screen it does nothing at all — no second hub, and nothing to catch, so a tab-bar entry a
fan double-taps needs no debouncing of its own. You get one `hubOpened` and one `hubClosed` per hub
the SDK presents. Tapping a game (`/s/{slug}`) opens the native bottom sheet
with `embed=1&utm_source=sdk&consent=0` — `utm_source=sdk` replacing the `utm_source` the link
carries, so every game the SDK opens is counted as SDK traffic, a game opened from another game in the
sheet included; the link's other parameters reach the game exactly as written. A `/s/` link on a Fastory stories domain
(`https://story.tl`, `https://staging.story.tl` — both, whichever environment you configured) is a
game too and opens the same sheet. Any other origin, and any non-http(s) scheme (`mailto`, `tel`,
`intent`, `market`), opens in the system browser. On Android the back button
first closes the bottom sheet, then walks the presented surface's WebView history, then closes the
view — the hub's when it is open, the membership panel's when that is (since 0.5.0).

`openMembership()` presents the club's panel on its default screen. **You can name the sequence to
open instead:**

```dart
await Fastory.openMembership(sequenceId: '2f8a1c64-5b3e-4d71-9a02-7c1e5d3b8f40');
```

The argument is `sequenceId` and the URL parameter it becomes is `sequence` — one name reads as what
you hold, the other is what the page reads. Pass the identifier exactly as you hold it: the SDK
escapes it, so encoding it yourself is how it reaches the panel with `%` sequences in it. An empty or
blank identifier names no sequence, and one the club does not carry opens the default screen —
neither is an error, and no event tells them apart from a good one, so validate an identifier where
it comes from. **And a named opening is slower than a bare one:** the panel is prepared ahead of the
first tap on one address only, the default screen, since the SDK cannot guess which sequence you will
ask for. Naming one loads the page when you ask for it; the bare call presents a page that is already
there. It is the preparation that makes that call instant, so the difference is inherent rather than
something to report — and that preparation happens only when `prewarm` names the panel.

## Events

`Fastory.events` is a broadcast stream of sealed classes — switch over the event instance:

```dart
final subscription = Fastory.events.listen((FastoryEvent event) {
  switch (event) {
    case FastoryHubOpened(:final fanzoneSlug):
      print('hub opened: $fanzoneSlug');
    case FastoryGameOpened(:final slug):
      print('game opened: $slug');
    case FastoryExternalLink(:final url):
      print('external link: $url');
    case FastoryIdentityResolved(:final mode, :final fanId):
      print('identity: ${mode.name} $fanId');
    case FastoryBridgeMessage(:final type, :final payload):
      print('bridge said $type with $payload');
    case FastorySurfaceLoadFailed(:final surface, :final reason, :final code):
      print('${surface.name} did not load: ${reason.name} ${code ?? ''}');
    case FastoryIdentityRevoked(:final reason, :final code):
      print('identity revoked: ${reason.name} ${code ?? ''}');
    case FastoryHubClosed():
    case FastoryGameClosed():
      break;
  }
});
```

| Event | Payload | Emitted when |
|---|---|---|
| `FastoryHubOpened` | `fanzoneSlug` | The hub view is presented |
| `FastoryHubClosed` | — | The hub view is dismissed |
| `FastoryMembershipOpened` | — | The membership panel is presented — *since 0.5.0* |
| `FastoryMembershipClosed` | — | The membership panel is dismissed — *since 0.5.0* |
| `FastoryGameOpened` | `slug` | A game sheet is presented |
| `FastoryGameClosed` | — | The game sheet is dismissed |
| `FastoryExternalLink` | `url` | A non-Fanzone link was handed off to the system browser |
| `FastoryBridgeMessage` | `type`, `payload` | A Fastory web surface posted a message — *since 0.4.0* |
| `FastoryIdentityResolved` | `mode`, `fanId` | `identify` resolved an identity, once per resolution, before any hub or game opening carrying it. `fanId` is null when anonymous — *since 0.4.0* |
| `FastorySurfaceLoadFailed` | `surface`, `reason`, `code`, `statusCode` | A hub, a game or (since 0.5.0) the membership panel did not load — *since 0.4.0* |
| `FastoryIdentityRevoked` | `reason`, `code` | The SDK dropped an identified fan — `FastoryHostToken` or `FastoryFanId` — on its own: the session expired unrenewably (`FastoryRevocationReason.expired`) or a background renewal was refused (`FastoryRevocationReason.rejected`, with the server's `code`); for a `FastoryFanId` fan, often shortly after launch. The fan is now anonymous; `logout()` never emits it — *since 0.5.0* |

`hubOpened` … `hubClosed` bracket every hub session and, since 0.5.0, `membershipOpened` …
`membershipClosed` every panel session — once each, even when Android rebuilds the screen in place —
and `gameOpened` / `gameClosed` nest inside the session the game was opened from, closing first. The
SDK sends no analytics of its own — you own all tracking through this stream.

## When a surface does not load (since 0.4.0)

A fanzone that does not exist, a key you revoked, a game that was taken down, a fan in a tunnel: the
SDK shows its own error screen with a Retry button — the game sheet has one too since 0.4.0 —
and tells your app what happened. The screen is localized in English, French and Spanish, follows the
fan's device language — falling back to the `locale` you configured, then to English — and
distinguishes a lost connection from any other failure.

- **`surface`** is `FastorySurface.hub`, `FastorySurface.game` or `FastorySurface.membership`.
- **`reason`** is what you branch on. `FastoryLoadFailureReason.rejected` — something answered and
  refused. `FastoryLoadFailureReason.network` — nothing answered: no connection, DNS, timeout.
  `FastoryLoadFailureReason.unknown` — everything else. Three cases on purpose, so "is Fastory
  reachable?" is one branch rather than a match over the codes below.
- **`code`** is non-null only when your publishable key was refused, and it is the field worth
  alerting on — a configuration problem, not a flaky connection. Branch on the code, never on a
  message. Only six things can appear there — five names and the `http_<status>` family. Four of the
  names come from our API: `sdk_key_unknown`
  (401 — we know no such key, which covers a key **deleted** in the back-office and a workspace that
  no longer exists, so an app already in the field can meet it), `sdk_key_revoked` (403 — the key
  existed and was withdrawn), `sdk_application_not_allowed` (403 — this bundle identifier / package
  name is not declared on the key) and `sdk_rate_limited` (429 — **not always transient**: repeated
  sanctions escalate to an address block with no expiry that is lifted only on request — ask your
  Fastory contact — so back off rather than retry in a loop). **The other two the SDK mints**, so that
  a refusal is never reported as a blank: `http_<status>` when the refusal named no code of its own —
  JSON without a `code`, an HTML error page, or no body at all — and `sdk_application_id_required`
  when the SDK could not read your app's identifier at all and had no well-formed request to send
  (iOS only in practice — an Android package name always exists).

  Anything else appearing here is a bug to report. Nothing answered at all → `code` is
  null, and `reason` says so: an unknown key, a revoked key and a fan with no signal are three different
  situations and only the last is the connection.
- **`statusCode`** is the HTTP status the page itself answered, when the page is what failed.
- **No opening event is emitted for a surface that failed**, and no closing one either: if you count
  `FastoryHubOpened` as a session, a hub that never loaded is not one.
- **A surface closed on its error view keeps nothing.** Left without *Retry*, a hub or a panel that
  did not load starts over at its next opening, and its opening event arrives only once a page has
  loaded — still offline, the error view and a new `FastorySurfaceLoadFailed` come back instead.
  After a failed publishable-key exchange, though, that next opening can show the error view even
  back online, answered from the exchange that failed: *Retry* opens it, and on Android so does the
  opening after.
- **The SDK never retries by itself**, and it never reports the same failed load twice. Cancellations
  it performs itself when routing a game or an external link are not failures and are not reported.
  It reloads without *Retry* only when Android rebuilds a screen in place (a language or
  display-size change, *Don't keep activities*): a game sheet reloads its game with the screen,
  error view or not, and a hub or a panel rebuilt while its error view is up loads its page again,
  as its first opening did — online it opens, offline you receive one more
  `FastorySurfaceLoadFailed`.
  A rebuild does not run the publishable-key exchange again, so when that exchange is what failed
  the error view can stay up until your fan presses *Retry*.
- **Retry recovers a refused publishable key too**, since 0.4.3. It used to be the one place the
  button fell short: Retry reloaded the page that failed, a key we refused had never produced one,
  and the fan stayed stuck until they killed the app. The button now re-runs the key exchange, so a
  fan who lost signal at launch taps Retry and the hub opens — no `Fastory.configure()` call from you,
  and no restart. A page that failed on its own reloads normally, and so does everything on the
  deprecated `fanzoneSlug` path.
- **The codes worth alerting on are unchanged by that.** `sdk_key_unknown`, `sdk_key_revoked` and
  `sdk_application_not_allowed` refuse the second exchange exactly as they refused the first, so no
  amount of tapping gets the fan in. Retry recovers a bad minute on the network, not a configuration
  we have refused.
- **`sdk_rate_limited` is the exception: Retry does not even ask again**, because that code's sanction
  counts requests from your users' address rather than from your key, and a third one blocks the
  address with no expiry. The error view stays and no request leaves the device.

## Identity (since 0.4.0)

One method, three mutually-exclusive modes, plus a sign-out. **This API is final**, and since 0.5.0
all three modes resolve.

| Mode | What your user does | Available |
|---|---|---|
| `FastoryAnonymous()` | nothing; each surface's page mints its own device visitor | **now** |
| `FastoryFanId()` | signs in to Fastory, in the **system browser** (never in a WebView) | **now** |
| `FastoryHostToken(jwt)` | nothing — your backend asserts an identity it already authenticated | **now** |

```dart
final FastoryResolvedIdentity identity =
    await Fastory.identify(const FastoryAnonymous());

// No identity system of your own? The user signs in to their Fastory account in the system browser:
final FastoryResolvedIdentity fan = await Fastory.identify(const FastoryFanId());

// Your backend already authenticated the user — pass its signed assertion, no screen opens:
final FastoryResolvedIdentity fan =
    await Fastory.identify(FastoryHostToken(jwtFromYourBackend));
// fan.fanId is a stable id for the account; the games and the hub now show that fan.

await Fastory.logout();
```

- **`identify(anonymous)` is idempotent.** Calling it twice, or on every launch, gives you the same
  fan. You do not have to call it at all: an app that never does behaves as it did before 0.4.0.
- **`hostToken` opens no browser and no screen.** Your backend authenticated the user; you pass the
  JWT it signed and the SDK exchanges it for a Fastory session — the games and hub then show that fan.
  It requires configuring with a **publishable key** (the exchange is bound to the resolved
  workspace); on the deprecated `fanzoneSlug` path it rejects with `identify_mode_unavailable`. The
  SDK never validates the JWT itself — a malformed or expired one comes back as `identify_rejected`
  with the API's own `code` in `PlatformException.details['code']`. Asking for the same user again is
  idempotent; asking for a different one replaces the session and leaves no trace of the previous fan.
- **`FastoryFanId()` opens the Fastory login in the system browser** through the platform's reference
  OpenID library, which ships with the SDK. Like `hostToken` it requires a publishable-key
  configuration; on the `fanzoneSlug` path it rejects with `identify_mode_unavailable`. A user
  already signed in on that browser round-trips without typing; dismissing the sheet rejects with
  `login_cancelled` and leaves the SDK anonymous. One setup step per platform — the Android
  `appAuthRedirectScheme` manifest placeholder and the iOS URL scheme, both set to your own
  application id — is in the integration guide.
- **Failures are typed and never leave the SDK half-identified** — branch on
  `PlatformException.code`, never on the message.
- **`logout()` is Fastory-only, in both directions.** It expires a declared list of Fastory cookies on
  the Fastory origins, deletes their web storage and erases what the SDK stores for the fan; your own
  session is never touched. Symmetrically, signing a user out of your app does not sign them out of
  Fastory — call `logout()` for that.
- An identity change drops the warm hub and the preloaded games: they were rendered for the previous
  fan, so the next `openGames()` is a cold open. One exception: after a `logout()`, a signed-in fan's
  hub still on screen once their data has been cleared reloads signed out, and once that page has
  loaded, it is kept when your fan closes it, like any hub, so the next `openGames()` shows it at
  once. Since 0.4.0 an identity change drops the standing bridge answer too — see *Answering the web
  content*.

### Keeping a `hostToken` fan signed in (since 0.5.0)

A `FastoryHostToken` session has a short lifetime. The SDK keeps the fan identified across it without
a visible break — give it a way to fetch a fresh token:

```dart
Fastory.setHostTokenProvider(() async => await yourBackend.freshJwt()); // return null when you cannot
```

- It refreshes the session server-side while it is still valid, asking no one; it calls your provider
  when that refresh fails or there is no session to refresh — once the session has expired, or for a
  fan restored without a session (below). The call is non-blocking and the SDK never inspects your
  token. Pass `null` to clear it; with no provider a session simply lapses when it expires. The SDK never
  calls it for a `FastoryFanId` fan, whom it keeps signed in on its own (below).
- When a session cannot be renewed, the SDK drops the fan to anonymous and emits
  `FastoryIdentityRevoked` — `reason == FastoryRevocationReason.expired` when nothing could renew it,
  `rejected` (with the server's `code`) when a renewal was refused. Re-`identify` with a fresh token,
  or let the fan continue anonymously; `logout()` never emits it.
- A verified fan survives an app restart: the SDK stores the identity — its mode and `fanId`, an
  account identifier — and **no token** for a `FastoryHostToken` fan, and restores it at `configure`,
  with no `FastoryIdentityResolved`. The session is not stored: while the fan has no session, the
  SDK asks your provider for a fresh token when `configure` runs if the provider is registered by
  then, right after you register it if that comes after `configure` — on the next turn of the main
  thread — and at each opening of the hub or the panel — one call at a time, never for a fan who has
  a session — and exchanges it in the
  background, with nothing waiting for it, so **register the provider before you call `configure`**:
  the session then comes back soonest. A hub or a panel that loads before the session is back shows
  the fan anonymous: a game picks the session up as soon as it is back, and the hub and the panel at
  their next opening, but a panel already on screen is not reloaded for it.
- Until you register a provider, a restored fan's session does not come back: the fan stays
  identified and is restored again at the next launch, the surfaces show them anonymous, and your
  app receives nothing — no `FastoryIdentityRevoked`, no `FastoryIdentityResolved` — since a
  provider may still come. Register one and the SDK asks it right after, on the next turn of the
  main thread: a token for the same fan brings the session back with no event, and `null` drops the
  fan to anonymous with `FastoryIdentityRevoked(reason: expired)`. Calling `identify` again works
  too, and an answer for the restored fan that comes back once `identify` has resolved or failed is
  ignored.

### Keeping a `fanId` fan signed in

A fan who signed in with `FastoryFanId()` stays signed in from one launch of your app to the next,
with no browser and no call to your code: the login also returns a **refresh token**, which the SDK
stores on the device and presents at launch for a new session. The hub, the membership panel and the
games open signed in as that fan from the first screen — a page asking for the fan during that
renewal waits for it, and so does the hub's opening, 3 seconds at most. A surface that loads after
that, while a slower renewal is still out, shows the fan anonymous and catches up as described for a
`FastoryHostToken` fan above: a game as soon as the session is back, the hub and the panel at their
next opening, a panel already on screen not at all. Each renewal replaces the token; a fan who opens your app at least once every 90 days stays signed in for a year from their
login, then signs in again in the system browser. A launch with no network keeps the fan signed in,
and the SDK tries again later.

**What the SDK stores** — declare it if you declare the data your app stores on the device:

- the identity, in your app's ordinary preferences (`UserDefaults`, `SharedPreferences`), scoped to
  the environment and the publishable key;
- the refresh token, a credential, which never reaches a page, a URL or a log. **iOS**: the Keychain,
  under a service of the SDK's own, readable once the device has been unlocked after a restart, on
  this device only, never synchronised to iCloud — and, since the SDK sets no access group, in your
  app's **default access group**, so apps of your team that share that group can read it. **Android**:
  a file of your app's no-backup files directory, encrypted with a key held in the Android Keystore.

**How the fan loses that session:**

- `logout()` erases everything at once and asks our servers to revoke the session, best effort: it
  never waits for that request and never fails, and offline the token, already gone from the device,
  expires on its own. Identifying another fan, or the same fan again, revokes the previous one the
  same way.
- `FastoryIdentityRevoked`, usually shortly after a launch: `expired` when the sign-in aged out — 90
  days without opening your app, or a year since the login — and `rejected`, with the API's `code`,
  when a renewal was refused: a revoked or deleted publishable key, an application identifier removed
  from it, or the same token presented twice (`refresh_token_reused`), which ends the session for
  every holder. Long past its lifetime, a token our servers no longer know comes back `rejected`
  with `refresh_token_invalid`. Whatever the reason, `identify(FastoryFanId())` signs them in again.
- With no event, the fan is anonymous after a reinstall, a restore onto another device (on Android,
  any restore from a backup), a Keystore key Android invalidated, or a version of your app configured
  with another environment or a regenerated publishable key.

Signing in on one device does not sign the fan out on their others, and neither does `logout()`.

## Bridge messages (since 0.4.0)

A Fastory web surface can send your app a typed message, as `FastoryBridgeMessage` on the event
stream. You enable nothing; no JavaScript is injected into your users' pages.

- **Three types exist today**, and `FastoryBridgeMessage.knownTypes` holds them:
  - `fastory:ready` — the embedded surface has rendered. It is a liveness signal, not a lifecycle
    event, and you must not *require* it to arrive: the web side may be deployed at a version that
    never sends it.
  - `fastory:login-requested` — *since 0.5.0*, a fan tapped a sign-in entry on the hub, the
    membership panel or a game, and asks your app to sign them in. Sent only when you set
    `handlesLoginRequests`, below.
  - `fastory:logout-requested` — a fan tapped a sign-out entry on the same pages, and
    asks your app to sign them out. Sent under the same declaration. Ask the fan to confirm before
    you call `logout()` — never sign them out on the message alone, below.
- **Unknown types are dropped**, which is what lets a new type ship later without breaking an app
  already in the stores.
- **These messages travel web → app only.** Nothing you do makes one arrive, and the bridge changes
  nothing about the games flow.

### Signing the fan in and out from a page (signing in since 0.5.0)

No page the SDK shows ever opens a login form, and no sign-out entry ends the fan's session in the
page. A sign-in or sign-out entry on the hub, the panel or a game either asks your app, or is not
there.

**Never sign the fan out on `fastory:logout-requested` alone.** Ask first, and call `logout()` only
on the fan's yes. On Android a frame embedded inside a game can post the message without the fan
touching anything; an app that called `logout()` on receipt would let that frame sign your fan out
behind their back.

**Close the surface before you show your sign-in or your confirmation.** The hub, the panel and the
game sheet are native screens presented above your Flutter view — full screen on iOS, a separate
Activity on Android — so a Flutter route or dialog draws beneath them, and your fan sees it only once
they are gone. Answer in four steps: `close()`, your sign-in or your confirmation, `identify` or
`logout()`, then reopen the surface your fan was on — `openGames()` for the hub or a game, which
reopens on the hub, or `openMembership()` with the same `sequenceId`. `close()` returns before the
surface has left the screen — on iOS it animates out — so show your screen once its closing event
arrives, `FastoryHubClosed` or `FastoryMembershipClosed`. Bound that wait: with nothing on screen no
closing event comes, so skip it, and a short timeout keeps your fan from waiting on an event that
never arrives. A refused or cancelled `identify` rejects with a `PlatformException`: catch it, or it
leaves your listener as an unhandled error. Reopen in a `finally`, so your fan gets the surface back
in every case — signed in, signed out, refused, cancelled, or after a sign-in of yours that throws.
And answer one request at a time — a fan who taps twice sends two:

```dart
Fastory.configure(const FastoryConfig(
  publishableKey: 'fpk_live_...',
  handlesLoginRequests: true,
));

FastorySurface? onScreen;
bool answering = false;

Fastory.events.listen((FastoryEvent event) async {
  switch (event) {
    case FastoryHubOpened():
      onScreen = FastorySurface.hub;
    case FastoryMembershipOpened():
      onScreen = FastorySurface.membership;
    case FastoryHubClosed() || FastoryMembershipClosed():
      onScreen = null;
    case FastoryBridgeMessage(type: 'fastory:login-requested'):
      await answerOffTheSurface(() async {
        // Your own sign-in, then the assertion your backend signs for that user:
        final String? jwt = await yourApp.signIn();
        if (jwt != null) await Fastory.identify(FastoryHostToken(jwt));
        // No identity system of your own? Let the fan sign in to Fastory in the system browser:
        // await Fastory.identify(const FastoryFanId());
      });
    case FastoryBridgeMessage(type: 'fastory:logout-requested'):
      await answerOffTheSurface(() async {
        // Ask first: the message alone is not the fan's tap.
        final bool confirmed = await yourApp.confirmSignOut();
        if (confirmed) await Fastory.logout();
      });
    default:
      break;
  }
});

Future<void> answerOffTheSurface(Future<void> Function() answer) async {
  // One request at a time: a second tap asks nothing new.
  if (answering) return;
  answering = true;
  final FastorySurface? origin = onScreen;
  try {
    final Future<void> leftScreen = origin == null
        ? Future<void>.value()
        : Fastory.events
            .firstWhere((FastoryEvent e) =>
                e is FastoryHubClosed || e is FastoryMembershipClosed)
            .then((_) {});
    // First, and wait until the surface is gone, or your screen draws under it:
    await Fastory.close();
    await leftScreen.timeout(const Duration(seconds: 2), onTimeout: () {});
    await answer();
  } on PlatformException catch (refusedOrCancelled) {
    debugPrint('Sign-in not completed: ${refusedOrCancelled.code}');
  } finally {
    answering = false;
    // Back where the fan was, whatever happened above: signed in, signed out, as they were if
    // they cancelled, or as the failure left them:
    if (origin == FastorySurface.hub) await Fastory.openGames();
    if (origin == FastorySurface.membership) {
      await Fastory.openMembership(sequenceId: yourApp.panelSequenceId);
    }
  }
}
```

- **With `handlesLoginRequests: true`** the entries stay, and a tap sends you the matching message —
  empty payload, once per tap, never because a page loaded. Answer with `identify` or `logout()`:
  there is no reply on the bridge. Once `identify` resolves a different fan, the hub or the panel you
  reopen shows that fan signed in — a hub or a panel still on screen reloads, on the panel's same
  `sequenceId`, without keeping its scroll position and without an opening or closing event — and
  the games pick the new session up on their own. Once `logout()` drops the fan, the hub and the
  panel show them signed out, and the games learn it the same way.
- **Until you answer a sign-out request, the fan stays signed in** — in the page and in the SDK. If
  your fan cancels your sign-in or your confirmation, reopen the surface without calling `identify`
  or `logout()`: they land back where they were, as they were.
- **`logout()` signs the fan out of Fastory only.** Whether a sign-out entry in the page should also
  sign your user out of your own app is your decision — the SDK never touches your session.
- **Left `false`, the default,** the pages show no sign-in or sign-out entry: an entry whose only job
  is to sign in or out is hidden, and content that needs a signed-in fan reads *Sign in from the app
  to continue*, with no button. A fan you signed in with `identify` is signed out by your own
  `logout()` call.
- **Set it only if you listen for both messages.** Declared and unheard, every sign-in and sign-out
  entry is a button that does nothing, and the SDK opens nothing and signs nobody out on either
  message itself.
- **Never decide anything that matters on them.** On Android a frame embedded inside a game can post
  either one too; asked first, the worst it can do is show your sign-in, or your confirmation, when
  the fan did not ask.

## Answering the web content (since 0.4.0)

A Fastory web surface can also **ask** your app something, and the SDK answers on its behalf. You
declare the answer up front; nothing is asked of you at the moment the question arrives.

```dart
// Before opening a game — typically right after you obtained the fan's token.
await Fastory.setBridgeReply(
  FastoryBridgeRequestType.userToken,
  <String, Object?>{'token': fanToken},
);

// `logout()` already drops it — this is for signing the fan out of Fastory without calling it.
await Fastory.setBridgeReply(FastoryBridgeRequestType.userToken, null);
```

Why it exists: a Fastory game normally asks the page embedding it who the fan is. Opened through the
SDK there is no such page — the game *is* the top-level document — so without an answer every game
session is anonymous.

- **One request type exists today:** `FastoryBridgeRequestType.userToken`. It is an enum, not a
  string, so you cannot name a type the SDK does not serve.
- **The answer is a standing value, not a callback.** It is what the *next* request gets. Set it
  before `openGames()`: the game asks while it boots, so a later answer arrives too late for that
  session.
- **Standing is not permanent, since 0.4.0 — set it again after any of these.** The value is a
  credential, so it does not outlive what justified it:

  | Call | When it drops the answer |
  |---|---|
  | `Fastory.logout()` | Always, including when you never called `identify()` |
  | `Fastory.identify(…)` | Only when it resolves a **different** fan. Re-asserting the same one leaves it alone |
  | `Fastory.configure(…)` | When the configuration **differs** from the one in force. The first `configure()` never drops it, so you may set the answer before it |

  After any of them the next question is answered `unavailable` until you set it again. No event
  announces it: all three are calls you just made. `configure()` is deliberately coarse — *any*
  difference drops it, a `theme` switch included — because deciding which parts of a configuration
  your credential depends on would mean reading your credential.
- **A question always gets an answer.** Set nothing and the surface is told so explicitly and falls
  back to anonymous — it is never left waiting, and you handle no timeout.
- **Still no data pushed into your users' pages.** The reply travels back on the platform's own
  return path for the message that asked, so data reaches a page only as the answer to its own
  request. Since 0.5.0 the SDK speaks first in exactly one way: the session-change signal, a
  constant, payload-free event it dispatches in the game pages it owns when the answer they would get
  changes — a session renewed or revoked, a fan identified or signed out, an `identify` that fails
  while a fan is signed in or a reply is set, a value you set or clear with `setBridgeReply`. It
  says *that* the answer changed, never what it became: the game asks again
  and is answered here.
- On Android this channel needs the WebView floor stated under *Requirements*.

## Errors

Every failure crosses the channel as a `PlatformException`; branch on `code`.

| Code | Raised by | Meaning |
|---|---|---|
| `not_configured` | `openGames`, `openMembership`, `identify` | `configure` was never called |
| `publishable_key_required` | `openMembership` | The configuration names a fanzone slug, which names a fanzone and not the workspace this surface is addressed by — *since 0.5.0* |
| `no_activity` | `openGames`, `openMembership` | Android: the plugin has no foreground activity to present from — call it from a visible screen |
| `no_view_controller` | `openGames`, `openMembership` | iOS: the plugin found no visible view controller to present from — call it once your first screen is up |
| `invalid_config` | `configure` | The native side refused a configuration Dart accepted — in practice a `developmentBaseUrl` iOS cannot parse as a URL; every other configuration mistake throws an `ArgumentError` in Dart, see below |
| `identify_mode_unavailable` | `identify` | `fanId` or `hostToken` when you configured with a `fanzoneSlug` instead of a publishable key |
| `invalid_identity_mode` | `identify` | The native side answered with a mode Dart does not know. Never caused by your input — a defect to report |
| `invalid_host_token` | `identify` | The `hostToken` JWT is absent or blank. A malformed or expired one is not caught here — it comes back as `identify_rejected` (the SDK never validates it) |
| `login_cancelled` | `identify` | The fan dismissed the system-browser login (`fanId`) |
| `identify_rejected` | `identify` | The API refused the identity; `details` carry its own code |
| `identify_network_error` | `identify` | The identity could not be reached — nothing was refused |
| `invalid_bridge_reply_payload` | `setBridgeReply` | The payload is neither an object nor `null`, or cannot be serialised to JSON |

Those are the codes a Dart app can receive in this version. `SPEC.md` declares the channel contract —
§ 5.2 the method codes, § 5.4 the identity and bridge failures — and it lists codes this table leaves
out because they cannot reach you today: the Dart types rule them out, or no platform raises them.
`no_activity` and `no_view_controller` are the plugin's own and appear in neither section. Calling
`openGames` while the hub is up is a silent no-op, not an error; calling it while the hub is leaving
opens a new one once it has gone.

A refused `setBridgeReply` leaves the current standing answer untouched. Configuration mistakes the
Dart side can see — no identifier, both identifiers, a key from the wrong environment, a blank
`hubTabSlug`, a `development` environment with no base URL — throw an `ArgumentError` from
`configure()` instead, before the channel.

`Fastory.logout()` never fails.

## Architecture

- Dart ↔ native: `MethodChannel('fastory_sdk')` carrying the eight methods (`configure`, `openGames`,
  `openMembership`, `close`, `identify`, `logout`, `setBridgeReply`, `setHostTokenProvider`) — plus
  `requestHostToken` the other way, native asking Dart for a fresh host token — and
  `EventChannel('fastory_sdk/events')` carrying the eleven events of *Events* above.
- Android: `FastorySdkPlugin` (`com.fastory.sdk.flutter`) delegates to the core classes
  (`com.fastory.sdk`).
- iOS: `FastorySdkPlugin` delegates to the core classes in `ios/Classes/`.

`android/` and `ios/` hold the SDK's native implementation. A Flutter plugin ships its native code as
sources its consumers compile, so the Swift and Kotlin the plugin needs lives inside the package
rather than being resolved as an artifact — see `android/README.md` and `ios/README.md`. Nothing in
either directory is part of the public API: host apps interact only with the Dart surface above.

Two native channels exist for apps that are not Flutter: the Swift core ships as a Swift package
from this repository's root, and the Kotlin core as the Android library `io.fastory:fastory-sdk` on
Maven Central. All three channels are published by the same release and carry the same version.

## Dev loop

The example app under `example/` is a demo club app whose *SDK* tab exercises the whole public
surface. Its native runners are not versioned, so create them first:

```bash
cd example
flutter create --org com.fastory.example --platforms android,ios .
# then apply the minSdk / iOS 15 tweaks described in example/README.md
flutter pub get
flutter run
```
