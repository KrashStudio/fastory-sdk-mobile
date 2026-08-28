# Fastory SDK v0.4.1 — QA Checklist

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
- [ ] `hubOpened` event is emitted exactly once per opening — including the second and later
      openings, where the hub is already pre-warmed and the page is reused rather than reloaded.

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
- [ ] Airplane mode OFF, tap retry → hub loads. **On an app configured by `fanzoneSlug` only.**
      Configured by publishable key this fails by design in 0.4.0 — see § 11's own retry item and
      FASTORY-2904 — so run this one on the slug path, or you are recording a known gap as a defect.
- [ ] Cut network while a game loads in the sheet → no crash, and **since 0.4.0** the sheet renders its own error view with Retry; it stays dismissible (swipe down / back).
- [ ] **Airplane mode ON, open hub → the host receives `surfaceLoadFailed` with `surface=hub`, `reason=network`, and no `code`** (0.4.0, `SPEC.md` § 9.1). Read it in the demo's *Last error* section, which shows the machine code.
- [ ] **No `hubOpened` is emitted for that failed open, and no `hubClosed` when it is dismissed.** This is the inverse defect the 0.4.0 acceptance run caught on iOS: the event went out while the error view was on screen. Configure online so the key exchange resolves, *then* cut the network, *then* open — that is the exact shape.
- [ ] **Configure with a revoked key → `surfaceLoadFailed` with `reason=rejected` and `code=sdk_key_revoked`.** Repeat with a key whose workspace never declared this application's identifier → `code=sdk_application_not_allowed`, and with a well-formed key the API never minted → `code=sdk_key_unknown`. The three must be distinguishable from each other and from the airplane-mode case above; before 0.4.0 all four were identical.
- [ ] **Open a game, then open several more, on a good connection → no `surfaceLoadFailed` at all.** Routing a game or an external link cancels a navigation, and cancellations must never be reported as failures.

### 7. Session persistence, per surface

Rewritten in 0.4.0 alongside `SPEC.md` § 7. The old first item bundled two assertions — *"consent/session
cookies set by the hub are visible in the game WebView"* and *"no second consent prompt"* — and only the
second could ever pass: the hub and the game are different sites, and a game loaded with `embed=1` reads
no storage at all. So a tester who ticked that line proved the consent hint worked and, in the same
stroke, appeared to prove a session transfer that never happened. Split rather than deleted, because the
consent half is a real check and this is the one item that would have caught the spec defect.

- [ ] **Consent (unchanged, still valid).** Open the hub, then a game → neither shows a cookie banner of
      its own. That comes from the `consent=0` hint on both URLs, not from a shared cookie.
- [ ] A game whose progress is cookie-backed keeps that progress across close/reopen of **the same game**
      (in-memory game state intentionally resets — see § 9).
- [ ] Kill the app, reopen the hub → the hub's own cookies persist across app restarts.
- [ ] **Expected, do not file:** a game does not know anything the hub knows about the visitor. The two
      surfaces are independent, and until the identified modes of `SPEC.md` § 2.6 ship both are
      anonymous separately. Report it only if a surface loses *its own* state.

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

Issuing the keys below needs the **Mobile SDK add-on** on the workspace; without it the back-office
presents the feature instead of listing keys. The add-on gates management only, never the exchange,
and one item below checks exactly that.

The key is exchanged once per configuration, before the hub can open, so every failure below surfaces
on the **first** `openGames()` and not at `configure` time — except the two marked *local*, which are
rejected without any network call.

- [ ] Valid key for the environment → hub opens on the workspace's own fanzone, and `hubOpened`
      carries that fanzone's slug (not one you typed anywhere).
- [ ] *Local* — a key from the other environment (`fpk_live_…` in a staging build, or the reverse)
      is refused at `configure`, with no request sent. Verify via proxy that nothing left the device.
      **The two channels react differently and both reactions are expected**, so record which one you
      saw rather than filing the other as a defect: on **Flutter**, `configure()` throws a catchable
      `ArgumentError`; on **native iOS**, `configure(_:)` cannot throw, so a **debug** build trips an
      assertion and the app terminates on the spot, while a release build returns having changed
      nothing. `SPEC.md` § 2.1 is the normative rule and `README.md`'s *When `configure()` refuses
      your configuration* is the integrator-facing account of it.
