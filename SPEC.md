# Fastory Mobile SDK — v0.1 Specification

Status: **Normative** — this document is the single source of truth for the Fastory Mobile SDK v0.1 public API.
Audience: SDK implementers (iOS, Android, Flutter) and integrators (your-fanzone app team).
The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as described in RFC 2119.

---

## 1. Overview & Scope (v0.1)

The Fastory Mobile SDK embeds the Fastory Fanzone games experience inside a host mobile application. v0.1 is deliberately ultra-light: it is a native WebView container with a strict URL interception policy — no authentication, no analytics, no behavior-modifying JavaScript (the only script evaluation permitted is the read-only preload discovery query of § 11).

### 1.1 User flow

1. The host app (Flutter, e.g. the your-fanzone app) calls `Fastory.openGames()`.
2. The SDK presents a **full-screen native view** containing **WebView A** (the "hub"), which loads a hidden tab of the client's Fanzone (e.g. `https://fanzone.me/your-fanzone?tab=games&chrome=0&consent=0`).
3. The user taps a game image in the hub. The web page performs `window.open(url, '_self')`; the SDK intercepts this navigation natively.
4. The SDK presents a **native bottom sheet** (the "toaster") containing **WebView B**, which loads the game (e.g. `https://fanzone.me/s/{slug}?embed=1&utm_source=sdk`).
5. Any navigation to an origin other than the configured Fanzone base URL opens in the **system browser**.

### 1.2 In scope (v0.1)

- Full-screen hub view (WebView A) and game bottom sheet (WebView B).
- URL interception policy (§ 4).
- Flutter platform channel bridge (§ 5).
- Android back button handling (§ 6).
- Shared cookie/data store between both WebViews (§ 7).
- Native safe-area handling (§ 8).
- Native error/offline view with retry (§ 9).
- Game preloading and fresh-state close (§ 11).

### 1.3 Minimum OS versions

- iOS: **15.0**
- Android: **minSdk 24** (Android 7.0)

---

## 2. Public API Surface

The SDK exposes three operations and one event stream. Signatures below are normative; implementations MUST match them exactly.

### 2.1 Configuration model

| Field | Type | Required | Description |
|---|---|---|---|
| `environment` | enum `production` \| `staging` \| `development` | yes | Selects the Fanzone base URL (§ 3.1) |
| `fanzoneSlug` | string | yes | Fanzone identifier, e.g. `"your-fanzone"` |
| `hubTabSlug` | string | yes | Hidden tab used as games hub, e.g. `"games"` |
| `locale` | string (BCP 47) | no | Preferred locale hint, e.g. `"en"`, `"fr-FR"` |
| `developmentBaseUrl` | string (https URL) | only when `environment == development` | Custom base URL for development |

`configure` MUST be called before `openGames()`. Calling `openGames()` unconfigured MUST fail with error code `not_configured` (§ 5.4). `configure` MAY be called again; the new configuration applies to the next `openGames()` call.

### 2.2 Swift (iOS)

```swift
public enum FastoryEnvironment {
    case production
    case staging
    case development(baseURL: URL)
}

public struct FastoryConfig {
    public let environment: FastoryEnvironment
    public let fanzoneSlug: String
    public let hubTabSlug: String
    public let locale: String?

    public init(environment: FastoryEnvironment,
                fanzoneSlug: String,
                hubTabSlug: String,
                locale: String? = nil)
}

public protocol FastoryEventsDelegate: AnyObject {
    func fastoryHubOpened(fanzoneSlug: String)
    func fastoryHubClosed()
    func fastoryGameOpened(slug: String)
    func fastoryGameClosed()
    func fastoryExternalLink(url: URL)
}

public enum Fastory {
    public private(set) static var config: FastoryConfig?
    public static weak var eventsDelegate: FastoryEventsDelegate?

    public static func configure(_ config: FastoryConfig)
    public static func openGames(from presenter: UIViewController)
    public static func close()
}
```

