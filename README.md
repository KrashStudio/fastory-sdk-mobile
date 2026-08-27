# Fastory Mobile SDK — Integration Guide

Audience: host app engineering teams integrating the SDK.
Scope: Fastory Mobile SDK v0.4.0 (ultra-light, WebView-based).

Two ways to consume it, same behavior and same version:

| Channel | For | How |
|---|---|---|
| **Flutter plugin** | Flutter apps | git dependency on this repo, `path: flutter/fastory_sdk` |
| **Swift package** | Native iOS apps | Swift Package Manager, this repo's root package |

A native Kotlin artifact on Maven Central follows. The real logic is native in both channels — the
Flutter plugin is a thin bridge over the same Swift and Kotlin cores.

## Overview

The SDK opens the Fastory games hub of your Fanzone inside your app, in five steps:

1. Your app calls `Fastory.openGames()` (e.g. from your footer tab).
2. The SDK presents a full-screen native view containing **WebView A**, which loads the hub — a hidden tab of your Fanzone: `https://fanzone.me/your-fanzone?tab=games&chrome=0&consent=0`.
3. The user taps a game image. The hub triggers `window.open(url)`; the SDK intercepts the navigation natively.
4. The SDK presents a native bottom sheet ("toaster") containing **WebView B**, which loads the game: `https://fanzone.me/s/{slug}?embed=1&utm_source=sdk&consent=0`.
5. Any navigation to an origin other than `fanzone.me` opens in the system browser — except a `/s/` link on a Fastory stories domain, which is a game and opens in the sheet like step 4 (see *URL interception* below). Closing the sheet returns to the hub; closing the hub returns to your app.

```
+---------------------------------------------------------------+
|                        Your Flutter app                       |
|                                                               |
|   footer tap --> Fastory.openGames()                          |
|                        |                                      |
|                        v                                      |
|   +-------------------------------------------------------+   |
|   |            Full-screen native view                    |   |
|   |   WebView A (hub)                                     |   |
|   |   fanzone.me/your-fanzone?tab=games&chrome=0          |   |
|   |                                                       |   |
|   |   tap game image (window.open)                        |   |
|   |            |                                          |   |
|   |            |  intercepted natively (URLPolicy)        |   |
|   |            v                                          |   |
|   |   +-----------------------------------------------+   |   |
|   |   |   Native bottom sheet ("toaster")             |   |   |
|   |   |   WebView B (game)                            |   |   |
|   |   |   fanzone.me/s/{slug}?embed=1&utm_source=sdk  |   |   |
|   |   +-----------------------------------------------+   |   |
|   +-------------------------------------------------------+   |
|                                                               |
|   any non-fanzone.me origin ------> system browser            |
+---------------------------------------------------------------+
```

## Prerequisites

- iOS 15.0+ (deployment target)
- Android minSdk 24
- Flutter >= 3.10.0 (Dart >= 3.0) — Flutter channel only

## Install

### Flutter

Add the SDK as a git dependency in your `pubspec.yaml`, pinned to a release tag:

```yaml
dependencies:
  fastory_sdk:
    git:
      url: https://github.com/KrashStudio/fastory-sdk-mobile
      path: flutter/fastory_sdk
      ref: sdk-v0.4.0
```

Then:

```sh
flutter pub get
```

### Native iOS (Swift Package Manager)

In Xcode: *File > Add Package Dependencies…*, enter `https://github.com/KrashStudio/fastory-sdk-mobile`, and pick *Up to Next Major Version*. Or declare it in your own `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/KrashStudio/fastory-sdk-mobile.git", from: "0.4.0")
]
```

Each release carries two tags on the same commit: the bare version, which is the only form SwiftPM resolves, and `sdk-v<version>`, the name the Flutter channel uses.

No extra native setup is required beyond the minimum OS versions above (iOS deployment target 15.0 in your Podfile/Xcode project, `minSdkVersion 24` in your Android Gradle config).

