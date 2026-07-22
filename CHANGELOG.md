# Changelog

All notable changes to the Fastory Mobile SDK are documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org),
tags `sdk-vX.Y.Z`.

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