- `openGames(from:)` MUST present the hub full screen (`.fullScreen` modal presentation) over `presenter`. Calling it unconfigured is a no-op (an assertion fires in debug builds); it does not throw.
- `close()` MUST dismiss the game sheet (if any) and the hub, in that order, emitting `gameClosed` then `hubClosed`.
- `eventsDelegate` is `weak`: the host app MUST retain its delegate for the lifetime of the session, or events stop being delivered.

### 2.3 Kotlin (Android)

```kotlin
sealed class FastoryEnvironment {
    object Production : FastoryEnvironment()
    object Staging : FastoryEnvironment()
    data class Development(val baseUrl: String) : FastoryEnvironment()
}

data class FastoryConfig(
    val environment: FastoryEnvironment,
    val fanzoneSlug: String,
    val hubTabSlug: String,
    val locale: String? = null,
)

interface FastoryEventsListener {
    fun onHubOpened(fanzoneSlug: String) {}
    fun onHubClosed() {}
    fun onGameOpened(slug: String) {}
    fun onGameClosed() {}
    fun onExternalLink(url: String) {}
}

object Fastory {
    fun configure(config: FastoryConfig, listener: FastoryEventsListener? = null)
    fun openGames(context: Context)
    fun close()
}
```

- The event listener is supplied to `configure` (all methods have default no-op bodies, so hosts override only what they need). Calling `openGames` unconfigured throws `IllegalStateException`.
- `openGames(context)` MUST launch a dedicated full-screen `Activity` (or full-screen `DialogFragment`) hosting WebView A.
- The game toaster MUST be a `BottomSheetDialogFragment` (Material bottom sheet) hosting WebView B.

### 2.4 Dart (Flutter plugin)

```dart
enum FastoryEnvironment { production, staging, development }

class FastoryConfig {
  const FastoryConfig({
    required this.environment,
    required this.fanzoneSlug,
    required this.hubTabSlug,
    this.locale,
    this.developmentBaseUrl,
  });

  final FastoryEnvironment environment;
  final String fanzoneSlug;
  final String hubTabSlug;
  final String? locale;
  final String? developmentBaseUrl;
}

sealed class FastoryEvent {
  const FastoryEvent();
}

class FastoryHubOpened extends FastoryEvent {
  const FastoryHubOpened(this.fanzoneSlug);
  final String fanzoneSlug;
}

class FastoryHubClosed extends FastoryEvent { const FastoryHubClosed(); }

class FastoryGameOpened extends FastoryEvent {
  const FastoryGameOpened(this.slug);
  final String slug;
}

class FastoryGameClosed extends FastoryEvent { const FastoryGameClosed(); }

class FastoryExternalLink extends FastoryEvent {
  const FastoryExternalLink(this.url);
  final String url;
}

class Fastory {
  static Future<void> configure(FastoryConfig config);
  static Future<void> openGames();
  static Future<void> close();

  static Stream<FastoryEvent> get events;
}
```

- All three methods delegate to the platform channel (§ 5) and complete when the native side has acknowledged the call.
- `events` is a broadcast stream backed by the `EventChannel`; subscribing MUST NOT be required for the SDK to function.

---

## 3. URL Construction

### 3.1 Environment base URLs

| Environment | Base URL |
|---|---|
| `production` | `https://fanzone.me` |
| `staging` | `https://staging.fanzone.me` |
| `development` | Integrator-provided (`developmentBaseUrl` / `Development(baseUrl:)`) — MUST be `https` |

The configured base URL origin (scheme + host + port) is referred to below as the **Fanzone origin**. All origin comparisons MUST be exact (no subdomain wildcards) and case-insensitive on the host.

### 3.2 Hub URL (WebView A)

```
{base}/{fanzoneSlug}?tab={hubTabSlug}&chrome=0&consent=0[&locale={locale}]
```

| Param | Value | Purpose |
|---|---|---|
| `tab` | `hubTabSlug` | Selects the hidden games tab of the Fanzone |
| `chrome` | `0` | Hides web navigation chrome (header/footer) |
| `consent` | `0` | Marks consent as handled by the host app; the web player suppresses its own cookie banner and does not assume analytics consent |
| `locale` | `locale` config value | Optional locale hint; omitted when not configured |

Example: `https://fanzone.me/your-fanzone?tab=games&chrome=0&consent=0`

