# Changelog

All notable changes to the Fastory Mobile SDK are documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org),
tags `sdk-vX.Y.Z`.

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
