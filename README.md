# Fastory Mobile SDK — Integration Guide

Audience: host app engineering teams integrating the SDK.
Scope: Fastory Mobile SDK v0.5.0 (ultra-light, WebView-based).

Two ways to consume it, same behavior and same version:

| Channel | For | How |
|---|---|---|
| **Flutter plugin** | Flutter apps | git dependency on this repo, `path: flutter/fastory_sdk` |
| **Swift package** | Native iOS apps | Swift Package Manager, this repo's root package |

A native Android app has no channel of its own yet, and no supported path in the meantime: the Kotlin
core ships only inside the Flutter plugin, for Flutter apps, and embedding it any other way is
neither documented nor tested here. A native Kotlin artifact on Maven Central follows, with no date
attached — if a native Android integration is what blocks you, ask us rather than planning around a
version number (see *Known limitations*). The real logic is native in both channels — the Flutter
plugin is a thin bridge over the same Swift and Kotlin cores.

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
      ref: sdk-v0.5.0
```

Then:

```sh
flutter pub get
```

### Native iOS (Swift Package Manager)

In Xcode: *File > Add Package Dependencies…*, enter `https://github.com/KrashStudio/fastory-sdk-mobile`, and pick **Up to Next Minor Version**. Or declare it in your own `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/KrashStudio/fastory-sdk-mobile.git", .upToNextMinor(from: "0.5.0"))
]
```

**Pick the minor rule, not *Up to Next Major Version*, for the whole 0.x line.** SwiftPM's `from:` means *at least this version, and anything below 1.0.0* — it gives a leading zero no special meaning, unlike Cargo's or npm's caret, so it is a range across every future minor. This SDK ships source breaks in minors while it is on 0.x: *Upgrading from 0.3.0* below lists three that arrived in 0.4.0, one of which deletes a configuration field your code passes. *Up to Next Major Version* accepts all of that without asking you. The minor rule accepts patch releases — bug fixes, no API change — and stops there.

The two channels are not identical on this point, and it is worth knowing which you have: the Flutter snippet above pins one immutable tag, so it never moves until you edit it, while the rule here still takes a patch release on its own. If you want the Swift channel to behave exactly like the Flutter one, use SwiftPM's `exact:` requirement with the same version, or *Exact Version* in Xcode.

Each release carries two tags on the same commit: the bare version, which is the only form SwiftPM resolves, and `sdk-v<version>`, the name the Flutter channel uses.

No extra native setup is required beyond the minimum OS versions above (iOS deployment target 15.0 in your Podfile/Xcode project, `minSdkVersion 24` in your Android Gradle config).

## Upgrading from 0.4.x: three source breaks

0.5.0 adds `openMembership()` and its own pair of events. No name you already call moves, nothing changes signature and nothing is removed — but two public types gain cases, and an exhaustive `switch` over either stops compiling until you add them.

**1. `FastorySurface` gains `membership`, on all three channels.** Read this one first: it is a plain public enum on Swift and Kotlin as well as in Dart, so a `switch` or a `when` used as an expression that already covers `hub` and `game` stops compiling there too — this minor is *not* additive for a native host. Add the case, or an `else` / `default:` branch. You meet this type on one event only, `FastorySurfaceLoadFailed`, which now also reports a membership panel that did not load; a host that never inspects a failed load has nothing to change.

**2. Dart: `FastoryEvent` gains `FastoryMembershipOpened` and `FastoryMembershipClosed`.** Same `sealed` rule as 0.4.0, two cases this time. The two native listeners stay additive — each new callback has a no-op default, so an existing delegate or listener keeps compiling.

**3. Nothing else.** `openMembership()` is a call you add when you want the panel, not a migration: it needs the publishable key you already configure with, and nothing else in 0.5.0 asks anything of you. If you add it, consider adding `membership` to `prewarm` too, so its first opening is as instant as the hub's — the SDK prepares the hub alone unless told otherwise (see *Preparing the panel ahead of time*).

## Upgrading from 0.3.0: three source breaks

Everything specified since 0.3.0 ships as 0.4.0, so all three arrive in one upgrade. Nothing else in this release asks anything of you.

**1. Dart: `FastoryEvent` gains three subtypes.** It is `sealed`, so an exhaustive `switch` with **no** `default:` stops compiling until you add a case for **all three** — `FastoryBridgeMessage`, `FastoryIdentityResolved` and `FastorySurfaceLoadFailed`. See *Events* below. The two native API surfaces are unaffected by this break — each new callback has a no-op default, so an existing delegate or listener keeps compiling. (0.5.0 is where a native host does have something to add: see the section above.)

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

> **Pair the key with its environment.** The exchange runs in production as well as on staging, so
> build on the key from the start — there is no staging-only window to plan around. Keys are minted
> per environment (`fpk_live_…` for production, `fpk_test_…` elsewhere) and `configure()` refuses a
> key that disagrees with the `environment` you pass, locally, before any network call. So the two
> always move together: changing one and not the other is the refusal described under *Configuration
> reference* below. If a live key of yours does not resolve, ask your Fastory contact whether its
> workspace is provisioned — the `code` on `FastorySurfaceLoadFailed` tells you which refusal you hit.

### Flutter

Configure once in `main()`, open from anywhere (e.g. your footer):

```dart
import 'package:fastory_sdk/fastory_sdk.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Fastory.configure(const FastoryConfig(
    publishableKey: 'fpk_test_...',
    environment: FastoryEnvironment.staging,   // pair the key with its environment
    theme: FastoryTheme.dark,   // optional
    locale: 'fr-FR',            // optional
  ));
  runApp(const MyApp());
}

// In your footer tap handler:
onTap: () => Fastory.openGames(),
```

Both snippets on this page show a staging setup, because that is where most teams do their first
integration. Production is the same two lines with an `fpk_live_…` key and
`FastoryEnvironment.production`, which is also the default when you pass no environment at all.

### Native iOS

Configure at launch, then present from the view controller of your choice:

```swift
import FastorySDK

