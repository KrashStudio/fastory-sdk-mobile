# Fastory SDK v0.1 — QA Checklist

Run the full scenario list on each device of the matrix before sign-off.

## Device matrix

| # | Device | OS | Why |
|---|---|---|---|
| 1 | Recent iPhone (iPhone 15/16, notch or Dynamic Island) | Latest iOS | Safe areas, modern WebKit |
| 2 | Older iPhone (iPhone SE 2nd gen / iPhone X class) | iOS 15.x | Minimum supported iOS, small screen, older WebKit |
| 3 | Mid-range Android (e.g. Samsung Galaxy A series, 3-4 GB RAM) | Android 10-12 | Performance floor, OEM WebView variations |
| 4 | Recent Android (Pixel / Galaxy S series) | Android 14+ | Gesture navigation, predictive back, latest System WebView |

## Scenarios

### 1. Hub opening

- [ ] Tap the footer entry → full-screen hub appears with a loading state (no blank white flash).
- [ ] Hub is interactive quickly (target: content visible < 3 s on Wi-Fi, < 5 s on 4G).
- [ ] Hub shows the games tab content only (`chrome=0`: no Fanzone header/footer/cookie banner).
- [ ] `hubOpened` event is emitted exactly once per opening.

### 2. Game in the toaster

- [ ] Tap a game image → native bottom sheet slides up with WebView B.
- [ ] Game URL carries `embed=1`, a `utm_source`, and `consent=0` (verify via proxy/charles or event payload).
- [ ] Game is playable end-to-end inside the sheet (scroll, taps, keyboard if any).
- [ ] `gameOpened{slug}` then `gameClosed` events fire with the correct slug.
- [ ] Opening a second game after closing the first works (no dead WebView reuse).

### 3. Drag-to-dismiss

- [ ] Dragging the sheet down dismisses it and returns to the hub (hub state preserved, no reload).
- [ ] A partial drag released early snaps the sheet back open.
- [ ] Dismiss during game load does not crash or leak a playing audio/video.

### 4. Android back button (3 cases)

- [ ] Sheet open → back closes the sheet only; hub remains.
- [ ] Sheet closed, hub has navigation history (`canGoBack`) → back goes back inside WebView A.
- [ ] Sheet closed, no WebView history → back closes the full-screen view and returns to the app.
- [ ] Repeat with gesture navigation (device #4) and 3-button navigation (device #3).

### 5. External links

- [ ] A link to any non-fanzone.me `http(s)` origin opens in the system browser, not in the WebView.
- [ ] `mailto:` / `tel:` links open the system mail/dialer.
- [ ] `externalLink{url}` event fires with the target URL.
- [ ] Returning from the browser to the app restores the hub exactly where it was.

### 6. Offline / airplane mode

- [ ] Airplane mode ON, open hub → native error state with retry (no blank WebView, no crash).
- [ ] Airplane mode OFF, tap retry → hub loads.
- [ ] Cut network while a game loads in the sheet → no crash; the sheet stays dismissible (swipe down / back). (v0.1: the sheet has no error view of its own.)

### 7. Cookie persistence hub ↔ game

- [ ] Consent/session cookies set by the hub are visible in the game WebView (no second consent prompt; the `consent=0` hint suppresses the banner without asserting analytics consent).
- [ ] A game whose progress is cookie-backed keeps that session across close/reopen (in-memory game state intentionally resets — see § 9).
- [ ] Kill the app, reopen the hub → cookies persist across app restarts.

### 8. Rotation

- [ ] Rotate the hub portrait ↔ landscape: layout adapts, no reload loop, no lost scroll position.
- [ ] Rotate with the sheet open: sheet stays open and usable, game not reloaded.
- [ ] Rotate mid-load: no crash.

### 9. Preloading & fresh close (0.1.3)

- [ ] After the hub has been open a few seconds, tapping a game presents it near-instantly (already rendered, no long spinner).
- [ ] Close a game while it plays sound → audio stops immediately on dismiss.
- [ ] Play a few moves, close the sheet, reopen the same game → it is back on its start screen (never mid-session), and still opens instantly after a short wait.
- [ ] While a game is open, background preloading is paused (no visible jank or competing network spinners in the game).

### 10. Notch / safe areas

- [ ] Device #1: WebViews render edge-to-edge (Fanzone background fills the screen top and bottom — this is expected, not a bug); interactive web content pads itself clear of the Dynamic Island / notch and home indicator via its own safe-area padding.
- [ ] Native close affordance (✕) sits below the status bar when the hub or sheet is fully expanded.
- [ ] Device #4 with display cutout: same checks with gesture bar.

## Sign-off

| Device | Tester | Date | Result |
|---|---|---|---|
| 1 |  |  |  |
| 2 |  |  |  |
| 3 |  |  |  |
| 4 |  |  |  |
