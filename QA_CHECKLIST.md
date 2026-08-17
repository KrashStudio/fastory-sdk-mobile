# Fastory SDK v0.3.0 — QA Checklist

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
- [ ] Cut network while a game loads in the sheet → no crash; the sheet stays dismissible (swipe down / back). (The sheet still has no error view of its own — see `README.md` known limitations.)

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

### 11. Configuration by publishable key (0.3.0)

Only for apps configured with `publishableKey`. Apps still passing `fanzoneSlug` skip this section —
that path calls no endpoint and is unchanged; run § 1 against it once to confirm.

The key is exchanged once per configuration, before the hub can open, so every failure below surfaces
on the **first** `openGames()` and not at `configure` time — except the two marked *local*, which are
rejected without any network call.

- [ ] Valid key for the environment → hub opens on the workspace's own fanzone, and `hubOpened`
      carries that fanzone's slug (not one you typed anywhere).
- [ ] *Local* — a key from the other environment (`fpk_live_…` in a staging build, or the reverse)
      is refused at `configure`, with no request sent. Verify via proxy that nothing left the device.
- [ ] *Local* — a malformed key, and a bare prefix with nothing after it (`fpk_test_`), are both
      refused at `configure`.
- [ ] Pass `workspaceId` alongside a key belonging to a **different** workspace → refused. Without
      this cross-check the app would silently open someone else's fanzone; confirm it does not.
- [ ] Run the app with a bundle identifier / package name **not** declared on the key → refused with
      `sdk_application_not_allowed`. Check both platforms: iOS sends the bundle id, Android the
      package name, and a debug build with an `applicationIdSuffix` sends a different string.
- [ ] Revoke the key in the workspace settings, relaunch → refused with `sdk_key_revoked`.
- [ ] Airplane mode at first `openGames()` → native error state with retry, never a blank WebView.
      Turn the network back on, retry → hub loads.
- [ ] Errors expose a machine-readable `code`. Branch on the code in the host app and confirm it
      arrives — the message is not a contract and may be reworded.
- [ ] Configured by key, the hub is **not** warmed up ahead of time (there is no URL until the
      exchange resolves): the first opening shows the loading state for the round trip. This is
      expected — check it is a loading state, not a blank screen.
- [ ] Kill and relaunch the app several times in a row → the exchange still succeeds. Rate limiting
      is per key and per address; a QA session behind one office address must not start failing.

## Sign-off

| Device | Tester | Date | Result |
|---|---|---|---|
| 1 |  |  |  |
| 2 |  |  |  |
| 3 |  |  |  |
| 4 |  |  |  |
