# fastory_sdk

Flutter plugin of the Fastory Mobile SDK. It opens a Fanzone's games hub in a full-screen native view
(WebView A), each game in a native bottom sheet (WebView B), and any external origin in the system
browser. The real logic is native — this package is a thin bridge over the same Swift and Kotlin cores
the native channels ship.

Scope: Fastory Mobile SDK v0.4.4 (ultra-light, WebView-based).

This file is the Dart reference: every method, event and error the plugin exposes. `README.md` at the
repository root is the full integration guide (it also covers the native iOS channel), and `SPEC.md`
is the normative contract all channels conform to.

## Requirements

- Flutter ≥ 3.10, Dart ≥ 3.0
- iOS 15+ (the host app's Podfile must declare `platform :ios, '15.0'`)
- Android minSdk 24 (the host app must declare `minSdk = 24`)

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
      ref: sdk-v0.4.4
```

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
| `locale` | `String?` | `null` | Forced hub locale; defaults to the web Fanzone's own resolution |
| `theme` | `FastoryTheme?` | `null` | `light` or `dark`, forwarded to the hub and game URLs. The web side does not read it yet, so setting it is inert until it ships there |
| `developmentBaseUrl` | `String?` | `null` | Base URL, required when `environment` is `development` |

Call `configure()` once before `openGames()`. If you call it straight from `main()`, call
`WidgetsFlutterBinding.ensureInitialized()` first so the platform channel has a binding.

Since 0.4.0 `configure()` no longer builds the hub WebView while your app is drawing its first
screen — it waits for the first frame, and warms nothing at all on a background launch. Opening the
hub is as fast as before. A re-`configure()` with a *different* configuration also drops the warm hub,
so the next `openGames()` shows the new fanzone rather than the previous one.

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
carries both channels side by side.

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
| `Fastory.configure(FastoryConfig)` | Sets the configuration. Call once, before anything else |
| `Fastory.openGames()` | Presents the hub full screen. Idempotent since 0.4.0: a call while the hub is up does nothing |
| `Fastory.close()` | Dismisses the game sheet then the hub. No-op if nothing is open |
| `Fastory.identify(FastoryIdentity)` | Binds your user to a Fastory fan. Returns the resolved identity — see *Identity* |
| `Fastory.logout()` | Signs the fan out of Fastory only. Idempotent, and never fails |
| `Fastory.setBridgeReply(type, payload)` | Declares what the SDK answers when a web surface asks — see *Answering the web content* |

```dart
await Fastory.openGames();
await Fastory.close();
```

`openGames()` presents the hub full screen. **It is idempotent since 0.4.0**: called while a hub is
already on screen it does nothing at all — no second hub, and nothing to catch, so a tab-bar entry a
fan double-taps needs no debouncing of its own. You get one `hubOpened` and one `hubClosed` per hub
the SDK presents. Tapping a game (`/s/{slug}`) opens the native bottom sheet
with `embed=1&utm_source=sdk&consent=0`. A `/s/` link on a Fastory stories domain
(`https://story.tl`, `https://staging.story.tl` — both, whichever environment you configured) is a
game too and opens the same sheet. Any other origin, and any non-http(s) scheme (`mailto`, `tel`,
`intent`, `market`), opens in the system browser. On Android the back button
first closes the bottom sheet, then walks the hub WebView history, then closes the view.

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
| `FastoryGameOpened` | `slug` | A game sheet is presented |
| `FastoryGameClosed` | — | The game sheet is dismissed |
| `FastoryExternalLink` | `url` | A non-Fanzone link was handed off to the system browser |
| `FastoryBridgeMessage` | `type`, `payload` | A Fastory web surface posted a message — *since 0.4.0* |
| `FastoryIdentityResolved` | `mode`, `fanId` | `identify` resolved an identity, once per resolution, before any hub or game opening carrying it. `fanId` is null when anonymous — *since 0.4.0* |
| `FastorySurfaceLoadFailed` | `surface`, `reason`, `code`, `statusCode` | A hub or a game did not load — *since 0.4.0* |

`hubOpened` … `hubClosed` bracket every session, and `gameOpened` / `gameClosed` nest inside it. The
SDK sends no analytics of its own — you own all tracking through this stream.

## When a surface does not load (since 0.4.0)

A fanzone that does not exist, a key you revoked, a game that was taken down, a fan in a tunnel: the
SDK shows its own error screen with a Retry button — the game sheet has one too since 0.4.0 —
and tells your app what happened.

- **`surface`** is `FastorySurface.hub` or `FastorySurface.game`.
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
  a refusal is never reported as a blank: `http_<status>` when the refusal named no code of its own,
  and `sdk_application_id_required`
  when the SDK could not read your app's identifier at all and had no well-formed request to send
  (iOS only in practice — an Android package name always exists).

  Anything else appearing here is a bug to report. Nothing answered at all → `code` is
  null, and `reason` says so: an unknown key, a revoked key and a fan with no signal are three different
  situations and only the last is the connection.
- **`statusCode`** is the HTTP status the page itself answered, when the page is what failed.
- **No opening event is emitted for a surface that failed**, and no closing one either: if you count
  `FastoryHubOpened` as a session, a hub that never loaded is not one.
- **The SDK never retries by itself**, and it never reports the same failed load twice. Cancellations
  it performs itself when routing a game or an external link are not failures and are not reported.
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

One method, three mutually-exclusive modes, plus a sign-out. **This API is final** — the two modes
that do not resolve yet are declared with their real signatures, so adopting them later is not a
breaking change for you.

| Mode | What your user does | Available |
|---|---|---|
| `FastoryAnonymous()` | nothing; each surface's page mints its own device visitor | **now** |
| `FastoryFanId()` | signs in to Fastory, in the **system browser** (never in a WebView) | later release |
| `FastoryHostToken(jwt)` | nothing — your backend asserts an identity it already authenticated | later release |

```dart
// Today: the behaviour the SDK has always had, now explicit.
final FastoryResolvedIdentity identity =
    await Fastory.identify(const FastoryAnonymous());

// Later releases, same call site:
// await Fastory.identify(FastoryHostToken(jwtFromYourBackend));

await Fastory.logout();
```

- **`identify(anonymous)` is idempotent.** Calling it twice, or on every launch, gives you the same
  fan. You do not have to call it at all: an app that never does behaves as it did before 0.4.0.
- **The reserved modes reject with `identify_mode_unavailable`** and change nothing about who the fan
  currently is.
- **Failures are typed and never leave the SDK half-identified** — branch on
  `PlatformException.code`, never on the message.
- **`logout()` is Fastory-only, in both directions.** It expires a declared list of Fastory cookies on
  the Fastory origins and deletes their web storage; your own session is never touched. Symmetrically,
  signing a user out of your app does not sign them out of Fastory — call `logout()` for that.
- An identity change drops the warm hub and the preloaded games: they were rendered for the previous
  fan, so the next `openGames()` is a cold open. Since 0.4.0 it drops the standing bridge answer too —
  see *Answering the web content*.

## Bridge messages (since 0.4.0)

A Fastory web surface can send your app a typed message, as `FastoryBridgeMessage` on the event
stream. You enable nothing; no JavaScript is injected into your users' pages.

- **One type exists today:** `fastory:ready` — the embedded surface has rendered. It is a liveness
  signal, not a lifecycle event, and you must not *require* it to arrive: the web side may be deployed
  at a version that never sends it. `FastoryBridgeMessage.knownTypes` holds the registry.
- **Unknown types are dropped**, which is what lets a new type ship later without breaking an app
  already in the stores.
- **These messages travel web → app only.** Nothing you do makes one arrive, and the bridge changes
  nothing about the games flow.

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
- **Still no JavaScript in your users' pages.** The reply travels back on the platform's own return
  path for the message that asked; the SDK never speaks to a page first.
- On Android this channel needs the WebView floor stated under *Requirements*.

## Errors

Every failure crosses the channel as a `PlatformException`; branch on `code`.

| Code | Raised by | Meaning |
|---|---|---|
| `not_configured` | `openGames`, `identify` | `configure` was never called |
| `already_open` | — | Reserved; no platform raises it. Calling `openGames` while the hub is up is a silent no-op, not an error |
| `invalid_config` | `configure`, `openGames` | Malformed configuration (bad URL, empty slug) |
| `identify_mode_unavailable` | `identify` | The mode is reserved in this version (`fanId`, `hostToken`) |
| `invalid_identity_mode` | `identify` | The mode is not one of the three names |
| `invalid_host_token` | `identify` | The `hostToken` JWT is absent, blank, malformed or expired |
| `login_cancelled` | `identify` | The fan dismissed the system-browser login (`fanId`) |
| `identify_rejected` | `identify` | The API refused the identity; `details` carry its own code |
| `identify_network_error` | `identify` | The identity could not be reached — nothing was refused |
| `invalid_bridge_request_type` | `setBridgeReply` | The type is not in the request registry |
| `invalid_bridge_reply_payload` | `setBridgeReply` | The payload is neither an object nor `null`, or cannot be serialised to JSON |

A refused `setBridgeReply` leaves the current standing answer untouched. Configuration mistakes the
Dart side can see — no identifier, both identifiers, a key from the wrong environment, a blank
`hubTabSlug`, a `development` environment with no base URL — throw an `ArgumentError` from
`configure()` instead, before the channel.

`Fastory.logout()` never fails.

## Architecture

- Dart ↔ native: `MethodChannel('fastory_sdk')` carrying the six methods (`configure`, `openGames`,
  `close`, `identify`, `logout`, `setBridgeReply`) and `EventChannel('fastory_sdk/events')` carrying
  the eight events of *Events* above.
- Android: `FastorySdkPlugin` (`com.fastory.sdk.flutter`) delegates to the core classes
  (`com.fastory.sdk`).
- iOS: `FastorySdkPlugin` delegates to the core classes in `ios/Classes/`.

`android/` and `ios/` hold the SDK's native implementation. A Flutter plugin ships its native code as
sources its consumers compile, so the Swift and Kotlin the plugin needs lives inside the package
rather than being resolved as an artifact — see `android/README.md` and `ios/README.md`. Nothing in
either directory is part of the public API: host apps interact only with the Dart surface above.

The native iOS channel exists for apps that are not Flutter: the same cores ship as a Swift package
from this repository's root. Both channels are published from the same commit and carry the same
version.

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
