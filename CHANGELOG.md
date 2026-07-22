# Changelog

All notable changes to the Fastory Mobile SDK are documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org),
tags `sdk-vX.Y.Z`.

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