### 3.3 Game URL (WebView B)

When the interception policy resolves `OPEN_GAME_SHEET` (§ 4), the SDK MUST load the intercepted URL in WebView B **augmented** with:

| Param | Value | Purpose |
|---|---|---|
| `embed` | `1` | Signals embedded rendering to the story player |
| `utm_source` | `sdk` | Attribution of SDK-originated traffic |
| `consent` | `0` | Same consent hint as the hub (§ 3.2), so the game player suppresses its own cookie banner |

Existing query parameters on the intercepted URL MUST be preserved; `embed`, `utm_source` and `consent` MUST NOT be duplicated if already present.

Example: intercepted `https://fanzone.me/s/summer-quiz` → loaded as `https://fanzone.me/s/summer-quiz?embed=1&utm_source=sdk&consent=0`

### 3.4 Game slug extraction

The game `slug` reported in the `gameOpened` event is the first path segment after `/s/` (e.g. `summer-quiz` for `/s/summer-quiz` or `/s/summer-quiz/anything`).

---

## 4. Navigation Interception Policy (URLPolicy)

Every main-frame navigation request in WebView A and WebView B MUST be evaluated **by URL** against the following ordered rules. The first matching rule wins.

| # | Condition | Decision | Behavior |
|---|---|---|---|
| 1 | (Origin == Fanzone origin OR origin is a **stories origin**) AND path starts with `/s/` | `OPEN_GAME_SHEET` | Cancel navigation; open (or replace content of) the game bottom sheet with the URL per § 3.3; emit `gameOpened{slug}` |
| 2 | Origin == Fanzone origin (any other path) | `ALLOW` | Let the WebView navigate in place |
| 3 | Any other `http(s)` origin | `OPEN_EXTERNAL_BROWSER` | Cancel navigation; open the URL in the system browser; emit `externalLink{url}` |
| 4 | Non-`http(s)` scheme (`mailto:`, `tel:`, `intent:`, `market:`, …) | `OPEN_EXTERNAL_BROWSER` | Cancel navigation; hand the URL to the OS (`UIApplication.open` / `Intent.ACTION_VIEW`); emit `externalLink{url}` |

The **stories origins** are the Fastory story-player domains games may be served from:
`https://story.tl` and `https://staging.story.tl` (exact `https` host match, default port). Any
stories-origin URL whose path does not start with `/s/` follows rule 3 (external).

### 4.1 Examples (production, `fanzoneSlug=your-fanzone`)

| URL | Rule | Decision |
|---|---|---|
| `https://fanzone.me/s/summer-quiz` | 1 | `OPEN_GAME_SHEET` |
| `https://fanzone.me/s/wheel-of-fortune?ref=hub` | 1 | `OPEN_GAME_SHEET` |
| `https://story.tl/s/summer-quiz` | 1 | `OPEN_GAME_SHEET` |
| `https://fanzone.me/your-fanzone?tab=games&chrome=0&consent=0` | 2 | `ALLOW` |
| `https://fanzone.me/your-fanzone/legal` | 2 | `ALLOW` |
| `https://www.instagram.com/your-fanzone` | 3 | `OPEN_EXTERNAL_BROWSER` |
| `https://story.tl/x/abc` | 3 | `OPEN_EXTERNAL_BROWSER` |
| `mailto:support@fastory.io` | 4 | `OPEN_EXTERNAL_BROWSER` |
| `tel:+33100000000` | 4 | `OPEN_EXTERNAL_BROWSER` |
| `intent://play#Intent;...;end` | 4 | `OPEN_EXTERNAL_BROWSER` |
| `market://details?id=com.x` | 4 | `OPEN_EXTERNAL_BROWSER` |

### 4.2 Interception points

- **iOS**: `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)` for link navigations, and `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)` for `window.open` (MUST return `nil` and route through URLPolicy).
- **Android**: `WebViewClient.shouldOverrideUrlLoading` and `WebChromeClient.onCreateWindow` (with `setSupportMultipleWindows(true)`), both routed through URLPolicy.
- `window.open(url, '_self')` from the hub MUST be intercepted like any main-frame navigation.
- Sub-frame (iframe) navigations MUST NOT be intercepted; they load in place.
- Rule matching for `/s/` MUST match the path prefix exactly: `/s/` followed by a non-empty segment. `/story/`, `/sea/` etc. do not match.
- If a game (WebView B) navigates to another `/s/` URL, the current sheet MUST load the new game in place (emitting `gameClosed` then `gameOpened{slug}` when the slug changes).