- [ ] *Local* — **a refused `configure()` leaves the previous configuration in force.** Configure
      correctly, open the hub once, then re-`configure()` with a mismatched key and open again (iOS:
      release build, or the app dies on the assertion): the hub must open the **previous** fanzone,
      not report "not configured". Reporting a fresh install's behaviour here is the defect —
      "nothing is stored" is true and "you are back to unconfigured" is not.
- [ ] *Local* — **the refusal message never contains the key.** Read the full exception or console
      line on all three channels: it must say which rule was broken, and must not contain the key. A
      host logs a failed `configure`, so a key echoed here is a key in their crash reporter for
      nothing. Only the Dart message also names the environment expected; the two native ones say
      "this environment" — that is not a defect, do not record it as one.
- [ ] *Local* — a malformed key, and a bare prefix with nothing after it (`fpk_test_`), are both
      refused at `configure`, with the same reactions and the same message rule as above.
- [ ] Run the app with a bundle identifier / package name **not** declared on the key → refused with
      `sdk_application_not_allowed`. Check both platforms: iOS sends the bundle id, Android the
      package name, and a debug build with an `applicationIdSuffix` sends a different string.
- [ ] Remove the Mobile SDK add-on from the workspace, relaunch with the key still configured → the
      hub opens as before. Removing the add-on closes the back-office screen, it must never cut an
      app already in the field. Run this **before** the revoke below, while the key is still live,
      and re-enable the add-on afterwards — without it you cannot issue a replacement key.
- [ ] Configure a well-formed key that was never minted (`fpk_test_` followed by anything),
      relaunch → refused with `sdk_key_unknown`, **not** `sdk_key_revoked`. The API answers 401 for
      a key it does not know. Run it before the two key-state items below: it needs no back-office
      change and leaves the real key untouched.
- [ ] Revoke the key in the workspace settings, relaunch → refused with `sdk_key_revoked`.
- [ ] **Delete** the key in the workspace settings, relaunch → refused with `sdk_key_unknown` again,
      **not** `sdk_key_revoked`. A deleted key reads back as unknown rather than as revoked, and
      that is what an app already in the field meets when a key is removed instead of withdrawn —
      recording `sdk_key_revoked` here is the defect. This destroys the key, so run it after the
      revoke above and issue a replacement afterwards.
- [ ] Airplane mode at first `openGames()` → native error state with retry, never a blank WebView,
      and `surfaceLoadFailed` with `reason=network` and no `code`.
- [ ] **Then turn the network back on and tap Retry: the hub does NOT load, and that is the expected
      result on this path in 0.4.0** (FASTORY-2904). The key exchange's failure is remembered for the
      configuration that asked for it, so Retry re-shows the same error without calling
      `/sdk/auth/bootstrap` again — verify with a proxy that **no second request leaves the device**.
      Then call `configure()` again from the host, **give the exchange a moment**, and open once
      more: it must load. Pass the **same** configuration on both platforms — a second `configure()`
      re-arms an exchange whose previous outcome was a failure on either one, so varying `theme` for
      the Android half would only hide that (FASTORY-3006). Record both halves — a Retry that *did*
      work here would mean 2904 landed and this item needs rewriting, which is worth knowing either
      way.
- [ ] On Android, if that first open **still** shows the error view, open once more — it must load
      then. That is expected on this path, not a defect: an equal `configure()` leaves the previous
      failure readable there until the new exchange answers, so an open that starts inside that
      window is answered from it. iOS, and Android on a *changed* configuration, clear the outcome
      and make the open wait instead. Recording a single error view here as "the escape hatch does
      not work on Android" is the mistake this item exists to prevent — two in a row, with no
      request on the proxy, is the real defect. And neither item settles *which* call put the
      request on the wire, because `openGames()` asks the resolver on Android too: the proof is the
      request seen on the proxy, not the button pressed before it.