## Upgrading from 0.3.0: three source breaks

Everything specified since 0.3.0 ships as 0.4.0, so all three arrive in one upgrade. Nothing else in this release asks anything of you.

**1. Dart: `FastoryEvent` gains three subtypes.** It is `sealed`, so an exhaustive `switch` with **no** `default:` stops compiling until you add a case for **all three** — `FastoryBridgeMessage`, `FastoryIdentityResolved` and `FastorySurfaceLoadFailed`. See *Events* below. The two native surfaces are unaffected — each new callback has a no-op default, so an existing delegate or listener keeps compiling.

**2. Android: an `androidx.webkit` dependency and a WebView floor.** The reply channel needs the one Android API that reports which frame posted a message and from which origin, because a reply carries a fan credential. Below that API (Chrome 85, mid-2020) the reply channel is simply absent and the surface stays anonymous. Nothing to change in your code. See *Known limitations*.

**3. `workspaceId` is gone from the configuration.** Delete the argument if you pass it — there is nothing to replace it with. It was an optional cross-check against the workspace your publishable key resolves to, and a key resolves exactly one workspace, so it asked you to confirm what the key already settles. What stops a key opening a workspace it does not belong to is the exchange being bound to your application identifier, which the API refuses unless the owning workspace declared it on that key (`sdk_application_not_allowed`). That refusal is unconditional, so nothing the field protected is now unprotected.

## Integrate in 5 lines

Configure the SDK with the **publishable key** from your workspace settings. Create it with your iOS
bundle identifier and Android package name declared — the key only works for the applications it
lists, so a key created without them refuses every call.

> **The Mobile SDK add-on must be active on your workspace.** Without it the key screen presents the
> feature instead of listing your keys, and creating, listing or revoking one answers
> `403 sdk_addon_required`. Ask your Fastory contact to enable it. The add-on gates management only:
> a key already shipped in an app keeps resolving even if the add-on is later removed, so losing it
> never cuts an app in the field.

`fanzoneSlug` still works and will keep working for the whole 0.x line, but it is deprecated: prefer
the key.

> **Availability of the key exchange.** The endpoint the key is exchanged at is live on **staging**
> today and reaches production later. Integrate against `environment: staging` with an `fpk_test_…`
> key, which works now. If you have to ship to production before it deploys, configure with the
> deprecated `fanzoneSlug` instead — that path calls no endpoint at all and is unaffected. An
> `fpk_live_…` key pointed at production ahead of the deployment resolves nothing, so `openGames()`
> lands on the hub's error view rather than the games.

### Flutter

Configure once in `main()`, open from anywhere (e.g. your footer):

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

// In your footer tap handler:
onTap: () => Fastory.openGames(),
```

### Native iOS

Configure at launch, then present from the view controller of your choice:

```swift
import FastorySDK

// In your App / AppDelegate:
Fastory.configure(FastoryConfig(publishableKey: "fpk_live_...", theme: .dark))

// From your games tab or button:
Fastory.openGames(from: presentingViewController)
```

The Swift API takes the presenter explicitly (`openGames(from:)`) and delivers lifecycle events through `Fastory.eventsDelegate`, a `FastoryEventsDelegate`. Each channel follows its own platform idiom rather than a lowest-common-denominator signature — the behavior behind them is identical.

## Configuration reference

`FastoryConfig`:

| Field | Type | Required | Description |
|---|---|---|---|
| `publishableKey` | `String` | one of the two | Your workspace publishable key, `fpk_live_…` in production, `fpk_test_…` elsewhere |
| `fanzoneSlug` | `String` | one of the two | **Deprecated.** Your Fanzone slug, e.g. `"your-fanzone"` — still accepted for the whole 0.x line |
| `theme` | `light` \| `dark` | no | Appearance hint forwarded to the hub and games. Not read by the web side yet |
| `environment` | `FastoryEnvironment` | no (default `production`) | `production` (`https://fanzone.me`), `staging` (`https://staging.fanzone.me`), or `development` (uses `developmentBaseUrl`) |
| `hubTabSlug` | `String` | no (default `"games"`) | The hidden hub tab slug |
| `locale` | `String?` | no | Forwarded to the hub when provided; defaults to the web Fanzone's own locale resolution |
| `developmentBaseUrl` | `String?` | only when `environment == development` | Custom `https` base URL for internal testing; `configure` throws if missing in development |