---

## 5. Platform Channel Contract (Flutter)

### 5.1 Channels

| Channel | Type | Name |
|---|---|---|
| Methods | `MethodChannel` | `fastory_sdk` |
| Events | `EventChannel` | `fastory_sdk/events` |

Both channels use the standard method codec (`StandardMethodCodec`).

### 5.2 Methods

#### `configure`

Argument: a `Map<String, Object?>`:

```json
{
  "environment": "production",
  "fanzoneSlug": "your-fanzone",
  "hubTabSlug": "games",
  "locale": "en",
  "developmentBaseUrl": null
}
```

- `environment` MUST be one of `"production"`, `"staging"`, `"development"`.
- `developmentBaseUrl` MUST be present and non-null when `environment == "development"`, ignored otherwise.
- Returns `null` on success.

#### `openGames`

Argument: `null`. Presents the hub. Returns `null` once presentation has started.

Errors (`PlatformException.code`):

| Code | Meaning |
|---|---|
| `not_configured` | `configure` was never called |
| `already_open` | The hub is already presented |
| `invalid_config` | Malformed configuration (bad URL, empty slug) |

#### `close`

Argument: `null`. Dismisses the sheet then the hub (no-op if nothing is open). Returns `null`.

### 5.3 Events

Each event is a `Map<String, Object?>` with a `type` discriminator:

| `type` | Payload | Emitted when |
|---|---|---|
| `hubOpened` | `{"type": "hubOpened", "slug": "your-fanzone"}` | Hub view is presented (`slug` = configured `fanzoneSlug`) |
| `hubClosed` | `{"type": "hubClosed"}` | Hub view is fully dismissed |
| `gameOpened` | `{"type": "gameOpened", "slug": "summer-quiz"}` | Game sheet is presented (or replaced) |
| `gameClosed` | `{"type": "gameClosed"}` | Game sheet is dismissed |
| `externalLink` | `{"type": "externalLink", "url": "https://..."}` | A URL is handed to the system browser / OS |

Ordering guarantees:

- `hubOpened` … `hubClosed` MUST bracket every session.
- `gameOpened` / `gameClosed` MUST be properly nested inside a hub session.
- Closing the hub while a game is open MUST emit `gameClosed` before `hubClosed`.

### 5.4 Error semantics

All failures surface as `PlatformException` on the method channel. The SDK MUST NOT throw uncaught native exceptions across the channel boundary.

---

## 6. Android Back Button Behavior

On back press (system back gesture or hardware button), in order:

1. If the game toaster is open → close the toaster (emit `gameClosed`). The hub stays open.
2. Else if WebView A `canGoBack()` → `goBack()` in WebView A.
3. Else → close the full-screen view (emit `hubClosed`).

Implementations MUST use `OnBackPressedDispatcher` (androidx) rather than overriding `onBackPressed` directly, so predictive back keeps working.

iOS has no system back button; the hub MUST provide a native close affordance, and the sheet is dismissible by swipe-down (emitting `gameClosed`).

---

## 7. Cookie / Data-Store Sharing

WebView A and WebView B MUST share the same cookie and web storage so the game inherits any session state established in the hub.

### 7.1 iOS

- Both `WKWebView` instances MUST use the same `WKWebViewConfiguration.websiteDataStore = WKWebsiteDataStore.default()`.
- Both configurations MUST share a single **static** `WKProcessPool` instance held by the SDK for the process lifetime.

### 7.2 Android

- Cookies are process-global via `CookieManager.getInstance()`; the SDK MUST call `CookieManager.getInstance().setAcceptCookie(true)`.
- The SDK MUST call `CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)` on **both** WebViews.
- The SDK MUST flush cookies (`CookieManager.getInstance().flush()`) when the hub closes.