- [ ] Errors expose a machine-readable `code`. Branch on the code in the host app and confirm it
      arrives — the message is not a contract and may be reworded.
- [ ] Configured by key, the hub is **not** warmed up ahead of time (there is no URL until the
      exchange resolves): the first opening shows the loading state for the round trip. This is
      expected — check it is a loading state, not a blank screen.
- [ ] Kill and relaunch the app several times in a row → the exchange still succeeds. Rate limiting
      is per key and per address; a QA session behind one office address must not start failing.
      **If it does start failing, stop relaunching.** The third sanction blocks the address with no
      expiry, and only an operator lifts it — a tester who keeps going to "confirm" the failure
      locks the office out of the exchange for every later run.

### 12. postMessage bridge (0.4.0)

The whole point of this section is that the answers must be identical whether or not the deployed web
side speaks the bridge. Run § 1, § 2 and § 5 first; this section only adds what changes.

This section is the **only** place a real page reaching the bridge is verified: no unit suite can do
it, because a WebKit content process does not load in a headless test host. Tracked by FASTORY-2877,
together with its prerequisite — the Fanzone posting `fastory:ready`.

Enable the diagnostics first — iOS
`log stream --level debug --predicate 'subsystem == "io.fastory.sdk"'`, Android
`adb shell setprop log.tag.FastorySDK DEBUG` — so an ignored message is visible instead of invisible.

- [ ] **No regression with the bridge idle.** Against a fanzone whose web side posts nothing, § 1,
      § 2 and § 5 behave exactly as they did on 0.3.0: same hub, same game sheet, same external
      links, same five events in the same order. This is the acceptance criterion; run it first.
- [ ] Paste
      `window.webkit?.messageHandlers?.fastory?.postMessage(JSON.stringify({v:1,type:'fastory:ready'}))`
      (iOS, Safari Web Inspector) or the `window.fastory.postMessage(...)` equivalent (Android,
      `chrome://inspect`) into the hub → the host app receives one `bridgeMessage` event with
      `type: 'fastory:ready'`.
- [ ] Same from inside a **game** sheet → also received. The bridge is on every SDK WebView, not
      only the hub.
- [ ] Post `{"v":2,…}`, then `{"v":1,"type":"nope"}`, then the string `not json` → **nothing**
      reaches the app, nothing crashes, and each drop appears once in the debug log with its reason.
- [ ] While a game is open, post a message and then tap a game tile / an external link → the game
      sheet and the browser hand-off behave exactly as in § 2 and § 5. A message must never stand in
      for a navigation decision.
- [ ] Turn the diagnostics back off (iOS: stop the stream; Android:
      `adb shell setprop log.tag.FastorySDK ""`) and confirm a release build logs nothing — the SDK
      ships inside the partner's app and must stay silent there.

### 13. Identity (0.4.0)

`SPEC.md` § 2.6. Only `anonymous` resolves in this release, so most of this section is about what must
**not** happen. Run § 1 first on an app that never calls `identify` — that path is unchanged and any
difference there is a regression, not a new feature.

- [ ] An existing integration that never calls `identify` behaves exactly as before: hub opens, games
      open, the five original events fire. Nothing about identity is required to use the SDK.
- [ ] Call `identify(anonymous)` at launch, open the hub, kill the app, relaunch, call it again → the
      fan is the same one (verify via the fanzone's own visitor state, e.g. a cookie-backed game
      progress that survives). A **new** visitor on the second call is the bug this checks for.
- [ ] `identityResolved` fires **once** per resolution, and **before** `hubOpened`. Call
      `identify(anonymous)` then `openGames()` and confirm the order in your event log. Calling
      `identify(anonymous)` a second time fires **no** second event.
- [ ] Ask for a reserved mode (`fanId`, or `hostToken` with any JWT) → the call fails with
      `identify_mode_unavailable`, and **nothing else changes**: no browser opens, no WebView appears,
      the hub still opens, and the fan is still the fan they were. A reserved mode must not act as a
      silent sign-out.
