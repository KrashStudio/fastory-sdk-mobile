# Fastory Mobile SDK — Integration Guide

Audience: host app engineering teams integrating the SDK.
Scope: Fastory Mobile SDK v0.3.0 (ultra-light, WebView-based).

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
5. Any navigation to an origin other than `fanzone.me` opens in the system browser. Closing the sheet returns to the hub; closing the hub returns to your app.

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
      ref: sdk-v0.3.0
```

Then:

```sh
flutter pub get
```

### Native iOS (Swift Package Manager)

In Xcode: *File > Add Package Dependencies…*, enter `https://github.com/KrashStudio/fastory-sdk-mobile`, and pick *Up to Next Major Version*. Or declare it in your own `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/KrashStudio/fastory-sdk-mobile.git", from: "0.3.0")
]
```

Each release carries two tags on the same commit: the bare version, which is the only form SwiftPM resolves, and `sdk-v<version>`, the name the Flutter channel uses.

No extra native setup is required beyond the minimum OS versions above (iOS deployment target 15.0 in your Podfile/Xcode project, `minSdkVersion 24` in your Android Gradle config).

## Integrate in 5 lines

Configure the SDK with the **publishable key** from your workspace settings. Create it with your iOS
bundle identifier and Android package name declared — the key only works for the applications it
lists, so a key created without them refuses every call.

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
| `workspaceId` | `String?` | no | Optional cross-check: a key resolving to another workspace is rejected instead of opening it |
| `theme` | `light` \| `dark` | no | Appearance hint forwarded to the hub and games. Not read by the web side yet |
| `environment` | `FastoryEnvironment` | no (default `production`) | `production` (`https://fanzone.me`), `staging` (`https://staging.fanzone.me`), or `development` (uses `developmentBaseUrl`) |
| `hubTabSlug` | `String` | no (default `"games"`) | The hidden hub tab slug |
| `locale` | `String?` | no | Forwarded to the hub when provided; defaults to the web Fanzone's own locale resolution |
| `developmentBaseUrl` | `String?` | only when `environment == development` | Custom `https` base URL for internal testing; `configure` throws if missing in development |

Public methods:

| Method | Description |
|---|---|
| `Fastory.configure(FastoryConfig)` | Sets the configuration. Call once before any `openGames()`. |
| `Fastory.openGames()` | Presents the full-screen hub view. |
| `Fastory.close()` | Programmatically dismisses the hub (and any open game sheet). |

Under the hood the plugin uses a `MethodChannel` named `fastory_sdk` (`configure`, `openGames`, `close`) and an `EventChannel` named `fastory_sdk/events`.

## Events

The SDK exposes a broadcast stream of lifecycle events:

| Event | Payload | Emitted when |
|---|---|---|
| `hubOpened` | `{fanzoneSlug}` | The hub view is presented |
| `hubClosed` | — | The hub view is dismissed |
| `gameOpened` | `{slug}` | A game sheet is presented |
| `gameClosed` | — | The game sheet is dismissed |
| `externalLink` | `{url}` | A non-fanzone link was handed off to the system browser |

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
    default:
      break;
  }
});
```

The SDK sends no analytics of its own — you own all tracking through this stream.

## Behavior details

### URL interception (URLPolicy)

Every navigation decision is made natively, per URL:

| Rule | Condition | Decision |
|---|---|---|
| 1 | Origin = Fanzone base (or a Fastory stories domain, `story.tl`) AND path starts with `/s/` | Open the game bottom sheet (WebView B) |
| 2 | Origin = Fanzone base, any other path | Allow — navigate inside the current WebView |
| 3 | Any other `http(s)` origin | Open in the system browser |
| 4 | Non-`http(s)` scheme (`mailto:`, `tel:`, `intent:`, `market:`, …) | Hand off to the system (external) |

### Consent

The hub and game URLs carry `consent=0`. The web player reads this as "the host app handles consent",
so it does not show its own cookie banner, and it does not assume analytics consent. If your app runs
its own consent flow and wants Fastory analytics enabled, contact us — a per-session consent value is
on the roadmap.

### Shared cookies

WebView A (hub) and WebView B (game) share the same cookie store, so consent and session state set in the hub are visible to games:

- iOS: both WebViews use the same `WKWebsiteDataStore.default()` and a shared static `WKProcessPool`.
- Android: the global `CookieManager` is used, with `acceptThirdPartyCookies` enabled on both WebViews.

### Android back button

Priority order:

1. If the game sheet is open, close the sheet.
2. Else if WebView A `canGoBack`, `goBack()`.
3. Else close the full-screen view and return to the app.

### Safe areas

The SDK WebViews are laid out **edge-to-edge** (the Fanzone fills the screen top and bottom, no letterboxing); the chromeless Fanzone pads its own content via `env(safe-area-inset-*)` so nothing interactive sits under the notch, Dynamic Island, or gesture bar. Native close affordances (the ✕ button) are inset below the system bars. You do not need to do anything on the app side.

### Offline

If the **hub** fails to load (airplane mode, no network), the SDK shows a native error state with a retry action — no blank white WebView is left on screen. The game sheet has no error view of its own; on failure it simply remains dismissible (swipe down / back).

## FAQ

**Can we use our own in-app WebView policy / browser component?**
No — the two WebViews are owned and configured by the SDK (cookie sharing, URL interception, safe areas depend on it). External links respect the system default browser.

**Do we need ProGuard / R8 rules?**
No custom rules are expected: the SDK uses the platform `android.webkit.WebView` and standard Flutter plugin registration, both covered by default Flutter/AGP keep rules. If your build uses aggressive custom shrinking and you hit an issue, keep the SDK's plugin package and report it to us.

**What does the SDK add to app size?**
It is intentionally ultra-light: Dart plugin glue plus thin native view controllers around system WebViews. No bundled UI frameworks, no analytics libraries, no native third-party dependencies. Expect a negligible footprint (well under 1 MB per platform).

**Will this pass Apple App Store review / TestFlight?**
The SDK displays the partner's own web content (your Fanzone) in a WebView, with no payments, no OAuth, no account creation, and no downloadable code beyond regular web pages. This is standard partner-content embedding. Prize-based games remain subject to the usual App Store Review Guidelines on contests (the contest organizer is the partner/Fastory, not Apple — state this in your contest rules as usual).

**Which environments exist?**
Production (`https://fanzone.me`) and staging (`https://staging.fanzone.me`). A development environment with a configurable base URL (`developmentBaseUrl`) is available for internal testing.

## Known limitations

All of these hold for the version documented above. None has a committed release date — ask us if
one of them blocks you, rather than planning around a version number.

- No authentication / SSO bridge — games run anonymously or with their own web-side identity.
- No SDK-side analytics — use the event stream and your own tracker.
- No JavaScript injection and no `postMessage` bridge between the app and the web content.
- The game sheet has no error view of its own: on a failed load it stays dismissible (swipe down / back).
- Portrait and landscape are supported, but the hub content is designed mobile-first (portrait).