### 7.3 Persistence

Cookies MUST persist across `openGames()` sessions within the same app install (default persistent stores on both platforms). The SDK MUST NOT clear cookies or web storage in v0.1.

---

## 8. Safe Areas

The chromeless Fanzone (`chrome=0`) applies its own `env(safe-area-inset-*)` padding, so the hub is laid out **edge-to-edge** natively while the web content stays clear of the notch and home indicator:

- The hub view MUST lay out WebView A edge-to-edge (pinned to the view bounds, not the safe area) so the Fanzone fills the screen top and bottom. The SDK MUST disable the WebView's automatic content-inset adjustment and set an SDK-configurable background color (default: black), shown only during load; the web content keeps clear of system bars via its own `env(safe-area-inset-*)` padding.
- The game bottom sheet MUST inset its content from the bottom safe area and MUST NOT extend under the status bar (sheet max height SHOULD be ~90% of the screen).
- The native hub close affordance MUST remain inside the safe area.

---

## 9. Error & Offline Handling

- If a main-frame load fails in **WebView A (the hub)** (no network, DNS failure, HTTP error ≥ 400 on the initial document), the SDK MUST hide the WebView content and show a **native error view**: a short localized message ("Something went wrong" / no-connection variant) and a **Retry** button.
- Retry MUST reload the failed URL in the WebView.
- The error view in the hub MUST keep the native close affordance visible. In 0.1 the game sheet (WebView B) does not render its own error view; on load failure it simply stays dismissible.
- Transient sub-resource failures (images, XHR) MUST NOT trigger the error view.
- The SDK SHOULD show a native loading indicator until the first meaningful load commits.
- No automatic retries, no offline caching in v0.1.

---

## 10. Versioning & Distribution

- The SDK follows **Semantic Versioning 2.0.0** (`MAJOR.MINOR.PATCH`). The public API surface defined in § 2 and the platform channel contract in § 5 are the compatibility boundary: breaking either requires a MAJOR bump.
- Releases are tagged `sdk-vX.Y.Z` (e.g. `sdk-v0.1.0`).
- Distribution repository: **`fastoryapp/fastory-sdk-mobile`** (GitHub, **public, release-only**) — it receives the clean release package per version, tagged `sdk-vX.Y.Z`, with no development history (dev happens in the `fastory` monorepo). v0.1 ships the Flutter plugin; native Swift (SPM), native Kotlin (Maven), and React Native follow in later versions.
- This spec version: **0.2.0**. The public names in § 2 and the channel contract in § 5 are locked (they ship in third-party integrations); any later normative change requires a new spec version and a coordinated SDK release. Changes since 0.1.0: stories origins added to rule 1 (§ 4); hub and game WebViews are kept warm across sessions (behavioral); the consent hint is now `consent=0` on both hub and game URLs (§ 3.2/§ 3.3) — banner suppressed without asserting analytics consent; the `hubOpened` event carries the `fanzoneSlug` (§ 5.3). Changes in 0.1.2: the default `hubTabSlug` is `games` (was `games-app`). Changes in 0.1.3: closing the game sheet discards the played WebView (fresh state guaranteed, audio stops immediately) and the SDK preloads the hub's games via a read-only discovery query (§ 11 — Non-Goals renumbered to § 12). Changes in 0.1.4: preload discovery (§ 11.1) additionally collects direct game URLs — absolute http(s) URLs with an `/s/` path — from the embedded payload, covering hubs whose tiles are plain links rather than `Experience` components. Changes in 0.2.0: presenting a game sheet releases the warm pool and abandons the load in flight, and closing rebuilds it (§ 11.2) — warm games otherwise hold memory and graphics contexts away from the game on screen. Changes in 0.1.5: the staging stories origin is `https://staging.story.tl` (§ 4, § 11.1) — the SDK previously named a host the platform does not serve, so staging games failed rule 1 and were handed to the system browser.

---

## 11. Game Preloading & Fresh Game State (since 0.1.3)

Goal: tapping a game tile presents an **already-rendered** game (like the warm hub), and closing a game **actually ends it**.

### 11.1 Discovery