// In your App / AppDelegate:
Fastory.configure(FastoryConfig(publishableKey: "fpk_test_...", environment: .staging, theme: .dark))

// From your games tab or button:
Fastory.openGames(from: presentingViewController)
```

The Swift API takes the presenter explicitly (`openGames(from:)`) and delivers lifecycle events through `Fastory.eventsDelegate`, a `FastoryEventsDelegate`. Each channel follows its own platform idiom rather than a lowest-common-denominator signature — the behavior behind them is identical.

Observed on iOS 26.5: opening the hub from a SwiftUI `TabView` entry — a selection binding that
refuses the tab and calls `openGames(from:)` instead — works, and the call alone logs nothing. If
the same tap also changes state that the view owning the `TabView` reads in its `body` — an
`@ObservedObject`, `@EnvironmentObject`, `@StateObject` or `@Observable` model you update from the
selection binding — that view re-renders mid-switch and UIKit logs `Unbalanced calls to begin/end
appearance transitions for <SwiftUI.TabHostingController: …>`. The hub still opens and your
selection stays put. To avoid the line, read that state in the tabs' content rather than in the
view that owns the `TabView`, or in any view above it; deferring the call by one runloop tick does
not remove it.

## Configuration reference

`FastoryConfig`:

| Field | Type | Required | Description |
|---|---|---|---|
| `publishableKey` | `String` | one of the two | Your workspace publishable key, `fpk_live_…` in production, `fpk_test_…` elsewhere |
| `fanzoneSlug` | `String` | one of the two | **Deprecated.** Your Fanzone slug, e.g. `"your-fanzone"` — still accepted for the whole 0.x line |
| `theme` | `light` \| `dark` | no | Appearance hint forwarded to the hub and games. Not read by the web side yet |
| `environment` | `FastoryEnvironment` | no (default `production`) | `production` (`https://fanzone.me`), `staging` (`https://staging.fanzone.me`), or `development` (uses `developmentBaseUrl`) |
| `hubTabSlug` | `String` | no (default `"games"`) | The hidden hub tab slug |
| `locale` | `String?` | no | Forwarded to the hub and game URLs when provided, and the error view's fallback language (see *Offline*); unset, the web Fanzone resolves its own locale |
| `developmentBaseUrl` | `String?` | only when `environment == development` | Custom `https` base URL, for testing against a Fanzone you serve yourself. Flutter only: `configure` refuses a `development` configuration without it. On the Swift channel the field does not exist — `FastoryEnvironment.development(baseURL:)` carries the URL, so a development environment without one cannot be written |
| `prewarm` | `Set<FastorySurface>` | no (default: the hub alone) | The surfaces prepared before their first opening, so that opening shows them already rendered (since 0.5.0). Add `membership` if your app opens the membership panel — see *Preparing the panel ahead of time*. An empty set prepares nothing |
| `handlesLoginRequests` | `bool` | no (default `false`) | Declares that your app listens for `fastory:login-requested` and signs the fan in itself (since 0.5.0). Set it and the sign-in entries of the hub, the panel and the games ask your app; leave it `false` and the pages show no sign-in entry at all — see *Signing the fan in from a page* |

Public methods:

| Method | Description |
|---|---|
| `Fastory.configure(FastoryConfig)` | Sets the configuration. Call once before anything else. |
| `Fastory.openGames()` | Presents the full-screen hub view. Idempotent: a call while the hub is up does nothing. |
| `Fastory.openMembership({String? sequenceId})` | Presents the full-screen membership panel (since 0.5.0). Needs a publishable key. One surface at a time: a call while the hub or the panel is up does nothing. `sequenceId` opens the panel on one of the club's sequences; call it with no argument for the default screen — see *Opening the panel on a sequence*. |
| `Fastory.close()` | Programmatically dismisses whichever surface is presented (and any open game sheet). |
| `Fastory.identify(FastoryIdentity)` | Binds your user to a Fastory fan. See *Identity* below. |
| `Fastory.logout()` | Signs the fan out of Fastory. Never touches your own session. |
| `Fastory.setBridgeReply(type, payload)` | Declares what the SDK answers when an embedded surface asks. See *Answering the web content* below. |
| `Fastory.setHostTokenProvider(provider)` | Registers the closure the SDK calls back for a fresh host token when a delegated session needs renewing (since 0.5.0); `null` clears it. See *Identity* below. |

**When `configure()` refuses your configuration.** A configuration is refused locally, before any
network call, when it supplies neither identifier or both, a blank `fanzoneSlug` or `hubTabSlug`, a
malformed `publishableKey`, or a key minted for another environment (`fpk_live_…` outside production,
or `fpk_test_…` in it). **The two channels do not react the same way, and the difference matters most
on a debug build.**

*On Flutter*, `Fastory.configure()` throws `ArgumentError` synchronously, before it reaches the
platform channel. Catch it, log it, show what you like. When the offending field is the publishable
key the message names the rule that was broken and the environment expected, and not your key.

*On native iOS*, `Fastory.configure(_:)` is **non-throwing and cannot throw** — its signature has no
`throws`, and neither do the initializers. On a **debug** build it trips an assertion, so **your app
terminates on the spot**, with a fatal error naming the SDK's own file and the rule that was broken.
On a **release** build it returns normally and nothing is stored. If you want to decide for yourself
what a bad configuration does, call `try config.validate()` first: it is public, it throws
`FastoryConfigError`, it applies the same rules, and it calls nothing. `FastoryConfigError` is a
`LocalizedError`, so `error.localizedDescription` names the rule that was broken — the same sentence
you get by interpolating the error.