- [ ] `hostToken` with an empty or whitespace JWT → `invalid_host_token`, again with no side effect.
- [ ] `identify` before `configure` → `not_configured`, the same code `openGames()` uses.
- [ ] `logout()` on an app that never called `identify` → completes, changes nothing, no crash.
- [ ] **The host app's own session survives `logout()` — the check that matters most.** Sign in to the
      *partner's own* web content (their own WebView, their own site, anything cookie-backed outside
      Fastory), then call `Fastory.logout()`, then return to that content. **You must still be signed
      in.** A failure here means the SDK reached a store it shares with the host app, which would sign
      the partner's users out of the partner's own services. Run it on both platforms — the stores are
      shared on both, for different reasons.
- [ ] After `logout()`, reopen the hub → it loads fresh (a cold open is expected: the warm hub and the
      preloaded games are dropped, since they were rendered for the previous fan) and shows no trace of
      the previous visitor.
- [ ] Repeat the previous two on iOS 15 or 16 as well as a recent iOS: erasure is enumerated per origin
      on every version, with no iOS-17-only path, so the two must behave identically.
- [ ] **Inspect the cookie jar after `logout()`, don't infer it from the UI.** The fan session cookies
      are `httpOnly` **and** `Partitioned`, so no page script can confirm they are gone and platform
      support for expiring partitioned cookies is uneven — this is the one item in the section that a
      unit test genuinely cannot stand in for. Use a proxy or the platform's own inspector on both
      OSes, and check the fanzone **and** story origins.
- [ ] A host that switches `environment` at runtime must call `logout()` **before** re-configuring
      (`SPEC.md` § 2.6.1). Do it in the wrong order once and confirm the documented consequence — the
      previous environment's cookies survive — so the rule is known to be load-bearing rather than
      decorative.
- [ ] No `identify` call ever blocks the UI: the hub stays interactive and nothing janks while one is in
      flight.

### 14. Bridge reply channel (0.4.0)

The reply channel is where a device pass is worth the most, because two of its outcomes look the same
from a page: *"the SDK refused to answer me"* and *"there is no SDK here"*. Only the debug log tells
them apart, so enable the diagnostics of § 12 before starting and keep them running throughout.

Run § 12 first — this section assumes the receive-only channel is verified, and its first item is that
that verification is still true.

Paste this helper into the WebView's console (Safari Web Inspector on iOS, `chrome://inspect` on
Android) and use `ask(...)` in the items below:

```js
window.ask = async (type = 'fastory:user-token', id = String(Date.now()), extra = {}) => {
  const json = JSON.stringify({ v: 1, type, requestId: id, ...extra });
  if (window.webkit?.messageHandlers?.fastoryRequest) {
    return JSON.parse(await window.webkit.messageHandlers.fastoryRequest.postMessage(json));
  }
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('no reply')), 1000);
    window.fastoryRequest.addEventListener('message', function on(e) {
      const r = JSON.parse(e.data);
      if (r.requestId !== id) return;
      clearTimeout(t); window.fastoryRequest.removeEventListener('message', on); resolve(r);
    });
    window.fastoryRequest.postMessage(json);
  });
};
```

- [ ] **No regression with the reply channel idle.** Against a fanzone whose web side never asks
      anything, § 1, § 2, § 5 and § 12 behave exactly as they did on 0.3.0. This is the acceptance
      criterion; run it first, on both platforms.
- [ ] With **nothing set** by the host, `await ask()` resolves with `ok: false` and
      `error.code === 'unavailable'`, and it echoes the `requestId` you sent. Not a rejected promise,
      not a hang — an answer.
- [ ] Call `Fastory.setBridgeReply(userToken, {token: 'test-token'})` from the host app, then
      `await ask()` → `ok: true` and `payload.token === 'test-token'`, with the same `requestId` back.
- [ ] Repeat inside a **game** sheet, and inside a **preloaded** game (open a game, close it, open
      another) → answered in all three. The reply channel is on every SDK WebView, like § 12's.
- [ ] Clear it — `Fastory.setBridgeReply(userToken, null)` — then `await ask()` → back to
      `unavailable`. A cleared answer is stated, never silent.