Public methods:

| Method | Description |
|---|---|
| `Fastory.configure(FastoryConfig)` | Sets the configuration. Call once before anything else. |
| `Fastory.openGames()` | Presents the full-screen hub view. Idempotent: a call while the hub is up does nothing. |
| `Fastory.close()` | Programmatically dismisses the hub (and any open game sheet). |
| `Fastory.identify(FastoryIdentity)` | Binds your user to a Fastory fan. See *Identity* below. |
| `Fastory.logout()` | Signs the fan out of Fastory. Never touches your own session. |
| `Fastory.setBridgeReply(type, payload)` | Declares what the SDK answers when an embedded surface asks. See *Answering the web content* below. |

**Threading (since 0.4.0).** Every method above may be called from any thread except `openGames()`,
which needs the main thread — it takes your own `UIViewController` / `Context`, so you are already in
UI code when you call it. `configure()` in particular is safe from a background bootstrap: it stores
your configuration before returning and schedules its own WebView work on the main thread. Every
callback and event still arrives on the main thread. `SPEC.md` § 2.7 is the normative table. From
Flutter this is nothing you have to think about: platform-channel calls already land on the platform
thread.

**Opening twice (since 0.4.0).** `openGames()` is idempotent: called while a hub is already on
screen it does nothing at all — no second hub, and no error to catch. You get one `hubOpened` and one
`hubClosed` per hub your fan actually sees, so a tab-bar entry a fan double-taps needs no debouncing
of its own. On Android this used to stack two hub `Activity` instances, which also made `close()`
return the fan to the hub underneath instead of to your app. `SPEC.md` § 2.1 is the normative rule.

**Startup cost (since 0.4.0).** `configure()` no longer builds the hub WebView while your app is
drawing its first screen — it waits for the first frame, and warms nothing at all on a background
launch. Opening the hub is as fast as before.

Under the hood the plugin uses a `MethodChannel` named `fastory_sdk` (`configure`, `openGames`, `close`, `identify`, `logout`, `setBridgeReply`) and an `EventChannel` named `fastory_sdk/events`.

## Identity

One method, three mutually-exclusive modes, plus a sign-out. **This surface is final** — the two modes
that do not resolve yet are declared with their real signatures so that adopting them later is not a
breaking change for you.

| Mode | What your user does | Available |
|---|---|---|
| `FastoryAnonymous()` | nothing; they are not recognised | **now** |
| `FastoryFanId()` | signs in to Fastory, in the **system browser** (never in a WebView) | later release |
| `FastoryHostToken(jwt)` | nothing — your backend asserts the identity it already authenticated | later release |

```dart
// Today: the behaviour the SDK has always had, now explicit.
await Fastory.identify(const FastoryAnonymous());

// Later releases, same call site:
// await Fastory.identify(const FastoryHostToken(jwtFromYourBackend));

await Fastory.logout();
```

What is worth knowing before you wire it up:

- **`identify(anonymous)` is idempotent.** Calling it twice, or on every app launch, gives you the
  same fan — it is a no-op when the SDK is already anonymous. Calling it is safe anywhere.
- **You do not have to call it at all.** An app that never calls `identify` behaves exactly as it did
  before 0.4.0.