**A refused `configure()` changes nothing — including nothing you had already set.** On either
channel the configuration already in force keeps applying. So the "nothing is stored" above is the
whole story only for your *first* call: refuse that one and you are simply unconfigured, and
`openGames()` says so. Refuse a *later* one — an environment switch, a re-`configure()` from a
failure handler — and the SDK keeps running on the previous configuration, and `openGames()` opens
**that** fanzone rather than reporting a problem. On a debug iOS build you will not get that far,
because the assertion fires first; on release, and on Flutter if you swallow the exception, a refused
switch looks exactly like a switch that did not happen.

**An environment switch is the edit that hits this most easily.** Moving between staging and
production is a two-line change — the key and the environment — and changing one line and not the
other is exactly the refusal above, because a key is minted for one environment and `configure()`
checks the pair before it calls anything. On iOS, every debug build of your app then dies at launch;
on Flutter you get an exception you can catch. Change both lines together, and if a debug build
starts dying at launch right after an environment switch, this is why.

**Threading (since 0.4.0).** Every method above may be called from any thread except `openGames()`,
which needs the main thread — it takes your own `UIViewController` / `Context` to present from, so
you are already in UI code when you call it. That it takes a platform object is not what makes it
main-thread-only; presenting is: on Android `configure(context, …)` takes a `Context` too, presents
nothing and keeps only the application context, so it stays callable from any thread. `configure()`
in particular is safe from a background bootstrap: it stores your configuration before returning and
schedules its own WebView work on the main thread. Every
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
launch. Opening the hub is as fast as before, on both paths: configured by slug the page is prepared
right after that first frame, and configured by key it is prepared as soon as the
exchange resolves, so the first tap finds it ready like every later one.

**Preparing the panel ahead of time (since 0.5.0).** By default the SDK prepares the hub alone. A
prepared surface opens already rendered, and it costs a WebView kept in memory from launch on — a
renderer process on Android — plus the requests its page makes, whether your fan opens it or not.
So the membership panel is prepared only if you ask for it, with `prewarm`:

```dart
Fastory.configure(const FastoryConfig(
  publishableKey: 'fpk_test_...',
  environment: FastoryEnvironment.staging,
  prewarm: {FastorySurface.hub, FastorySurface.membership},
));
```

```swift
Fastory.configure(FastoryConfig(
    publishableKey: "fpk_test_...",
    environment: .staging,
    prewarm: [.hub, .membership]
))
```

- **Leave it out and the panel still works.** `openMembership()` needs nothing from `prewarm`: its
  first opening loads while your fan waits, under a loading indicator, and once that page has loaded
  it is kept when the panel closes, so every later opening is instant. A panel closed on its error
  view keeps nothing, and its next opening loads again. The same holds for the hub if you remove it
  from the set.
- **`prewarm: {}` prepares nothing ahead of time.** The key exchange still starts at `configure()`,
  so a first opening never waits for it to begin.
- **`game` changes nothing on its own.** Games are preloaded from the hub's page, so they follow
  `hub`.
- **On the deprecated `fanzoneSlug` path `membership` is ignored**: that path names no workspace, so
  there is no panel to prepare — or to open.
- **Changing the set is changing the configuration.** A `configure()` with a different `prewarm`
  drops what is warm and prepares again, like any other change; the same set again keeps it.

**Opening the panel on a sequence (since 0.5.0).** `openMembership()` opens the panel's default
screen, which is the club's own setting. Pass a sequence identifier and it opens there instead:

```dart
await Fastory.openMembership(sequenceId: '2f8a1c64-5b3e-4d71-9a02-7c1e5d3b8f40');
```

```swift
let sequenceId = "2f8a1c64-5b3e-4d71-9a02-7c1e5d3b8f40"
Fastory.openMembership(from: presentingViewController, sequenceId: sequenceId)
```

Four things to know, and the last one is the one that costs you a measurement if nobody tells you:

- **The argument is `sequenceId`; the URL parameter it becomes is `sequence`.** One name reads as
  what you hold, the other is what the page reads. `SPEC.md` § 3.5 is where both are written down.
- **Pass the identifier exactly as you hold it.** The SDK escapes it for the URL, so encoding it
  yourself is how it reaches the panel with `%` sequences in it.
- **An empty or blank identifier names no sequence**, and one the club does not carry opens the
  default screen. Neither is an error and no event tells them apart from a good one, so validate an
  identifier where it comes from rather than expecting the SDK to refuse it.
- **A named opening is slower than a bare one.** The panel is prepared ahead of the first tap on one
  address only — the default screen, since the SDK cannot guess which sequence you will ask for — so
  naming one loads the page at the moment you ask for it, while the bare call presents a page that
  is already there. On a slow network the difference is visible. It is not a defect to report: it is
  the preparation that makes the bare call instant — and that preparation happens only when
  `prewarm` names the panel (see above).

Under the hood the plugin uses a `MethodChannel` named `fastory_sdk` (`configure`, `openGames`, `openMembership`, `close`, `identify`, `logout`, `setBridgeReply`, `setHostTokenProvider` — plus `requestHostToken` the other way, when the SDK asks your provider for a fresh token) and an `EventChannel` named `fastory_sdk/events`.

## Identity

One method, three mutually-exclusive modes, plus a sign-out. **This API is final**, and since 0.5.0
all three modes resolve.

| Mode | What your user does | Available |
|---|---|---|
| `FastoryAnonymous()` | nothing; they are not recognised | **now** |
| `FastoryFanId()` | signs in to Fastory, in the **system browser** (never in a WebView) | **now** |
| `FastoryHostToken(jwt)` | nothing — your backend asserts the identity it already authenticated | **now** |

```dart
await Fastory.identify(const FastoryAnonymous());

// No identity system of your own? The user signs in to their Fastory account in the system browser:
final FastoryResolvedIdentity fan = await Fastory.identify(const FastoryFanId());

// Your backend already authenticated the user — pass the assertion it signed, no screen opens:
final FastoryResolvedIdentity fan =
    await Fastory.identify(FastoryHostToken(jwtFromYourBackend));

await Fastory.logout();
```

### Setting up `fanId` (one step per platform)