- [ ] **The revocation points (§ 13.8.6, since 0.4.0), one at a time, each from a set answer.** Set
      `{token: 'test-token'}`, confirm `await ask()` returns it, then:
      **(a)** `Fastory.logout()` → `await ask()` answers `unavailable`. Do it once having *never*
      called `identify()`, which is the only shape that exists today;
      **(b)** re-set the answer, `Fastory.configure(…)` with a **different** configuration (switching
      `theme` is enough) → `unavailable`;
      **(c)** re-set the answer, `Fastory.configure(…)` with the **same** configuration → still
      answered with the token. Revoking here would make a harmless call destructive.
      This is the § 13.8.6 contract end to end, and no automated check can reach it: the unit suites
      assert the revocation, never that a real page then reads `unavailable`.
- [ ] `await ask('fastory:nope')` → `unsupported`. `await ask('fastory:ready')` → also `unsupported`:
      a receive-only type is not answerable, which is the disjoint-registry rule from the page's side.
- [ ] Malformed requests, one at a time — no `requestId`, a blank one, `{"v":2,…}`, and the raw string
      `not json` (post it directly rather than through `ask`) → each answers `malformed`, nothing
      crashes, and each appears once in the debug log with its reason.
- [ ] **The gate that matters: a sub-frame must not be answered.** In a game that embeds a
      cross-origin `<iframe>`, run `ask()` from **inside the iframe's** console context. On iOS the
      promise must reject with no envelope; on Android `window.fastoryRequest` must not exist there at
      all. Either way the log names an unrecognised caller. A `payload.token` reaching an iframe is a
      credential leak, not a cosmetic failure — treat it as a release blocker.
- [ ] While a request is in flight, tap a game tile and an external link → § 2 and § 5 behave
      unchanged, and the host app receives **no** event for the request. Answering is not an event.
- [ ] **Android WebView too old.** On a device (or emulator image) whose WebView predates
      Chrome 85, `window.fastoryRequest` is absent and the page falls back to anonymous without
      erroring. The log says the channel was not attached, and § 1, § 2 and § 12 still pass.
- [ ] Switch `environment` at runtime (staging → production) and ask again from the new hub → answered
      for the new environment's origins only. A listener attached under the previous configuration must
      not answer under the current one.
- [ ] **Time the round trip on the device, once per platform.** In the console, `const t = performance.now(); await ask(); performance.now() - t` a handful of times with an answer set. The unit suites assert § 13.5's 16 ms budget in-process, which § 13.5 itself calls a tripwire and not a measurement — this is the only place the JS → native → JS transport is actually timed. Report the figures in the sign-off rather than only ticking the box; a first call slower than the rest is expected (channel warm-up) and is not a failure.
- [ ] Turn the diagnostics back off and confirm a release build logs nothing, as in § 12.

### 15. Initialisation cost and threading (0.4.0)

**This section is the only proof that exists for FASTORY-2883's budget.** The change is in the tree and
the deferral is unit-asserted, but *no number has been measured on a device* — the acceptance criterion
"the budget is met, measured on a real device, and the figure is published" is unmet until the two
measurements below are filled in. Treat it as unverified, not as covered by the suites.

- [ ] **Measure `configure()` on the main thread, per platform, and record the figure.** Wrap the call
      — iOS: `let t = CFAbsoluteTimeGetCurrent(); Fastory.configure(config); (CFAbsoluteTimeGetCurrent() - t) * 1000`;
      Android: `SystemClock.elapsedRealtimeNanos()` either side — in the demo's own launch path, on the
      **slug** path (every production integrator) and again by **key**. The epic's budget is **16 ms**.
      Report the numbers in the sign-off; a box ticked without them proves nothing.