- **`hostToken` opens no browser.** It is the mode where the fan types nothing: you pass a JWT your
  own backend signed, and Fastory verifies it server-side. `fanId` is the opposite — it is a login,
  so it carries no argument and the credentials are typed in the system browser (the only path that
  reaches the device's password manager).
- **Failures are typed and leave a clean state.** `identify` rejects with a `PlatformException` whose
  `code` you branch on — `identify_mode_unavailable` for a reserved mode, `not_configured` if
  `configure` has not run, `invalid_host_token` for a malformed JWT. It never leaves the SDK
  half-identified.
- **`logout()` is Fastory-only, in both directions.** It clears the Fastory session on the Fastory
  domains and nothing else; and signing your user out of your own app does not sign them out of
  Fastory, so call `logout()` when that happens.
- An identity change drops the warm hub and the preloaded games, since they were rendered for the
  previous fan. The next `openGames()` after a `logout()` is a cold open.

## Events

The SDK exposes a broadcast stream of lifecycle events:

| Event | Payload | Emitted when |
|---|---|---|
| `hubOpened` | `{fanzoneSlug}` | The hub view is presented |
| `hubClosed` | — | The hub view is dismissed |
| `gameOpened` | `{slug}` | A game sheet is presented |
| `gameClosed` | — | The game sheet is dismissed |
| `externalLink` | `{url}` | A non-fanzone link was handed off to the system browser |
| `bridgeMessage` | `{type, payload}` | A Fastory web surface posted a message through the bridge (see below) |
| `identityResolved` | `{mode, fanId}` | `identify` resolved an identity — once per resolution, before any hub or game opening carrying it. `fanId` is null when anonymous |
| `surfaceLoadFailed` | `{surface, reason, code, statusCode}` | A hub or a game did not load (see below) |

Events are Dart sealed classes — switch over the event instance:

```dart
Fastory.events.listen((FastoryEvent event) {
  switch (event) {
    case FastoryHubOpened(:final fanzoneSlug):
      analytics.track('Fastory Hub Opened', properties: {'fanzone': fanzoneSlug});
    case FastoryGameOpened(:final slug):
      analytics.track('Fastory Game Opened', properties: {'slug': slug});
    case FastoryExternalLink(:final url):
      analytics.track('Fastory External Link', properties: {'url': url});
    case FastoryIdentityResolved(:final mode, :final fanId):
      analytics.identify(fanId, properties: {'fastoryMode': mode.name});
    default:
      break;
  }
});
```

The SDK sends no analytics of its own — you own all tracking through this stream.

`FastoryEvent` is `sealed`, so an exhaustive `switch` with **no** `default:` stops compiling when a
release adds an event — 0.4.0 adds three, `FastoryBridgeMessage`, `FastoryIdentityResolved` and
`FastorySurfaceLoadFailed`. Keeping the `default: break;` above, as this example does, makes your
call site forward-compatible; dropping it means you get a compile error instead of silently ignoring
a new event. Both are reasonable; pick deliberately.

## When a surface does not load (since 0.4.0)

A fanzone that does not exist, a key you revoked, a game that was taken down, a fan in a tunnel: the
SDK shows its own error screen with a Retry button, and tells your app what happened.

```dart
Fastory.events.listen((FastoryEvent event) {
  if (event case FastorySurfaceLoadFailed(:final surface, :final reason, :final code)) {
    switch (reason) {
      case FastoryLoadFailureReason.network:
        // Nothing answered. Usually the fan's connection, not you.
        break;
      case FastoryLoadFailureReason.rejected:
        // Something answered and refused. `code` is the API's when your key was refused —
        // `sdk_key_unknown`, `sdk_key_revoked`, and the rest of the table below — and
        // `statusCode` is the page's HTTP status when the page itself failed.
        alerting.warn('Fastory refused ${surface.name}: ${code ?? 'HTTP error'}');
      case FastoryLoadFailureReason.unknown:
        break;
    }
  }
});
```

What to know:

- **`surface` is `FastorySurface.hub` or `FastorySurface.game`** — which of the two did not load.
- **Branch on `reason`, read `code` and `statusCode` for the cause.** `rejected` means something
  answered and refused; `network` means nothing answered; `unknown` is everything else. Three cases
  on purpose, so "is Fastory reachable?" does not require you to enumerate every code we may add.
- **`code` appears only when your publishable key was refused**, and it is the one field worth
  alerting on: it means a configuration problem on your side or ours, not a flaky connection. Only
  six things can appear there: four names from our API, one the SDK mints, and the `http_<status>`
  family. Cover those and you have covered the field. The four from our API:

  | `code` | HTTP | What it means for you |
  |---|---|---|
  | `sdk_key_unknown` | 401 | We know no such key. Not only a typo in a build you never shipped: a key **deleted** in the back-office, and a workspace that no longer exists, both land here — so an app already in the field can meet it after a change it never saw. Ask us to re-issue a key; nothing in your app will fix it. |
  | `sdk_key_revoked` | 403 | The key existed and was withdrawn. A different back-office fact from the row above — keep them apart in your alerting, or a deleted key gets chased as a revoked one. |
  | `sdk_application_not_allowed` | 403 | The key is fine; this bundle identifier / package name is not declared on it. A debug build with an `applicationIdSuffix` is the usual cause. |
  | `sdk_rate_limited` | 429 | Too many exchanges from this key or this address. **Back off — do not retry in a loop.** A single burst clears on its own, but the third sanction adds your address to a block list **with no expiry**, and every later exchange from it answers this same code until we lift it by hand. Looping is what earns the permanent form. Surface it rather than absorb it, and tell us if it persists. |

  **The other two the SDK mints itself**, so that a refusal is never reported as a blank:
  `http_<status>` when the refusal named no code of its own (a proxy in front of our API, typically),
  and `sdk_application_id_required` when the SDK could not read your app's identifier at all and so
  had no well-formed request to send — iOS only in practice, since an Android package name always
  exists. Those six are the whole of it; treat anything else in `code` as a bug to report. When
  nothing answered at all, `code` is null and `reason` is what tells you — **an unknown key, a
  revoked key and a fan with no signal are three different situations**, and only the third is the
  fan's connection.
- **No opening event is emitted for a surface that failed**, and no closing event either. If you count
  `hubOpened` as a session, a failed hub is not one — and `hubOpened` … `hubClosed` still pair up.
- **The SDK never retries by itself.** The fan has a Retry button; your app decides everything else.
- **Retry does not recover a refused publishable key** — the one place the button falls short, so
  plan around it rather than discovering it. Retry reloads the page that failed, and a key the API
  refused never produced one: the SDK remembers the exchange's outcome for the configuration that
  asked for it, failure included, and shows the same error again without calling the API twice. A page
  that failed on its own (a 404, a connection dropped mid-load) *does* reload, and so does everything
  on the deprecated `fanzoneSlug` path. To recover from a transient failure of the **exchange**, call
  `configure()` again from your `FastorySurfaceLoadFailed(surface: hub)` handler — **any second call
  re-arms it, on both platforms**, and the configuration you pass may be the one already in force.
  You do not have to vary it to force the retry. **What you cannot count on is the very next open**:
  on Android an equal `configure()` leaves the previous failure readable until the new exchange
  answers, so an open that starts inside that window is answered from it and the recovery lands on
  the one after. Re-configure from the handler, then let the fan open again when they choose to.
  Tracked as FASTORY-2904; `SPEC.md` § 9 and § 2.1 carry the normative version.
- **You will not get noise.** A failed image or XHR inside a page is not reported, and neither are the
  navigation cancellations the SDK performs itself every time it routes a game or an external link.
  One failed load is one event.

## Bridge messages (since 0.4.0)

A Fastory web surface can send your app a typed message. You receive it as an event; you never have
to call anything to enable it.

```dart
Fastory.events.listen((FastoryEvent event) {
  if (event case FastoryBridgeMessage(:final type, :final payload)) {
    debugPrint('Fastory said $type with $payload');
  }
});
```

What to know before you build on it:

- **One type exists today:** `fastory:ready` — the embedded Fastory surface has rendered. It is a
  liveness signal, not a lifecycle event: `hubOpened` / `gameOpened` remain the source of truth for
  what is on screen, and you must not *require* `fastory:ready` to arrive, because the web side may
  be deployed at a version that never sends it. It is sent when the page's own render commits, not
  once the surface has painted — fonts, images and data-driven blocks may still be resolving — so
  dismissing a native splash screen on it can uncover a surface that is not finished drawing.
- **These messages travel web → app only.** They are notifications, and nothing you do makes one
  arrive. The other direction is *answering* — see the next section.
- **Unknown message types are dropped.** That is what lets us ship a new message type later without
  breaking an app already in the stores — your build keeps working, it just does not see it.
- **The bridge changes nothing about the games flow.** Games still open through native URL
  interception; external links still leave for the system browser. A message never substitutes for
  either.

The normative envelope, the type registry and the JavaScript entry points are in `SPEC.md` § 13.

## Answering the web content (since 0.4.0)

A Fastory web surface can also **ask** your app something, and the SDK answers on its behalf. You
declare the answer up front; nothing is asked of you at the moment the question arrives.

```dart
// Before opening a game — typically right after you have obtained the fan's token.
await Fastory.setBridgeReply(
  FastoryBridgeRequestType.userToken,
  <String, Object?>{'token': fanToken},
);

// Signing out? `logout()` already drops it — this is for the cases where you sign the fan out of
// Fastory without calling it.
await Fastory.setBridgeReply(FastoryBridgeRequestType.userToken, null);
```

Why this exists: a Fastory game normally asks the page that embeds it who the fan is. Opened through
the SDK there is no such page — the game *is* the top-level document — so without an answer every
game session is anonymous. `setBridgeReply` is how your app stands in for the missing page.

What to know before you build on it:

- **One request type exists today:** `FastoryBridgeRequestType.userToken`. It is an enum rather than a
  string on purpose — you cannot name a type the SDK does not serve.
- **A question always gets an answer.** If you have set nothing, the surface is told so explicitly and
  falls back to anonymous. It is never left waiting, and you never have to handle a timeout.
- **Set it before `openGames()`.** The game asks while it is loading, so an answer that arrives later
  arrives too late for that session.
- **The SDK drops it when the fan changes, and you have to set it again** (since 0.4.0). The value is
  a credential, so it does not outlive what justified it. Three calls revoke it:

  | Call | When it revokes |
  |---|---|
  | `Fastory.logout()` | Always — including when you never called `identify()` |
  | `Fastory.identify(…)` | Only when it resolves a **different** fan. Re-asserting the same one leaves it alone |
  | `Fastory.configure(…)` | When the configuration **differs** from the one in force. The first `configure()` never revokes, so you may set the answer before it |

  After any of those, the next question is answered `unavailable` until you call `setBridgeReply`
  again. The SDK emits no event for this: all three are calls you just made, so nothing has happened
  that you could not predict. `configure()` is deliberately coarse — *any* difference revokes, a
  `theme` switch included — because deciding which parts of a configuration your credential depends
  on would mean reading your credential.
- **The SDK does not read your payload**, and the web side verifies the token on our servers before
  trusting anything in it. Setting a reply is an assertion, not a login.
- **Still no JavaScript in your users' pages.** The answer goes back through the platform's own return
  path for the message that asked. The SDK never speaks to a page first.

The normative request and reply envelopes, the registry and the origin rules are in `SPEC.md` § 13.8.

## Behavior details

### URL interception (URLPolicy)

Every navigation decision is made natively, per URL:

| Rule | Condition | Decision |
|---|---|---|
| 1 | Origin = Fanzone base, **or** a Fastory stories domain (`https://story.tl` or `https://staging.story.tl` — both, whichever environment you configured) AND path starts with `/s/` | Open the game bottom sheet (WebView B) |
| 2 | Origin = Fanzone base, any other path | Allow — navigate inside the current WebView |
| 3 | Any other `http(s)` origin | Open in the system browser |
| 4 | Non-`http(s)` scheme (`mailto:`, `tel:`, `intent:`, `market:`, …) | Hand off to the system (external) |

### Consent

The hub and game URLs carry `consent=0`. The web player reads this as "the host app handles consent",
so it does not show its own cookie banner, and it does not assume analytics consent. If your app runs
its own consent flow and wants Fastory analytics enabled, contact us — a per-session consent value is
on the roadmap.

### Sessions and stored data

The hub and the games are **different sites** (`fanzone.me` and `story.tl`), so they do not share a
session, and no store configuration can make them: the hub reads a cookie, and a game loaded with
`embed=1` reads no storage at all. Each surface keeps its own persisted state across `openGames()`
sessions and app restarts.

Releases up to 0.3.0 documented the opposite — that the game inherited the hub's session through a
shared cookie store. That was wrong and is withdrawn in 0.4.0 (`SPEC.md` § 7, rewritten). If you read
it as "games already know who the fan is", use `Fastory.identify(...)` instead (see *Identity* above).

- iOS: both WebViews use `WKWebsiteDataStore.default()`. No shared `WKProcessPool` — it has had no
  effect since iOS 15.
- Android: the process-global `CookieManager`, with `acceptThirdPartyCookies` enabled on both WebViews.

Both of those stores are **shared with your app**, which is why the SDK never calls a "clear
everything" API. `logout()` expires a declared list of Fastory cookies on the Fastory origins and
deletes their web storage, and touches nothing else — see `SPEC.md` § 7.4.

### Android back button

Priority order:

1. If the game sheet is open, close the sheet.
2. Else if WebView A `canGoBack`, `goBack()`.
3. Else close the full-screen view and return to the app.

### Safe areas

The SDK WebViews are laid out **edge-to-edge** (the Fanzone fills the screen top and bottom, no letterboxing); the chromeless Fanzone pads its own content via `env(safe-area-inset-*)` so nothing interactive sits under the notch, Dynamic Island, or gesture bar. Native close affordances (the ✕ button) are inset below the system bars. You do not need to do anything on the app side.

### Offline

If a surface fails to load (airplane mode, no network, a page that answers an error), the SDK shows a native error state with a retry action — no blank white WebView is left on screen. **Since 0.4.0 the game sheet has the same error view**, and both surfaces report the failure to your app as `FastorySurfaceLoadFailed` (see *When a surface does not load*).

## FAQ

**Can we use our own in-app WebView policy / browser component?**
No — the two WebViews are owned and configured by the SDK (URL interception, safe areas, and the scoped session erasure of `logout()` all depend on it). External links respect the system default browser.

**Do we need ProGuard / R8 rules?**
No. The SDK ships its own keep rule (`consumerProguardFiles`), so the bridge's JavaScript entry point survives shrinking even if your R8 configuration is hand-written rather than based on AGP's defaults. Everything else it uses — the platform `android.webkit.WebView`, standard Flutter plugin registration — is covered by default Flutter/AGP rules. If your build uses aggressive custom shrinking and you still hit an issue, keep the SDK's plugin package and report it to us.

**What does the SDK add to app size?**
It is intentionally ultra-light: Dart plugin glue plus thin native view controllers around system WebViews. No bundled UI frameworks, no analytics libraries, no native third-party dependencies. Expect a negligible footprint (well under 1 MB per platform).

**Will this pass Apple App Store review / TestFlight?**
The SDK displays the partner's own web content (your Fanzone) in a WebView, with no payments, no OAuth, no account creation, and no downloadable code beyond regular web pages. This is standard partner-content embedding. Prize-based games remain subject to the usual App Store Review Guidelines on contests (the contest organizer is the partner/Fastory, not Apple — state this in your contest rules as usual).

**Which environments exist?**
Production (`https://fanzone.me`) and staging (`https://staging.fanzone.me`). A development environment with a configurable base URL (`developmentBaseUrl`) is available for internal testing.

**Which hosts does the SDK contact? (network allow-lists)**
Three kinds, and the API one is the one people miss:

| What | Production | Staging | `development` |
|---|---|---|---|
| Fanzone (the hub) | `https://fanzone.me` | `https://staging.fanzone.me` | your `developmentBaseUrl` |
| API (the publishable-key exchange only) | `https://api.fastory.io` | `https://api.staging.fastory.io` | your `developmentBaseUrl` |

Plus the two **stories** hosts the games are served from, `https://story.tl` and
`https://staging.story.tl` — a fixed pair rather than an environment split, in every environment,
because a game link is whatever the fanzone page put on the tile. That is also why a `/s/` link to
either one opens in the game sheet whichever environment you configured (`SPEC.md` § 4, rule 1).

The API host is reached **only** on the publishable-key path, once per configuration, at
`POST /sdk/auth/bootstrap`. Configured with the deprecated `fanzoneSlug` the SDK calls no endpoint at
all. Anything else your fan reaches through a hub tile leaves for the system browser and is not the
SDK's traffic.

## Known limitations

All of these hold for the version documented above. None has a committed release date — ask us if
one of them blocks you, rather than planning around a version number.

- Of the three identity modes, only `FastoryAnonymous()` resolves today (see *Identity*). Until the
  other two ship, a fan is anonymous on both surfaces — which also means a game they play credits no
  points to an account.
- No SDK-side analytics — use the event stream and your own tracker.
- No JavaScript injection. The bridge carries one notification type and answers one question type —
  there is no API to *push* into the web content unprompted, and no haptics or share hooks.
- On Android the reply channel needs a WebView from Chrome 85 (mid-2020) or later. Below that it is
  simply absent and surfaces stay anonymous; nothing else about the SDK is affected.
- The SDK never retries a failed load by itself. It shows an error view with Retry and reports the
  failure (`FastorySurfaceLoadFailed`); any automatic retry policy is yours to implement. **And that
  Retry does not re-run a refused publishable-key exchange** — see *When a surface does not load*
  above for the shape and the workaround (FASTORY-2904).
- **Two build-time warnings you will see and can ignore, on the Flutter channel.** Neither breaks the
  build and neither has a workaround on your side:
  - `flutter build apk` prints *"Your app uses the following plugins that apply Kotlin Gradle Plugin
    (KGP): fastory_sdk … upgrade to a version that supports Built-in Kotlin"*. Flutter has dated the
    deprecation; the plugin will move before it becomes an error (FASTORY-2987).
  - `flutter build ios` prints *"Plugin fastory_sdk does not have Swift Package Manager support for
    ios"* and falls back to CocoaPods, which succeeds. This is about the **plugin's** iOS side only —
    the native Swift channel described under *Install* is a real SwiftPM package and resolves normally
    (FASTORY-2939).
- **One runtime console warning on iOS, also harmless.** Calling `openGames(from:)` from a SwiftUI
  tab-bar action logs `Unbalanced calls to begin/end appearance transitions for
  <SwiftUI.TabHostingController: …>` once — UIKit noticing that a presentation started while the tab
  transition was still settling. The hub opens, your selection stays where it was, and nothing else
  is affected; presenting from a plain button does not produce it. Tracked as FASTORY-2988 (observed
  on iOS 26.5). It is ours to fix, so you are not expected to do anything — though if the line
  bothers your logs, deferring the call by one runloop tick
  (`DispatchQueue.main.async { Fastory.openGames(from: …) }`) lets the tab transition settle first.
  Worth knowing before you spend an afternoon on it.
- Portrait and landscape are supported, but the hub content is designed mobile-first (portrait).