The login runs through AppAuth, the platform's reference OpenID library, which ships with the SDK —
you install nothing. What the platform needs from your app is the redirect back from the browser:
its scheme is **your application id** (bundle identifier on iOS, package name on Android), always —
the SDK derives it, and the server refuses a code minted for any other app.

**Android** — declare the placeholder in your app's `build.gradle` (the build fails at manifest
merge without it once the SDK is present, even if you never call `fanId`):

```groovy
android {
  defaultConfig {
    manifestPlaceholders += [appAuthRedirectScheme: applicationId]
  }
}
```

**iOS** — declare your bundle identifier as a URL scheme in `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>your.bundle.identifier</string></array>
  </dict>
</array>
```

What is worth knowing before you wire it up:

- **`identify(anonymous)` is idempotent.** Calling it twice, or on every app launch, gives you the
  same fan — it is a no-op when the SDK is already anonymous. Calling it is safe anywhere.
- **You do not have to call it at all.** An app that never calls `identify` behaves exactly as it did
  before 0.4.0.
- **`hostToken` opens no browser and no screen.** Your backend authenticated the user and signs an
  assertion; you pass that JWT and the SDK exchanges it for a Fastory session, which the games and the
  hub then carry. Fastory verifies the assertion server-side — the SDK never validates it. `fanId` is
  the opposite: a login, so it carries no argument and the credentials are typed in the system browser
  (the only path that reaches the device's password manager).
- **`fanId` costs one screen hand-off and comes back typed.** The browser sheet opens over your app;
  a user already signed in to Fastory on that browser round-trips without typing anything. Dismissing
  the sheet rejects with `login_cancelled` and leaves the SDK anonymous — never half-identified, and
  never the previously resolved fan. Signing out later (`logout()`) does not sign the user out of the
  system browser — that session belongs to the browser, which an app cannot erase — so a later
  `identify(FastoryFanId())` on the same device may resolve without showing a login form.
- **Both identified modes need a publishable key.** The exchange is bound to the workspace your key
  resolves, so `hostToken` and `fanId` alike on the deprecated `fanzoneSlug` path reject with
  `identify_mode_unavailable`.
- **A resolved fan carries an id and follows the user across surfaces.** `fan.fanId` is a stable
  identifier for the account; asking for the same user again is idempotent, and asking for a different
  one replaces the session with no trace of the previous fan.
- **The SDK keeps a delegated fan signed in — give it a way to get a fresh token (since 0.5.0).**
  Register a provider once and the SDK renews the session before it expires, without a visible break:

  ```dart
  Fastory.setHostTokenProvider(() async => await yourBackend.freshJwt()); // return null when you cannot
  ```

  It refreshes the session server-side while it is still valid (asking no one), and only calls your
  provider when that refresh is refused. The call is non-blocking and the SDK never inspects your
  token. Pass `null` to clear it. With no provider, a session simply lapses when it expires.
- **A session that cannot be renewed lapses to anonymous, and tells you why.** Listen for
  `FastoryIdentityRevoked` on the event stream: `reason == FastoryRevocationReason.expired` when
  nothing could renew it, `rejected` (with the server's `code`) when a renewal was refused. Re-`identify`
  with a fresh token, or let the fan continue anonymously — you are never left with a blank panel.
  `logout()` and a failed `identify()` never emit it.
- **A verified fan survives an app restart.** The SDK stores the identity (never the token) and
  rehydrates it on `configure`, so the panel opens already identified rather than re-verifying from
  scratch; the session behind it is re-established in the background.
- **Failures are typed and leave a clean state.** `identify` rejects with a `PlatformException` whose
  `code` you branch on — `identify_mode_unavailable` for an identified mode on the slug path,
  `not_configured` if `configure` has not run, `invalid_host_token` for a blank JWT,
  `login_cancelled` for a dismissed browser, and `identify_rejected` (with the API's own code in
  `details['code']`) when the assertion or the login code is refused. A refusal or a network failure
  leaves the SDK anonymous; it never leaves it half-identified.
- **`logout()` is Fastory-only, in both directions.** It clears the Fastory session on the Fastory
  domains and nothing else; and signing your user out of your own app does not sign them out of
  Fastory, so call `logout()` when that happens.
- An identity change drops the warm hub and the preloaded games, since they were rendered for the
  previous fan. The next `openGames()` after a `logout()` is a cold open.
- **A hub on screen follows the signed-in fan (since 0.5.0).** When an `identify` signs in a fan, or
  a different one, and when `logout()` or a lapsed session drops one, an open hub reloads — signed in
  as the new fan, or anonymous. Identifying the same fan again, a background renewal, and
  `identify(FastoryAnonymous())` while no fan is signed in reload nothing. The reload does not keep the
  fan's scroll position, and it emits no `hubOpened` or `hubClosed`. Games learn of the change without
  reloading.
- **A fan who taps a sign-in entry inside the hub, the panel or a game is asking your app to sign
  them in** — never a form in the page. See *Signing the fan in from a page* below.

## Events

The SDK exposes a broadcast stream of lifecycle events:

| Event | Payload | Emitted when |
|---|---|---|
| `hubOpened` | `{fanzoneSlug}` | The hub view is presented |
| `hubClosed` | — | The hub view is dismissed |
| `membershipOpened` | — | The membership panel is presented (since 0.5.0) |
| `membershipClosed` | — | The membership panel is dismissed (since 0.5.0) |
| `gameOpened` | `{slug}` | A game sheet is presented |
| `gameClosed` | — | The game sheet is dismissed |
| `externalLink` | `{url}` | A non-fanzone link was handed off to the system browser |
| `bridgeMessage` | `{type, payload}` | A Fastory web surface posted a message through the bridge (see below) |
| `identityResolved` | `{mode, fanId}` | `identify` resolved an identity — once per resolution, before any hub or game opening carrying it. `fanId` is null when anonymous |
| `surfaceLoadFailed` | `{surface, reason, code, statusCode}` | A hub, a game or (since 0.5.0) the membership panel did not load (see below) |
| `identityRevoked` | `{reason, code}` | The SDK dropped a delegated fan on its own — the session expired unrenewably (`expired`) or a renewal was refused (`rejected`, with the server's `code`). The fan is now anonymous; `logout()` never emits it |

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

Each presentation is bracketed exactly once: `hubOpened` … `hubClosed` for the hub,
`membershipOpened` … `membershipClosed` for the membership panel, with `gameOpened` / `gameClosed`
nested inside whichever of the two the game was opened from — so a `close()` with a game open emits
`gameClosed` first, on both platforms. A hub or a panel that Android rebuilds in place (a language
or display-size change, *Don't keep activities*) is the same presentation: it emits neither its
closing nor its opening event again. Rebuilt while its error view is up, it loads its page again
and emits its opening event only if it had not emitted it yet — see *When a surface does not load*.

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

- **`surface` is `FastorySurface.hub`, `FastorySurface.game` or, since 0.5.0, `FastorySurface.membership`** — which of the three did not load.
- **Branch on `reason`, read `code` and `statusCode` for the cause.** `rejected` means something
  answered and refused; `network` means nothing answered; `unknown` is everything else. Three cases
  on purpose, so "is Fastory reachable?" is one branch rather than a match over the codes below.
- **`code` appears only when your publishable key was refused**, and it is the one field worth
  alerting on: it means a configuration problem on your side or ours, not a flaky connection. Only
  six things can appear there: four names from our API, one the SDK mints, and the `http_<status>`
  family. Cover those and you have covered the field. The four from our API:

  | `code` | HTTP | What it means for you |
  |---|---|---|
  | `sdk_key_unknown` | 401 | We know no such key. Not only a typo in a build you never shipped: a key **deleted** in the back-office, and a workspace that no longer exists, both land here — so an app already in the field can meet it after a change it never saw. Ask us to re-issue a key; nothing in your app will fix it. |
  | `sdk_key_revoked` | 403 | The key existed and was withdrawn. A different back-office fact from the row above — keep them apart in your alerting, or a deleted key gets chased as a revoked one. |
  | `sdk_application_not_allowed` | 403 | The key is fine; this bundle identifier / package name is not declared on it. A debug build with an `applicationIdSuffix` is the usual cause. |
  | `sdk_rate_limited` | 429 | Too many exchanges from this key or this address. **Back off — do not retry in a loop.** A single burst clears on its own, but the third sanction adds your address to a block list **with no expiry**, and every later exchange from it answers this same code until the block is lifted, which you ask your Fastory contact for. Looping is what earns the permanent form. Surface it rather than absorb it. |

  **The other two the SDK mints itself**, so that a refusal is never reported as a blank:
  `http_<status>` when the refusal named no code of its own — whatever its body looked like: JSON
  without a `code`, an HTML error page from a proxy in front of our API, or nothing at all —
  and `sdk_application_id_required` when the SDK could not read your app's identifier at all and so
  had no well-formed request to send — iOS only in practice, since an Android package name always
  exists. Those six are the whole of it; treat anything else in `code` as a bug to report. When
  nothing answered at all, `code` is null and `reason` is what tells you — **an unknown key, a
  revoked key and a fan with no signal are three different situations**, and only the third is the
  fan's connection.
- **No opening event is emitted for a surface that failed**, and no closing event either. If you count
  `hubOpened` as a session, a failed hub is not one — and `hubOpened` … `hubClosed` still pair up.
- **A surface closed on its error view keeps nothing.** When your fan leaves a hub or a panel that
  did not load without pressing Retry, its next opening starts over instead of reusing what failed,
  and the opening event arrives only once a page has loaded — still offline, the error view and a
  new `FastorySurfaceLoadFailed` come back instead. After a failed publishable-key exchange, though,
  that next opening can show the error view even back online, answered from the exchange that
  failed: Retry opens it, and on Android so does the opening after.
- **The SDK never retries by itself**, save when Android rebuilds a screen in place (a language or
  display-size change, *Don't keep activities*): a game sheet reloads its game with the screen,
  error view or not, and a hub or a panel rebuilt while its error view is up loads its page again,
  as its first opening did — online it opens, offline you receive one more
  `FastorySurfaceLoadFailed`. A rebuild does not run the publishable-key exchange again, so when
  that exchange is what failed the error view can stay up until the fan presses Retry. Otherwise the
  fan has a Retry button; your app decides everything else.
- **Retry recovers a refused publishable key too**, since 0.4.3. It used to be the one place the
  button fell short: Retry reloaded the page that failed, a key we refused had never produced one,
  and the fan was stuck until they killed the app. The button now re-runs the key exchange, so a fan
  who lost signal at launch taps Retry and the hub opens — no `configure()` call from you, and no
  restart. A page that failed on its own (a 404, a connection dropped mid-load) still reloads, and so
  does everything on the deprecated `fanzoneSlug` path.
- **What that does not change: every code in the table above is still worth alerting on.**
  `sdk_key_unknown`, `sdk_key_revoked` and `sdk_application_not_allowed` refuse the second exchange
  exactly as they refused the first, so the fan can tap Retry all afternoon without getting in — the
  hub opens once one of us fixes the configuration, not because they persisted. Retry recovers a bad
  minute on the network, never a key we have refused.
- **`sdk_rate_limited` is the exception: Retry does not even ask us again.** The error view stays and
  no request leaves the device. That code's sanction counts requests from your users' **address**, not
  from your key — everyone behind one carrier NAT or one venue's wifi shares it, and a third sanction
  blocks that address with no expiry. A button that re-asked would make the SDK the looping client the
  table above tells you not to be. `SPEC.md` § 9 carries the normative version of all of this.
- **If you call `configure()` again anyway** — behind your own error UI, say — that still re-runs a
  failed exchange, on both platforms, with the configuration already in force. One caveat if you do:
  on Android the previous failure stays readable until the new answer lands, so an open that starts
  inside that window is answered from it and the recovery lands on the open after. Re-configure, then
  let the fan open again when they choose to.
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

- **Two types exist today.**
  - `fastory:ready` — the embedded Fastory surface has rendered. It is a liveness signal, not a
    lifecycle event: `hubOpened` / `gameOpened` remain the source of truth for what is on screen, and
    you must not *require* `fastory:ready` to arrive, because the web side may be deployed at a
    version that never sends it. It is sent when the page's own render commits, not once the surface
    has painted — fonts, images and data-driven blocks may still be resolving — so dismissing a native
    splash screen on it can uncover a surface that is not finished drawing.
  - `fastory:login-requested` (since 0.5.0) — a fan tapped a sign-in entry on the hub, the membership
    panel or a game, and asks your app to sign them in. Sent only if you declared
    `handlesLoginRequests`; see *Signing the fan in from a page* below.
- **These messages travel web → app only.** They are notifications, and nothing you do makes one
  arrive. The other direction is *answering* — see the next section.
- **Unknown message types are dropped.** That is what lets us ship a new message type later without
  breaking an app already in the stores — your build keeps working, it just does not see it.
- **The bridge changes nothing about the games flow.** Games still open through native URL
  interception; external links still leave for the system browser. A message never substitutes for
  either.

The normative envelope, the type registry and the JavaScript entry points are in `SPEC.md` § 13.

### Signing the fan in from a page (since 0.5.0)

Your fanzone's pages have sign-in entries of their own: a *Log in* button, a contest reserved to
signed-in fans, the end of a game offering to save the score. Inside your app none of them ever opens
a login form — signing the fan in is your app's job, through `identify`. What they do instead depends
on one configuration field:

- **You set `handlesLoginRequests: true`.** The entries stay. A tap sends your app
  `fastory:login-requested`; you sign the fan in your own way, then call `identify`. The hub on
  screen then reloads with the fan signed in.
- **You leave it `false`, the default.** The pages show no sign-in entry at all: an entry whose only
  job is to sign in is hidden, and content that needs a signed-in fan reads *Sign in from the app to
  continue*, with no button. Your fan never meets a button that does nothing.

**On Flutter, close the surface before you show your sign-in.** The hub, the panel and the game sheet
are native screens presented above your Flutter view — full screen on iOS, a separate Activity on
Android — so a Flutter route or dialog draws beneath them, and your fan sees it only once they are
gone. Answer in four steps: `close()`, your sign-in, `identify`, then reopen the surface your fan was
on — `openGames()` for the hub or a game, which reopens on the hub, or `openMembership()` with the
same `sequenceId`. `close()` returns before the surface has left the screen — on iOS it animates
out — so show your sign-in once its closing event arrives, `FastoryHubClosed` or
`FastoryMembershipClosed`. Bound that wait: with nothing on screen no closing event comes, so skip
it, and a short timeout keeps your fan from waiting on an event that never arrives. A refused or
cancelled `identify` rejects with a `PlatformException`: catch it, or it leaves your listener as an
unhandled error. Reopen in a `finally`, so your fan gets the surface back in every case — signed in,
refused, cancelled, or after a sign-in of yours that throws. And answer one request at a time — a
fan who taps twice sends two. A native iOS host presents its sign-in above the SDK's screens and
keeps them open.

```dart
Fastory.configure(const FastoryConfig(
  publishableKey: 'fpk_live_...',
  handlesLoginRequests: true,
));

FastorySurface? onScreen;
bool signingIn = false;

Fastory.events.listen((FastoryEvent event) async {
  switch (event) {
    case FastoryHubOpened():
      onScreen = FastorySurface.hub;
    case FastoryMembershipOpened():
      onScreen = FastorySurface.membership;
    case FastoryHubClosed() || FastoryMembershipClosed():
      onScreen = null;
    case FastoryBridgeMessage(type: 'fastory:login-requested'):
      // One sign-in at a time: a second tap asks nothing new.
      if (signingIn) return;
      signingIn = true;
      final FastorySurface? origin = onScreen;
      try {
        final Future<void> leftScreen = origin == null
            ? Future<void>.value()
            : Fastory.events
                .firstWhere((FastoryEvent e) =>
                    e is FastoryHubClosed || e is FastoryMembershipClosed)
                .then((_) {});
        // First, and wait until the surface is gone, or your sign-in draws under it:
        await Fastory.close();
        await leftScreen.timeout(const Duration(seconds: 2), onTimeout: () {});
        // Your own sign-in, then the assertion your backend signs for that user:
        final String? jwt = await yourApp.signIn();
        if (jwt != null) await Fastory.identify(FastoryHostToken(jwt));
        // No identity system of your own? Let the fan sign in to Fastory in the system browser:
        // await Fastory.identify(const FastoryFanId());
      } on PlatformException catch (refusedOrCancelled) {
        debugPrint('Sign-in not completed: ${refusedOrCancelled.code}');
      } finally {
        signingIn = false;
        // Back where the fan was, whatever happened above: signed in, as they were if they
        // cancelled, or as the failure left them:
        if (origin == FastorySurface.hub) await Fastory.openGames();
        if (origin == FastorySurface.membership) {
          await Fastory.openMembership(sequenceId: yourApp.panelSequenceId);
        }
      }
    default:
      break;
  }
});
```

```swift
Fastory.configure(FastoryConfig(
    publishableKey: "fpk_live_...",
    handlesLoginRequests: true
))

// In your FastoryEventsDelegate:
func fastoryBridgeMessage(type: String, payload: [String: Any]) {
    guard type == "fastory:login-requested" else { return }
    yourApp.signIn { jwt in
        guard let jwt else { return }
        Fastory.identify(.hostToken(jwt: jwt))
    }
}
```

What to know before you declare it:

- **Declare it only if you listen for the message.** Declared and unheard, every sign-in entry in
  the pages is a button that does nothing — and no event tells you so. The SDK does nothing with the
  message itself: it opens no screen and changes no navigation.
- **The message carries nothing.** Its `payload` is empty. It arrives on the main thread, once per
  tap, and only after a fan's tap — never because a page loaded or a game ended.
- **You answer with `identify`, not with a bridge reply.** There is no reply on the bridge. Once
  `identify` resolves a different fan, the hub on screen reloads signed in as that fan and the games
  pick the new session up on their own — see *Identity* above. If your fan cancels your sign-in, a
  native host does nothing and the page stays as it was; a Flutter host reopens the surface it
  closed, without calling `identify`.
- **On Android, a frame embedded inside a game can post this message too.** It carries nothing, so
  the worst it can do is show your sign-in when the fan did not ask. Never decide anything that
  matters on it: offer a sign-in, never grant one.
- **The membership panel does not show the signed-in fan yet** — see *Known limitations*.
- **Changing it is changing the configuration**: a `configure()` that flips it drops what is warm and
  prepares again, like any other change.

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
| 1 | Origin = Fanzone base **or** a Fastory stories domain (`https://story.tl` or `https://staging.story.tl` — both, whichever environment you configured) — **and**, in either case, path starts with `/s/` | Open the game bottom sheet (WebView B) |
| 2 | Origin = Fanzone base, any other path | Allow — navigate inside the current WebView |
| 3 | Any other `http(s)` origin | Open in the system browser |
| 4 | Non-`http(s)` scheme (`mailto:`, `tel:`, `intent:`, `market:`, …) | Hand off to the system (external) |

### Consent

The hub and game URLs carry `consent=0`. The web player reads this as "the host app handles consent",
so it does not show its own cookie banner, and it does not assume analytics consent. The value is
fixed: the SDK always sends `consent=0`, and no configuration field changes it in this version.

### Sessions and stored data

The hub and the games are **different sites** (`fanzone.me` and `story.tl`), so they do not share a
session, and no store configuration can make them: the hub reads a cookie, and a game loaded with
`embed=1` takes its session from its host page, not from storage — and in an SDK WebView it has no
host page. Each page still reads and writes storage of its own: the game keeps its own cookies and
web storage on its own site, as any page does, so if you declare the data your app stores, count the
game's as well as the hub's. What never happens is a session crossing from one site to the other.
Each surface keeps its own persisted state across `openGames()` sessions and app restarts.

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
2. Else if the presented surface's WebView `canGoBack`, `goBack()`.
3. Else close the full-screen view and return to the app.

The same order applies to the membership panel, and step 2 is why back behaves hierarchically there:
its page pushes a history entry per tab and per sub-screen it opens, so back walks the fan out of a
sub-screen, then back through the tabs, and only then closes the panel.

Back only walks what the fan did since the SDK last loaded the page. An opening that loads its page
— the panel on a named sequence, or on its default screen after one, and the hub of a fan you
identified, whose address changes at every opening — starts with no history behind it, and back
closes it while that page is still loading. A surface reopened as the fan left it has not been
loaded again and keeps the way they came.

### Safe areas

On iOS the SDK keeps the top and the sides of its WebViews **inside the safe area**: the hub and the membership panel start below the status bar (notch and Dynamic Island included), which sits on a plain band in the system background colour rather than on the Fanzone's own background. If your app sets the status bar style itself rather than per view controller (`UIViewControllerBasedStatusBarAppearance` set to `NO`), the band follows the style in force when the surface opens: black under light text, white under dark text. A phone without a notch shows no band beyond the status bar's, and in landscape the band also runs along the side edges the system reserves.

**At the bottom, the three surfaces differ on iOS.** Since 0.5.0 the **hub runs to the bottom edge of the screen**, under the home indicator, with no band there: its page keeps its last content clear of the indicator itself, the way it already did on Android. The **membership panel ends above the home indicator**, on the same band as at its top, because its page does not make room for the indicator. The **game sheet ends above the home indicator** too, on a plain band, so a game's bottom button never sits under it. This holds in portrait, in landscape and on iPad alike.

On Android the WebViews are laid out **edge-to-edge** and the chromeless Fanzone pads its own content via `env(safe-area-inset-*)`, clear of the cutout and the gesture bar. Native close affordances (the ✕ button) are inset below the system bars on both platforms. You do not need to do anything on the app side.

One effect to expect on the hub, on both platforms: a control its page pins to the very bottom of the screen without allowing for that inset — a floating button, the foot of a drawer — can sit behind the home indicator on iOS, or the gesture bar on Android. It is the page's to correct, and nothing in your app changes it; tell your Fastory contact where you see one.

### Offline

If a surface fails to load (airplane mode, no network, a page that answers an error), the SDK shows a native error state with a retry action — no blank white WebView is left on screen, and none is kept for later: a surface closed on its error state starts over at its next opening. The message is localized — English, French and Spanish, following the fan's device language; when none of the device's languages is one of those, the `locale` you configured is used if it is one, English otherwise — and tells a lost connection (*No internet connection.*) from any other failure (*Something went wrong.*). With VoiceOver or TalkBack on, pressing Retry on any surface moves the focus onto a loading indicator labelled *Loading…*, and the end of the wait is spoken — *Content loaded.* when the page opens, the error message when it does not; the same language rule applies. On Android you may override the six string resources by redefining them, for every language you ship: a redefinition in `values/` alone leaves the SDK's French and Spanish tables in force on those devices. On iOS the texts cannot be overridden. **Since 0.4.0 the game sheet has the same error view**, and every surface reports the failure to your app as `FastorySurfaceLoadFailed` (see *When a surface does not load*).

## FAQ

**Can we use our own in-app WebView policy / browser component?**
No — the two WebViews are owned and configured by the SDK (URL interception, safe areas, and the scoped session erasure of `logout()` all depend on it). External links respect the system default browser.

**Do we need ProGuard / R8 rules?**
No. The SDK's Android module declares its keep rule with `consumerProguardFiles`, which is what makes R8 merge that rule into your application's configuration when it shrinks — whether your R8 setup is hand-written or derived from AGP's defaults. The rule keeps the bridge's JavaScript entry point, the one member R8 finds no caller for, because the WebView reaches it by reflection. Everything else the SDK uses — the platform `android.webkit.WebView`, standard Flutter plugin registration — is covered by default Flutter/AGP rules. If your build uses aggressive custom shrinking and you still hit an issue, keep the SDK's plugin package and report it to us.

**What does the SDK add to app size?**
It is intentionally ultra-light: Dart plugin glue plus thin native view controllers around system WebViews. No bundled UI frameworks and no analytics libraries. The Swift package declares no dependency. The Android module depends on five AndroidX and Material libraries — `androidx.core:core-ktx:1.13.1`, `androidx.appcompat:appcompat:1.7.0`, `com.google.android.material:material:1.12.0`, `androidx.webkit:webkit:1.11.0` and `androidx.lifecycle:lifecycle-process:2.6.1` — which most Android apps already resolve. Expect a negligible footprint (well under 1 MB per platform).

**Will this pass Apple App Store review / TestFlight?**
The SDK displays the partner's own web content (your Fanzone) in a WebView, with no payments, no OAuth, no account creation, and no downloadable code beyond regular web pages. This is standard partner-content embedding. Prize-based games remain subject to the usual App Store Review Guidelines on contests (the contest organizer is the partner/Fastory, not Apple — state this in your contest rules as usual).

**Which environments exist?**
Production (`https://fanzone.me`) and staging (`https://staging.fanzone.me`). A development environment takes a base URL of your own (`developmentBaseUrl`), for testing against a Fanzone you serve yourself.

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

The API host is reached **only** on the publishable-key path, at `POST /sdk/auth/bootstrap`. "Once
per configuration" is true of an exchange that succeeded: it is not run again until you configure
again. A **failed** exchange is not remembered as final, and the two platforms re-run it differently:
on Android, `openGames()` asks the resolver again, so a second request leaves before the hub decides
what to show; on iOS, the hub shows the error view from the remembered failure and the second
request leaves when the fan taps Retry (never for `sdk_rate_limited` — see *When a surface does not
load*). So a configuration whose exchange failed costs **two requests on Android** before the fan
taps anything, and **one on iOS** until they tap Retry — plus one per Retry press on either — and
none of them is a retry loop: each is triggered by a call of yours or a tap of the fan's.
Configured with the deprecated `fanzoneSlug` the SDK calls no endpoint at all. Anything else your fan
reaches through a hub tile leaves for the system browser and is not the SDK's traffic.

## Known limitations

All of these hold for the version documented above. None has a committed release date — ask us if
one of them blocks you, rather than planning around a version number.

- **The membership panel does not show the signed-in fan yet.** A fan you identified with
  `identify()` still appears anonymous in the panel, and a sign-in entry tapped there sends you
  `fastory:login-requested` like anywhere else, but the panel does not change once you have signed
  the fan in. The hub and the games do show the signed-in fan. A fix is planned on our side.
- **A club whose membership panel is not enabled shows an explanatory page, and the SDK reports that
  panel as opened.** The page answers normally, so there is no failure to observe and no event
  distinguishing it — `membershipOpened` fires as it would for any other page. If you need to know
  whether a given club has it, ask us rather than inferring it from the event stream.
- No standalone Android artifact, and no supported native Android path until it ships: the Kotlin
  core reaches an app only inside the Flutter plugin, for a Flutter app. Ask us if this blocks you.
- No SDK-side analytics — use the event stream and your own tracker.
- No JavaScript injection. The bridge carries two notification types and answers one question type —
  there is no API to *push* into the web content unprompted, and no haptics or share hooks.
- On Android the reply channel needs a WebView from Chrome 85 (mid-2020) or later. Below that it is
  simply absent and surfaces stay anonymous; nothing else about the SDK is affected.
- On Android the SDK learns that your app is on screen through `androidx.lifecycle:lifecycle-process`,
  which is initialised by the `InitializationProvider` that `androidx.startup` declares in its
  manifest. If your app removes that provider (`tools:node="remove"`), the SDK is never told you
  are on screen: nothing `prewarm` names is prepared ahead of its first opening and every opening loads cold,
  under a loading indicator — with no error and no event to tell you why. Keep the
  provider, or run `ProcessLifecycleInitializer` yourself through `AppInitializer` before the SDK
  needs it.
- The SDK never retries a failed load by itself — save, on Android, a hub, a panel or a game sheet
  the system rebuilds while its error view is up, which loads its page again (see *When a surface does not load*). It
  shows an error view with Retry and reports the failure (`FastorySurfaceLoadFailed`); any automatic
  retry policy is yours to implement. The fan's
  Retry does re-run a refused publishable-key exchange, since 0.4.3 — see *When a surface does not
  load* above for what it recovers and what it cannot.
- **Two build-time warnings you will see and can ignore, on the Flutter channel.** Neither breaks the
  build and neither has a workaround on your side:
  - `flutter build apk` prints *"Your app uses the following plugins that apply Kotlin Gradle Plugin
    (KGP): fastory_sdk … upgrade to a version that supports Built-in Kotlin"*. Flutter has dated the
    deprecation; the plugin will move before it becomes an error.
  - `flutter build ios` prints *"The following plugins do not support Swift Package Manager for
    ios"*, listing `fastory_sdk`, then *"This will become an error in a future version of
    Flutter"*, and falls back to CocoaPods, which succeeds. Built with the plugin as a local path
    dependency, as the bundled example app is, it also prints *"Plugin fastory_sdk does not have
    Swift Package Manager support for ios"*. This is about the **plugin's** iOS side only — the
    native Swift channel described under *Install* is a real SwiftPM package and resolves normally.
    Swift Package Manager support for the plugin is planned on our side.
- Portrait and landscape are supported, but the hub content is designed mobile-first (portrait).