- After each completed hub load (including retries and in-place navigations), the SDK discovers the games of the current hub tab by evaluating a script against the hub document that reads the fanzone's embedded SSR payload (`__NEXT_DATA__`), in two passes: visible `Experience` tiles and `Crusher` blocks of the active tab (`fanzoneData`), in display order; then (since 0.1.4) any **direct game URL** — an absolute http(s) URL string whose path starts with `/s/` — found anywhere in the payload: hubs whose tiles are plain links (e.g. `website` buttons) reference games by direct URL, with no `Experience` component at all. Game URLs never appear in the hub DOM (tiles call `window.open` from JS), so the embedded payload is the only reliable source.
- The discovery script MUST be strictly **read-only**: no DOM mutation, no event listeners, no storage access, no behavior change. This is the sole exception to the no-JavaScript rule (§ 12).
- Component games replicate the web's own link construction (`{storiesOrigin}/s/{slug}?utm_source=fanzone`, § 3.1 origins: production `https://story.tl`, staging `https://staging.story.tl`, development falls back to the page origin); direct game URLs are collected verbatim — a tap would navigate to exactly that URL. All discovered URLs are augmented per § 3.3 and MUST be validated against § 4 — only URLs resolving to `OPEN_GAME_SHEET` may be preloaded (the payload scan may over-collect, e.g. `/s/` paths on foreign origins; § 4 validation is authoritative). Component games precede direct-URL finds, and duplicates of the same game keep the first occurrence, so hubs using `Experience` components keep their preload order.

### 11.2 Preloading

- Games are preloaded **sequentially** — at most one background load at a time — and never while a game sheet is presented, so preloading cannot compete with the hub or a live game.
- Per discovery, at most **12** games are loaded (bounding background data usage); the first **3** stay alive in a pool of prewarmed WebViews, the rest are released after loading (which still warms the HTTP disk cache, making their cold open fast).
- Pool priority: the game the player closed last, then hub display order. A lower-priority pooled game is evicted when a higher-priority one finishes loading.
- Opening a game with a pooled WebView MUST present it as-is (no reload — it is fresh by construction, § 11.3). A game without one falls back to a normal load.
- Presenting a game sheet MUST release the whole pool and abandon the load in flight (since 0.2.0). A pooled WebView is detached, so the engine throttles its timers — but it keeps its page, its textures and its graphics contexts resident, and every WebView shares one content process and therefore one memory budget. Warm games would otherwise take that budget away from the game on screen, which is measurable on WebGL/3D experiences. The sheet takes its own WebView out of the pool first, so opening stays instant.
- Closing the sheet MUST rebuild the pool released above, in the § 11.2 priority order (the game just closed first). Reopening a *different* game in the seconds that follow may therefore be a cold open — deliberate: a smooth game on screen outranks an instant second open.
- All preloaded WebViews and pending loads MUST be dropped under system memory pressure and when the configuration changes.

### 11.3 Fresh state on close

- Closing the game sheet MUST immediately silence and end the played game: media playback is paused at dismissal and the played WebView is discarded — its page (timers, audio, state) dies with it. Game state MUST NOT survive a close.
- After a close, the SDK re-preloads that game ahead of everything else, so reopening it is instant **and** lands on the start screen.
- Session state stored in cookies is unaffected (§ 7): fresh loads reuse the shared cookie store.

---

## 12. Non-Goals (v0.1)

Explicitly out of scope for v0.1 (candidates for v0.2+):

| Non-goal | Notes |
|---|---|
| Authentication / user identity | No token passing, no SSO between host app and Fanzone |
| Analytics | No SDK-side tracking; only `utm_source=sdk` attribution on game URLs |
| Push notifications | — |
| OTA / remote configuration | Configuration is compile-time via `configure` |
| JS ↔ native `postMessage` bridge | Planned for **v0.2** (game → native events, haptics, share) |
| JavaScript injection | The SDK MUST NOT inject behavior-modifying JS; the only permitted script evaluation is the read-only preload discovery query (§ 11.1) |
| Deep links into a specific game | `openGames()` always lands on the hub |
| Tablet-specific layouts | Phones first; tablets render the phone layout |