- [ ] **The host's first screen is not measurably delayed.** Launch the demo 5 times with the SDK
      configured and 5 times with the `configure()` call commented out, timing to first frame
      (Xcode's *App Launch* template / `adb shell am start -W`). The two sets should overlap.
- [ ] **The hub still opens instantly.** Wait for the demo's first screen, then tap Games: the hub
      appears already rendered, exactly as on 0.3.0. This is the half the deferral could have broken —
      a startup gain paid back as open latency is not a gain.
- [ ] **A background launch warms nothing.** Configure the SDK from a background entry point (iOS: a
      background fetch / `BGAppRefreshTask`; Android: a `WorkManager` job or a boot receiver) and
      confirm no hub WebView is built until the app is brought to the foreground.
- [ ] **`configure()` from a background thread does not crash** (§ 2.7). iOS: `DispatchQueue.global().async { Fastory.configure(config) }`.
      Android: `thread { Fastory.configure(config) }`. Then do it **twice**, the second time with a
      *different* configuration, which is the case that reaches the WebView teardown — before 0.4.0
      this raised `A WebView method was called on thread …` and took the host app down. Repeat with
      `identify`, `logout`, `close` and `setBridgeReply`; each must behave as it does from the main
      thread, with its callback still arriving on the main thread.
- [ ] **Known hole, do not report it as new: `logout()` with the hub open** (FASTORY-2913). Sign in,
      open the hub, call `logout()` while it is on screen, close it, reopen: the previous fan's screen
      comes back, because the hub is kept for reuse *after* the erasure ran. The cookies are gone —
      check the jar as in § 13 — so what survives is the rendered page, not the session. 0.4.0 closed
      the same shape on the configuration axis only.
- [ ] **`openGames()` from a background thread is the one that may fail** — it is main-thread-only by
      contract (§ 2.7). Confirm the demo never calls it off the main thread; nothing here asks you to
      make it work.

### 16. Opening the games twice (0.4.0)

**Never observed on a device, in either direction.** FASTORY-2905 was established by reading the
manifest and the call path, and the fix is unit-asserted on both platforms — but nobody has yet
watched two hubs stack, nor watched them stop. Android is where the defect was; run it on iOS anyway,
which is the platform the guarantee was copied from.

- [ ] **Double-tap the Games entry, fast.** One hub appears. The log shows exactly **one `hubOpened`**,
      not two — the count is the assertion here, the screen alone cannot tell one hub from two.
      **Turn TalkBack / VoiceOver off for this one**: with a screen reader on, a double tap is a
      single activation, so the gesture cannot produce the two calls being tested. Re-enable it for
      the accessibility pass below.
- [ ] **Close it once.** You land back in the demo, not on a second hub. Exactly one `hubClosed`.
- [ ] **Android, same tap with the back gesture instead of the close button** — § 6's third case, but
      after a double tap. One back press must leave the hub, not reveal another one underneath.
- [ ] **Tap Games, then close within the same second.** The hub either never appears or appears and
      leaves immediately; it must not be sitting there afterwards. This is the launch window, where
      Android has no Activity to finish yet.
- [ ] **Accessibility of that refused launch.** Same sequence with TalkBack on: the hub Activity is
      created and finished before it draws anything, so it can paint one frame of its opaque theme
      and steal focus. Confirm focus comes back to the host's Games entry and is not left stranded.
      Report what you observe either way — nothing automated covers this.
- [ ] **Android, a hub whose launch is refused outright.** Call `openGames()` from a background entry
      point (a `WorkManager` job, a push handler) with an application `Context`. Android 10+ refuses
      the start with a logcat line and no exception. Nothing opens — expected. Then bring the app to
      the foreground, wait ~10 s and tap Games: **it must open.** A reservation that outlived a
      launch that never happened would make the SDK mute for the life of the process.
- [ ] **Android, memory: no WebView is left behind.** Double-tap Games, close, then repeat the whole
      sequence 10 times, watching `adb shell dumpsys meminfo <package>` — the `Views` and native heap
      figures must come back to roughly where they started. A stacked hub used to leak one WebView per
      stack, so a 10× loop is what makes it visible.
- [ ] **Rotate, then tap Games again.** A recreated hub Activity still counts as one hub: the second
      tap must do nothing. (The manifest handles rotation itself, so force it with a locale change or
      *Don't keep activities* in developer options to actually destroy and rebuild it.)

## Sign-off

| Device | Tester | Date | Result |
|---|---|---|---|
| 1 |  |  |  |
| 2 |  |  |  |
| 3 |  |  |  |
| 4 |  |  |  |
