# Changelog

All notable changes to the Fastory Mobile SDK are documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [SemVer](https://semver.org),
tags `sdk-vX.Y.Z`.

## 0.4.5

Twenty-one fixes and seven changes: fifteen fixes and three changes in what the SDK does, and a
documentation pass. No public name moves and nothing you call changes signature. Behaviours you may
have worked around do change: a single `close()` on iOS returns the fan to your app even with a game
open, `close()` on Android reports the game's closing before the hub's, `openGames()` on Android
works again right after a close, a hub Android rebuilds in place no longer reports a close and a
reopen, nor does a game open on it, a refusal whose body is
not JSON now carries its status, the native error view speaks the fan's language and the wait after
its *Retry* is spoken to a screen reader, a hub configured by key is ready before the first tap, a native Android app calls
`Fastory.configure(context, config, listener)`, a bridge message that is not strict JSON is ignored
on Android as it is on iOS, a bridge message that repeats a name, holds `-1e309` in an object, holds
a number iOS cannot read or spells one name two ways reads the same on both platforms, the Android
keep rules protect the bridge on their own, and on iOS the
hub and the game sheet keep clear of the status bar and the home indicator. The rest is what the
documentation tells you, corrected in ten places where it said something wrong, incomplete or
contradictory, found by reading it the way an integrator does.

### Fixed

- **Configured by key, the first opening of the hub is now as fast as the second.** Until now only
  the deprecated `fanzoneSlug` path prepared the hub ahead of time; a hub configured by
  `publishableKey` had no page to prepare until the exchange answered, and nothing was prepared once
  it had. Your fan's first tap therefore always loaded the hub cold, under a loading indicator, while
  every later tap found it ready. The SDK now prepares the page as soon as the exchange resolves,
  behind the same gate as before — never while your app is drawing its first screen, never on a
  background launch — so the first tap finds it ready too. A failed exchange prepares nothing and
  tells you nothing new: the first tap loads cold and reports `FastorySurfaceLoadFailed` for itself,
  exactly as it did. An `identify()` or `logout()` that lands before the page is ready cancels it,
  and one that lands after drops it, so a fan never sees a page rendered for a previous session.
  Nothing prepares a new page after that transition — the SDK subscribes to the exchange once, at
  `configure` — so the first opening after a `logout()` loads cold, as it always has, on both paths.
  Nothing to change on your side.
- **A prepared page that failed to load can no longer be presented.** A prepared page whose load
  failed was already discarded, but a turn late — and a tap landing in that turn presented an empty
  view under a loading indicator that never went away. The page now leaves the slot the instant the
  failure is observed, so that tap loads cold like any other.
- **A refusal whose body is not JSON now reaches your app with its status.** When something in front
  of our API — a proxy, typically — answered the publishable-key exchange with an error page instead
  of JSON, `surfaceLoadFailed` reported `reason: unknown` with a null `code` and a null `statusCode`:
  your app learned neither the status nor that anything had answered and refused. The guide has
  promised `http_<status>` for exactly that case since 0.4.0, and the fallback existed in the code; it
  sat behind a check that required the body to be JSON, so the one answer it was written for could
  never reach it. Both platforms now read the status before they require the body to parse: a 502
  HTML page, an empty body and a response with no body at all are all `reason: rejected` with
  `code: http_<status>`, on iOS and Android alike. A refusal whose JSON body carries an empty `code`
  also falls back to the status now on iOS, as it already did on Android. A successful status whose
  body cannot be read is still `unknown` — that is a response the SDK cannot use, not a refusal — and
  on Android a successful status with no body at all moves from `network` to that same `unknown`,
  matching iOS. If you alert on `code`, expect `http_<status>` values you were not receiving before,
  in situations where you used to see `unknown` (or, on Android for a refusal with no body at all,
  `network`).
- **On iOS, `error.localizedDescription` now names the rule a refused configuration broke.**
  `FastoryConfigError`, thrown by `try config.validate()`, described itself only through
  interpolation, so the idiomatic `catch { log(error.localizedDescription) }` printed "The operation
  couldn't be completed." followed by a case number. It now conforms to `LocalizedError`, and
  `localizedDescription`, `"\(error)"` and `description` all return the same sentence — for example
  `publishableKey does not belong to this environment`. Nothing changes for Flutter, whose
  `ArgumentError` already carried the rule.
- **Android: reopening the games right after closing them works again.** Calling `openGames()` in
  the seconds after the hub was closed — by `close()`, by the close button or by the back gesture —
  did nothing until the platform had finished destroying the previous hub, which can take several
  seconds: no hub, no event, nothing reported to the host. The hub now hands its slot back the moment
  it is dismissed, so the next `openGames()` opens a hub immediately, and `hubClosed` is emitted at
  that moment rather than when the Activity is destroyed — calling `openGames()` from the `hubClosed`
  callback opens a new hub. Two consequences follow. A hub that has been dismissed emits nothing
  further: a page that fails, or finishes loading, while the hub leaves the screen produces no
  `surfaceLoadFailed` and no `hubOpened`. And a hub reopened before the platform destroyed the
  previous one starts from a cold page; the one after it is warm again. A second `openGames()` while
  a hub is still launching is still absorbed, as before. iOS was not affected.
- **iOS: one `close()` now returns the fan to your app even while a game is open.** With a game sheet
  on screen, a single `close()` used to dismiss the sheet only: the hub stayed up, `hubClosed` was
  never emitted, and a second call was needed — a workaround no document described, and one that
  closed the hub by mistake whenever no game was open. `close()` now dismisses the game sheet and then
  the hub, emitting `gameClosed` then `hubClosed`, as the specification always required. A `close()`
  that lands while the sheet is still animating in is honoured too, once the animation ends. With the
  hub alone on screen, nothing changes. If you had added a second `close()` to work around this,
  remove it.
- **Android: `close()` with a game open now emits `gameClosed` before `hubClosed`.** The hub was
  finished with the game sheet still up, so `hubClosed` went out at once and `gameClosed` only when
  the platform tore the sheet down with the hub, seconds later on a slow device — the reverse of the
  order the specification requires, and of what iOS emits. One `close()` now dismisses the sheet and
  then the hub, so `gameClosed` and `hubClosed` leave in that order, one right after the other.
  With the hub alone on screen, and on the back gesture, nothing changes. If your app reconciles its
  own state on `hubClosed` and was tolerating a `gameClosed` arriving after it, that tolerance is no
  longer needed.
- **Android: a hub the system rebuilds in place no longer reports a close and a reopen.** When
  Android destroyed and rebuilt the hub's screen without the fan leaving it — a change of device
  language or display size, or the *Don't keep activities* developer option; rotation was never
  affected — your app received `hubClosed` immediately followed by `hubOpened`, for one hub that
  never left the screen. The rebuilt hub now continues the same presentation and emits neither event;
  an `openGames()` called while the system has not rebuilt it yet asks for that hub again. A game
  open on the hub at that moment is covered by the next entry. Closing the hub afterwards — `close()`, the close button or the back gesture —
  emits one `hubClosed`, as for any hub, including a `close()` that arrives while your app is in the
  background and the system has not rebuilt the hub yet. If you counted openings, or discarded the extra pair,
  that correction is no longer needed. iOS was not affected.
- **Android: a game open on a hub the system rebuilds in place no longer reports a close and a
  reopen.** The game sheet was rebuilt with the hub, and your app received `gameClosed` immediately
  followed by `gameOpened` for a game the fan never left. The rebuilt sheet now continues the same
  game and emits neither event. Its page still reloads with the screen, so the fan's progress in the
  game starts over, as before; a reload that fails reports `surfaceLoadFailed`. Ending the game
  afterwards — its close button, the back gesture, a swipe down, or `close()` — emits one
  `gameClosed`, before `hubClosed` when the hub closes with it; a `close()` that arrives while your
  app is in the background and the system has not rebuilt the hub yet emits `gameClosed` then
  `hubClosed` too. If you discarded the extra pair, that correction is no longer needed. iOS was not
  affected.
- **Android: the SDK's R8 rules now keep the annotation the bridge needs, not only the method.**
  `addJavascriptInterface` exposes a method only while its `@JavascriptInterface` annotation is still
  visible at runtime. The SDK's consumer rules kept the method and left the `RuntimeVisibleAnnotations`
  attribute to your own configuration: with AGP's default rules, or with any dependency that keeps
  annotation attributes, nothing was lost — but a host whose hand-written R8 configuration keeps no
  annotation attributes had a silent bridge in release, the method present and unreachable from the
  page. The SDK now ships `-keepattributes RuntimeVisibleAnnotations` with its rules; nothing to change
  on your side, and the FAQ's answer that you need no keep rule of your own now holds for that case
  too.
- **The wait after *Retry* is now spoken by a screen reader, on the hub and in the game sheet.** When
  the hub could not open and the fan pressed *Retry* on the native error view, that view disappeared
  — and VoiceOver's or TalkBack's focus with it — while a loading indicator with no label took its
  place for as long as the exchange ran; nothing was said when the hub finally opened or when the
  error view came back, and on Android the focus fell on a close button that had no label. The game
  sheet, which shows the same error view when a game cannot load, was as silent, with no indicator
  at all while the game reloaded. Pressing *Retry* now announces *Loading…* on either surface — the
  game sheet gains a loading indicator for that wait, and only for it — the indicator carries that
  label for the whole wait, and the end of the wait is announced too — *Content loaded.* when the
  hub or the game opens, the error message when it does not. On both platforms the screen reader's
  focus moves onto the indicator when the wait begins; when it ends, VoiceOver starts the screen
  over and TalkBack hears the announcement where it stands. The hub's close button on Android now
  carries the same *Close* label and button role as the game sheet's, so a focus that lands on it
  reads as one. The texts, and the game sheet's *Close* label on Android, follow the error view's
  language rule — the fan's device language among English, French and Spanish, then your configured
  `locale`, then English. On Android they are two
  new string resources, `fastory_sdk_loading` and `fastory_sdk_loaded`, which your app may redefine
  under the same rule as the four existing ones. Nothing to change in your code.
- **Android: a bridge message that is not strict JSON is now ignored, as it is on iOS.** The
  Android parser read a little more than JSON: a version written `01`, `0x1` or `+1` was accepted as
  `1`, and a comment, an `=` in place of a `:`, an unquoted value or text after the closing brace
  were read past; so were an escaped lone surrogate, a positive number too large to be finite and
  nesting deeper than 512 levels, all three refused on iOS. So a message iOS ignores as malformed
  reached an Android host as `bridgeMessage`, and the same request on the reply channel was answered
  instead of refused as `malformed`. Both channels now judge the text by the JSON grammar before
  reading it, so the two platforms decide every one of these forms the same way: the version is an
  integer as JSON writes one, and the document is JSON and nothing else. A leading byte order mark
  is still skipped, as on iOS. Every envelope `JSON.stringify` produces from a well-formed string,
  nested no more than 512 levels deep, is unaffected. If your web content builds the envelope by
  hand and leaned on that leniency, Android now gives it the silence iOS always did — correct the
  envelope, which iOS already required.
- **A bridge message that repeats a name, or holds a negative number too large to be finite, now
  reads the same on Android and iOS.** Both forms are valid JSON and the two platforms read them
  differently. A name repeated within one object, as in `{"v":1,"v":2,…}`, was read at its first
  occurrence on iOS and at its last on Android, so the version, the `type`, the `requestId` or a
  payload value could differ by platform and a message one of them ignored reached the host on the
  other. Android now keeps the first occurrence, as iOS always did. A number such as `-1e309` held
  by an object member was refused on Android and reached an iOS host as negative infinity; iOS now
  refuses it too: ignored on the receive-only channel, answered `malformed` on the reply channel.
  As an array element it is still read on both. `JSON.stringify` writes neither form, so web
  content that builds its envelope with it is unaffected.
- **Two more bridge messages read the same on Android and iOS: a number iOS cannot read, and two
  names that differ only in how a character is encoded.** iOS refuses some numbers that are valid
  JSON and that Android read: an integer written in full past about 3.4 × 10^165, such as a `1`
  followed by 166 zeros, positive or negative; a number written with more than 17 digits whose scale
  iOS cannot hold, such as `0.` followed by 128 zeros and a `1`; and a number whose exponent
  takes more than four characters, sign included, such as `1e-0001`. Such a message was ignored on
  iOS, or answered `malformed` on the reply channel, and reached the host on Android; Android now
  refuses it too, wherever the number stands. The same value written with a short exponent, such as
  `1e166`, is read on both. Separately, two names of one object that are the same text written
  differently — `é` as one character and as `e` followed by a combining accent, or the Kelvin sign
  and the letter `K` — were two keys on Android and one on iOS, holding either value from one
  message to the next. Both platforms now read them as one name repeated: the first occurrence wins,
  spelling included, as it already did for a name repeated letter for letter. Names that are only
  compatible, such as the ligature `ﬁ` and `fi`, stay two. `JSON.stringify` writes none of these
  numbers; it does write both spellings of a name when your object holds both, and the first one it
  writes is the one your host now receives on both platforms.
- **A game page does read and write storage — its own.** The guide, the specification and the notes
  on 0.4.0 said a game loaded with `embed=1` "reads no storage at all". Measured on the published
  package, it does what any page does: it reads and writes its own cookies and web storage, on its
  own site. What it does *not* read there is a session — it asks its host page for one, and in an
  SDK WebView it has no host page — so the hub and the game still know nothing about each other, and
  the isolation the earlier releases established holds. If you declare the data your app stores,
  count the game's own cookies and web storage as well as the hub's.
- **"Once per configuration" is only true of a key exchange that succeeded.** The guide said the API
  host was reached "once per configuration". A failed exchange is not remembered as final, and the
  guide now says how each platform re-runs it: on Android the next `openGames()` asks again by itself,
  so a network incident at configuration time costs a second request with no tap; on iOS the hub shows
  the error view from the remembered failure and the second request leaves on the fan's Retry. Only a
  configuration whose exchange succeeded sends nothing more until you configure again. The behaviour
  is unchanged and intended; the sentence was too absolute for anyone sizing their calls or reading
  their own logs.
- **The specification dates the staging stories host to the version that shipped it.** It dated the
  switch to `https://staging.story.tl` to a 0.1.5 that never existed — the tags go from 0.1.4 to
  0.2.0 — while the note added to the 0.1.1 entry below said 0.2.0. The specification now says 0.2.0
  as well.
- **The 0.2.0 entry below now says its install instruction was replaced.** It still tells you to add
  the package with `from:`, the range 0.4.1 asked you to leave because it spans every 0.x minor and
  this line ships source breaks in minors. Its text stays as the record of that release and carries a
  note pointing at the 0.4.1 instruction — it was the one entry that still gave the old instruction in
  the clear.
- **The 0.4.4 entry below says where its four corrections actually were.** It announced them as "the
  availability note, both quickstart snippets and the configuration reference". Three are in the root
  `README.md` — the availability note, the Flutter quickstart's comment and the configuration
  reference — and the fourth is in the Flutter plugin's own `README.md`; the Swift quickstart never
  carried the note. A reader who re-checked one file saw three of the four.
- **The specification's Kotlin signatures describe the Kotlin that ships.** `SPEC.md` § 2.3 declared
  `FastoryEnvironment` as a sealed class whose `Development` case carried the base URL. The shipped
  type is an enum — `PRODUCTION`, `STAGING`, `DEVELOPMENT` — and the URL travels as
  `developmentBaseUrl` on `FastoryConfig`, as the same section's `FastoryConfig` and the
  configuration table already said; code written from the old block did not compile. § 2.2 also
  names `invalidIdentityMode`, a case `FastoryIdentifyError` has always had on Swift and whose code
  § 5.4 already listed. Three smaller corrections travel with it: `locale` is documented as
  forwarded to the game URLs as well as the hub's, and as the error view's fallback language; the
  plugin's iOS notes say the error view follows the fan's device languages, then your configured
  `locale` — not the language your app runs in; and the demo's notes name the back-office tab that
  holds the publishable keys, *Mobile SDK*, rather than a tab that does not exist.
- **iOS: the hub and the game sheet keep clear of the status bar and the home indicator on every
  iPhone.** On an iPhone with a notch or a Dynamic Island, the hub's first frame — the top of
  whichever tab it opened on — was painted under the status bar, and could stay there until the fan
  scrolled; the game sheet's bottom edge, a game's main button typically, sat under the home
  indicator. The page was left to pad itself from the insets WebKit reports, and WebKit reports them
  to a page only after its first layout when the load began off screen, which is always the case
  for the page the SDK prepares ahead of the tap. Both surfaces are now laid out inside the safe
  area natively: the page starts below the status bar and ends above the home indicator, and the
  system bars sit on a plain band in the system background colour rather than on the Fanzone's own
  background. On the hub that band follows your status bar when your app sets its style itself
  rather than per view controller: black under light text, white under dark text. A phone without a
  notch gets the same band under its 20 pt status bar, and in landscape or on iPad the band runs
  along every edge the system reserves. Android is unchanged. Nothing to change on your side.

### Changed

- **Android: call `Fastory.configure(context, config, listener)`.** A native Kotlin host used to
  call `configure(config, listener)`, and without a `Context` the SDK could neither name your
  application for the key exchange — so the exchange waited for your first `openGames(context)` —
  nor watch your process lifecycle, so it never prepared the hub ahead of that first open on either
  path. The new form does both: the exchange starts at `configure`, and the hub is prepared once your
  app is on screen, at once on the slug path and once the exchange resolves on the key path. Pass any
  `Context`; only its application context is kept, and it stays callable from any thread. The
  context-less form is `@Deprecated`, keeps working exactly as before for the whole 0.x line, and
  goes away in 1.0.
- **The Android module now depends on `androidx.lifecycle:lifecycle-process`.** It is how the SDK
  knows whether your app is on screen before it has an Activity of its own. Nothing to change in a
  Flutter app — the plugin declares it — and nothing to change in a native app that already resolves
  the module's dependencies through Gradle.
- **The native error view speaks the fan's language, and tells a lost connection from any other
  failure.** Until now the screen shown when the hub or a game could not load was English on every
  device, with one message whatever had failed, and the two platforms did not even show the same
  words. Both platforms now read their texts from a table per language — English, French and Spanish,
  the languages the Fanzone web surfaces serve, English for any other device language — and show *No
  internet connection.* when nothing answered, *Something went wrong.* otherwise. The message follows
  the fan's device language; when none of the device's languages is one the SDK carries, the `locale`
  you pass in the configuration is used if it is one, English otherwise. On Android the texts are
  ordinary string resources (`fastory_sdk_error_message`, `fastory_sdk_error_no_connection`,
  `fastory_sdk_retry`, `fastory_sdk_close`): your app may redefine them, provided it does so for
  every language it ships — a redefinition in `values/` alone leaves the SDK's French and Spanish
  tables in force on those devices. The Swift channel offers no override. Nothing to change in your
  code.
- **A native Android app now has an answer.** The guide only said a Kotlin artifact on Maven Central
  "follows". It now says what holds today — the Kotlin core reaches an app only inside the Flutter
  plugin, for a Flutter app, and no other path is supported until the artifact ships — and lists the
  missing artifact among the known limitations, with no date attached and an invitation to ask.
- **The plugin's error table lists the codes a Dart app can actually receive.** It listed eleven, and
  five of them cannot reach you in this version: the Dart types rule them out, no platform raises
  them, or the mode that raises them is reserved. Two it did not list can — `no_activity` and
  `no_view_controller`, which `openGames()` answers when the plugin has no activity or no view
  controller to present from. What every listed code means is unchanged. The channel contract stays in
  `SPEC.md` § 5.2 and § 5.4.
- **The specification no longer illustrates pinning with the range the guide tells you to avoid.** It
  said a host pinning `ref: sdk-vX.Y.Z` and a host pinning `from: "X.Y.Z"` are on the same code — true,
  and it normalised the form 0.4.1 asked you to drop. It says the same thing without it.
- **The iOS console warning on a SwiftUI tab entry is no longer listed as an SDK limitation.** The
  guide said `openGames(from:)` called from a SwiftUI tab-bar action logs *"Unbalanced calls to
  begin/end appearance transitions"*, and that deferring the call by one runloop tick avoids it. Both
  were wrong: on iOS 26.5 the call alone logs nothing, and the deferral changes nothing. The line
  comes from the host side — the view owning the `TabView` re-rendering in the same tap, because it
  reads state that tap changes. The *Integrate in 5 lines › Native iOS* section now says so and how to
  avoid it. Nothing in the SDK changed.

## 0.4.4

Documentation only. The sole change to the shipped Swift and Kotlin is comments — no public name
moves, no behaviour changes, and upgrading changes nothing your app does. What changes is what the
documentation tells you, and one of those things was wrong in a way that could have cost you a
planning decision.

### Fixed

- **The guide no longer tells you the publishable-key exchange is staging-only.** It said the
  endpoint was live on staging and would reach production later, and advised shipping to production
  on the deprecated `fanzoneSlug` path until it deployed. That has not been true for some time: the
  exchange answers in production, verified end to end with a live key. If you deferred the key path
  or built a fallback because of that note, you need neither. Four places carried it — the
  availability note, both quickstart snippets and the configuration reference — and all four now say
  the same thing: keys are minted per environment (`fpk_live_…` for production, `fpk_test_…`
  elsewhere), and `configure()` refuses a pair that disagrees before any network call, so move the
  key and the `environment` together. A live key that still does not resolve is a workspace
  provisioning question for your Fastory contact, and the `code` on `FastorySurfaceLoadFailed` names
  which refusal you hit.

  **Corrected.** Three of those four places are in the root `README.md` — the availability note, the
  Flutter quickstart's comment and the configuration reference — and the fourth is in the Flutter
  plugin's own `README.md`. The Swift quickstart never carried the note.
- **Three entries below now say when they stopped being true.** A changelog is usually read by
  landing in the middle of it, and three notes described a state of the world that has since changed:
  0.4.0's workaround for Retry after a refused key, which 0.4.3 made unnecessary; 0.3.0's warning
  that live keys would not resolve, superseded by the deployment above; and the staging host named in
  0.1.1, which became `https://staging.story.tl` in 0.2.0. Each keeps its original text as the record
  of the release that shipped it, and carries a note saying what superseded it.

### Changed

- **The failure-code reference lists only codes you can actually receive.** It used to name two that
  never reach a host and explain why they were absent — which put them in the list. If you see
  `sdk_application_id_required`, it is always the SDK refusing before it forms a request, never an
  answer from our API; a missing or malformed key never leaves the device either. Every code you can
  observe, and the behaviour behind it, is unchanged.
- **Two long entries below are easier to read.** The 0.4.0 notes on the Retry limitation and on
  `configure()` threading each said in one paragraph what four short ones say better. Nothing was
  removed but repetition.
- **Comments in the shipped Swift and Kotlin describe the code, not our test arrangement.** Four of
  them explained which of our own test classes needed a member to be visible. They now say what a
  reader of the source needs — why a member is reachable inside the module rather than private —
  which is the part that stays true when our tests are rearranged.

## 0.4.3

One defect, on the path every new integration takes. **No public name moves and nothing you call
changes** — the fix is behind the error view's own button.

### Fixed

- **Retry now recovers a hub that failed because the publishable-key exchange failed.** A fan who
  opened the games while their connection was down got our error screen, and the Retry button under
  it did nothing they could see: it reloaded the page that had failed, and a hub configured by key
  has no page yet — the fanzone to open comes back from `/sdk/auth/bootstrap`, and that call had not
  succeeded. The refusal was remembered for as long as the app lived, so every later tap re-showed
  the same screen without asking us again, and the fan was stuck until they killed the app. Retry
  re-runs the exchange now. **Nothing to change on your side, and one thing you can stop doing:** the
  workaround we documented — calling `configure()` again from your `FastorySurfaceLoadFailed(surface:
  hub)` handler — still works and is no longer needed.
- **What Retry still cannot do, stated because it is the half worth knowing.** `sdk_key_unknown`, a
  key we have revoked, and an application identifier the key does not declare refuse the second
  exchange exactly as they refused the first: the request goes out, comes back refused with the same
  `code`, and the error screen stays. Retry recovers a bad minute on the network, never a
  configuration we refuse — those codes are still the ones worth alerting on.
- **`sdk_rate_limited` is the one code Retry does not even re-ask on.** The error screen stays and no
  request leaves the device. That sanction counts requests from your users' *address* rather than from
  your key, and a third one blocks that address with no expiry — everyone behind one carrier NAT or
  one venue's wifi shares it. A button that re-asked would make us the looping client we tell you not
  to be.

### Changed

- **On iOS the key exchange now gives up after 15 seconds instead of 60 — an alignment on Android, not
  a new limit.** Android has always declared 15 seconds; iOS declared nothing and inherited
  `URLSession`'s 60-second default. The same dead network therefore kept a fan waiting four times
  longer depending on the phone they held, and an exchange slower than 15 seconds was already failing
  for every Android user. 15 seconds was the de facto contract; iOS now honours it too.
  **What that changes for you:** on a congested or 2G connection, an exchange that used to complete
  after 20-40 seconds on iOS now surfaces `FastorySurfaceLoadFailed` with `reason=network` instead. If
  you alert on that event, expect more of it from iOS on very slow networks — and note that those
  fans were already failing on Android. The fan's Retry recovers it. One asymmetry remains: iOS
  applies a single inactivity budget where Android applies a connect budget plus a read budget, so
  read 15 seconds as the shared budget without progress, not as a guaranteed ceiling.

## 0.4.2

### Changed

- **The published documentation now addresses only you.** Wording that only meant something inside
  Fastory — issue identifiers, repository paths, build-tool names — told you nothing you could act
  on, and every one of them is out of the files this release publishes. No public name moves and no
  behaviour changes.
- **Known limitations are still documented, in the terms you meet them in**: what you observe, what it
  costs you, the workaround when there is one, and whether a fix is planned.
- **`QA_CHECKLIST.md` is no longer published.** Nothing in it described SDK behaviour that
  `README.md` and `SPEC.md` do not already carry. A link to it on the default branch now answers 404.
- **The `android/` and `ios/` README files inside the plugin now say what each directory holds** — the
  SDK's native implementation, compiled into your app — instead of how those sources are maintained.

## 0.4.1

A correction release. **No public name moves and no behaviour you depend on changes** — five defects
found by consuming the published 0.4.0 packages from outside our own repository, four of which are
things we told you that were not true. Nothing here asks you to change code, with one exception
called out below: the iOS install instruction, which you should update in your own project.

### Fixed

- **Android: the SDK's R8 keep rule is now actually handed to your application.** The rule that keeps
  the bridge's JavaScript entry point alive under shrinking has shipped with the Android module since
  the bridge did — but no Gradle file declared `consumerProguardFiles`, which is the only thing that
  passes a library's rule to the app consuming it, so R8 never read ours. **Nothing broke, and it
  matters that you know why:** Flutter's Gradle plugin adds AGP's default rule file to every shrinking
  release build, and that file carries an equivalent rule, so the bridge survived whatever your own R8
  configuration said. If you read the FAQ's *Do we need ProGuard / R8 rules?* and wrote no keep rule
  of your own, you were protected by your build chain rather than by us. You are now protected by us,
  which is what that FAQ answer has always claimed. Nothing to change on your side.
- **iOS: the install instructions now pin up to the next *minor*, and you should follow them again.**
  They previously told you to pick *Up to Next Major Version*, or `from:` in your `Package.swift`.
  Both mean `>= 0.4.0, < 1.0.0`: Swift Package Manager gives a leading zero no special meaning, unlike
  the caret in some other ecosystems, so that range spans every future 0.x minor. This SDK ships
  source breaks in minors while it is on 0.x — *Upgrading from 0.3.0* in the README lists three —
  which made the recommended range one a future release could stop compiling in, without you asking
  for it. **Change your dependency to *Up to Next Minor Version*, or `.upToNextMinor(from:)` in your
  manifest.** If you want the Swift channel to be as immovable as the Flutter one, which pins a tag,
  use SwiftPM's `exact:` requirement instead. The demo project we ship as "resolve it exactly as an
  integrator does" carried the old range too, and now carries the new one.
- **The README now says what `configure()` does with a configuration it refuses, on each channel.**
  It said nothing at all, while its configuration table claimed `configure` *throws* when
  `developmentBaseUrl` is missing in development — which describes the Flutter channel and cannot
  describe the Swift one, where neither the initializers nor `configure(_:)` are declared to throw.
  The behaviour is unchanged and deliberate; only the silence about it is fixed. On Flutter,
  `configure()` throws a catchable `ArgumentError` before it reaches the platform channel. On native
  iOS, `configure(_:)` cannot throw: a **debug** build trips an assertion and terminates, and a
  release build returns having changed nothing. A Swift host that would rather handle it calls
  `try config.validate()` first. **The same section also states what a refusal is not**: it is not a
  rollback. The configuration already in force keeps applying on both channels, so only a host whose
  *first* `configure()` is refused ends up unconfigured — refuse a later one and `openGames()` opens
  the previous fanzone as though nothing had happened. The README's new *When `configure()` refuses
  your configuration* carries both channels side by side, because the mistake this catches — a
  publishable key and an environment that disagree — is exactly the one the staging-to-production
  move makes easy.
- **Flutter: a refused publishable key no longer appears in the exception message.** `configure()`
  still throws `ArgumentError` for the same reasons; the message now names the rule that was broken
  and the environment expected, instead of quoting your key at the end of the sentence. Logging a
  failed `configure()` is the ordinary thing to do, and it was sending the key to your crash reporter
  and your log aggregator for no purpose. A publishable key is not a credential — `SPEC.md` § 2.5 —
  so nothing was exposed by this; the value was simply useless in a third party's logs, and the Swift
  guard never did it. **If you match on the message text of this exception, it has changed** — and so
  have its `name` and `invalidValue` properties, which are now null for this one field, because
  `invalidValue` is where the key used to sit. The `ArgumentError` type itself, and every
  configuration this refuses, are unchanged. The other fields `configure()` refuses — a blank
  `fanzoneSlug` or `hubTabSlug` — still carry the offending value, deliberately: they are identifiers
  you chose, and seeing which one was blank is the point.
- **`SPEC.md` no longer points you at files this repository does not contain.** Four of its lines
  named files you have no way to open, and one of them made such a file *the* authority — § 9.1 told
  you to treat any unlisted failure `code` as a defect to report, and then said the closed list was
  that file. **The table in § 9.1 is the closed list**, and it always held the same values; a
  specification you hold now says so itself.

## 0.4.0

Everything specified since 0.3.0, released at once: a message bridge between your app and the web
content the SDK hosts, the identity API, the bridge's reply channel, a surface that fails to load
now telling your app so, and four defects a pre-release audit found. Plus one removal,
`workspaceId`.

It arrives as one upgrade, but it is five separate capabilities and they break in different places —
so each has its own section below, in that order, and the three source breaks are listed first.
**Read `Breaking` and you are done**: nothing else here asks anything of you.

### Breaking

- **Dart: `FastoryEvent` gains three subtypes.** It is a `sealed` class, so an exhaustive `switch` with
  no `default:` stops compiling until you add a case for **all three** — `FastoryBridgeMessage` (the
  bridge), `FastoryIdentityResolved` (the identity API) and `FastorySurfaceLoadFailed` (a hub or
  game that did not load). The analyzer points at each. Deliberate, under SemVer § 4 (anything may
  change in a `0.y.z` line), and the last such break planned before 1.0. The two native channels are
  purely additive: each new callback is defaulted to a no-op, so an existing delegate or listener
  keeps compiling untouched.
- **Android: the reply channel adds a dependency and a WebView floor.** The SDK now depends on
  `androidx.webkit`, because the reply channel needs the one Android API that reports which frame
  posted a message and from which origin — `addJavascriptInterface`, which the receive-only channel
  uses, reports neither. A reply carries a credential, so answering the wrong frame is not an
  acceptable failure: an `<iframe>` inside a game must not be able to read it. On a device whose
  WebView predates that API (Chrome 85, mid-2020) **the reply channel is simply absent** and the
  surface falls back to anonymous — everything else works as before.
- **`workspaceId` is gone from `FastoryConfig`**, on all three platforms. If you pass it, delete the
  argument; there is nothing to replace it with, and nothing it protected is now unprotected. It was
  an optional cross-check against the workspace your publishable key resolves to — but a key resolves
  exactly one workspace, so it was asking you to confirm something the key already settles. What
  actually stops a key opening a workspace it does not belong to is the exchange being bound to your
  application identifier, which the API refuses unless the owning workspace declared it on that key
  (`sdk_application_not_allowed`). That refusal is unconditional and happens on the side that holds
  the truth; the field was an opt-in copy of it, and could only ever be weaker.

### Added — the JS ↔ native bridge

The web content the SDK hosts can talk to your app, through a versioned message envelope.

- A Fastory web surface (the hub, or a game) can post `{"v": 1, "type": "…", "payload": {…}}` and your
  app receives it as a **sixth event**: `FastoryBridgeMessage` on `Fastory.events` (Flutter),
  `onBridgeMessage` (Android), `fastoryBridgeMessage(type:payload:)` (iOS). The callback is a no-op by
  default on every platform, so upgrading without touching your call site changes nothing.
- **Additive, and no part of navigation.** The hub, the games and the external-link routing behave
  exactly as they did in 0.3.0 whether or not the web side posts anything.
- **Versioned, with an allow-list.** Anything that is not envelope version `1` carrying a type the SDK
  knows is silently ignored — so a later web release can introduce a message type without breaking an
  app already in the stores. Malformed input never throws.
- **One type today:** `fastory:ready`, a liveness signal meaning the embedded Fastory surface has
  rendered and speaks this envelope. Do not depend on receiving it.
- **No JavaScript is injected.** The entry point exists by native registration alone
  (`window.webkit.messageHandlers.fastory` on iOS, `window.fastory` on Android).
- **Bounded input.** A message over 65 536 characters is refused before it is parsed, and every drop
  is traced at debug level with its reason (see `SPEC.md` § 13.6 for how to turn the diagnostics on —
  they are off in release builds, as an SDK inside your app should be).
- Full contract in `SPEC.md` § 13. It carries a ≤ 16 ms budget for decode plus delivery; treat that as
  a regression tripwire rather than a latency figure, since the real cost is microseconds.

### Added — the identity API

Tell the SDK who the fan is: one `identify` method with three modes, plus `logout`. Only the anonymous
mode resolves in this release; the other two are the final signatures, reserved.

- **`Fastory.identify(...)` and `Fastory.logout()`** — the whole identity API, and it is now
  frozen: three mutually-exclusive modes behind one method. `anonymous` is what the SDK has always
  done (each surface's web page mints its own device visitor) and it is the only one that resolves
  today. `fanId` (a Fastory login through the system browser) and `hostToken(jwt)` (your backend
  asserts an identity it already authenticated, so the fan types nothing) ship in later releases and
  reject with `identify_mode_unavailable` until then. They are declared now on purpose: adopting them
  later must not be a breaking change for you.
- **`identityResolved`** — emitted once per successful `identify`, before any hub or game opening
  carrying that identity, so you never attribute a session to the wrong fan. A refused identification
  emits nothing; its error comes back from the call.
- **Calling `identify(anonymous)` twice gives you the same fan.** Repeated calls — across app launches,
  or defensively before every `openGames()` — are a no-op, not a new visitor each time.
- **An app that never calls `identify` behaves exactly as it did in 0.3.0**, and an app that starts
  calling `identify(anonymous)` keeps the visitor it already had. Nothing about the hub, the games or
  the URLs moves.
- **`logout()` signs the fan out of Fastory only.** It clears the Fastory session on the fanzone and
  story domains and nothing else: your own session, your own cookies and your own web storage are
  never touched. Symmetrically, signing a user out of your app does not sign them out of Fastory —
  call `logout()` for that.
- **The documented promise that the hub and the game share a session was wrong, and is withdrawn.**
  `SPEC.md` § 7 said the two WebViews shared a cookie store *"so the game inherits any session state
  established in the hub"*. They cannot: the hub and the game are different sites, and the game (which
  loads with `embed=1`) reads no storage at all. If you read that paragraph as "games already know who
  the fan is", they do not: a game asks the SDK, and the only thing the SDK can answer with is the
  standing value you set with `setBridgeReply()`, new in this release. § 7 now describes what
  actually happens, and § 7.4 specifies what a sign-out erases.

  **Corrected.** "Reads no storage at all" was wrong: the game page reads and writes its own cookies
  and web storage on its own site, like any page. What it does not read there is a session — it asks
  its host page for one, and has none in an SDK WebView — so the rest of this entry stands.
- **The shared `WKProcessPool` is gone on iOS.** Deprecated since iOS 15 and documented by Apple as
  having no effect, so it produced a deprecation warning and nothing else. WebKit decides process
  sharing on its own at the SDK's iOS 15 floor. No behavior change; one less warning in your build.

### Added — the bridge's reply channel

The web can ask the SDK a question and get an answer. One method for you, `setBridgeReply` — and the
first thing it unlocks is a game knowing who the fan is.

- **`Fastory.setBridgeReply(type, payload)`** — declares what the SDK answers the next time an
  embedded surface asks for something. Today there is exactly one thing it can be asked
  (`FastoryBridgeRequestType.userToken`), and it exists because a game has no way to know the fan on
  its own: when it runs inside a page it asks that page, and inside the SDK there is no page to ask.
  Set the answer before opening a game and the SDK stands in for the missing host.
- **A request always gets a reply.** If you have set nothing, if the surface asks for something this
  SDK version does not know, or if the message is malformed, the page is told so explicitly — it is
  never left waiting. That is deliberate: silence is indistinguishable from a hung SDK.
- **The bridge is registered on every SDK WebView** — hub, game sheet and preloaded games — and still
  injects no JavaScript into your users' pages. The answer travels back on the channel the question
  arrived on, which is the platform's own return path.
- **"The bridge is receive-only" is not the right description of it.** The SDK never speaks to a page
  first, but it does answer one that asks. Pushing data into a page unprompted remains out of scope.
- An app that never calls `setBridgeReply` is unaffected by this capability.

### Added — a surface that does not load now tells your app

Until this release, a Fastory surface that failed to load showed the fan an error screen that does not
belong to your app, and told your app nothing at all. You could not log it, alert your team, or offer
the fan something else.

- **`FastorySurfaceLoadFailed`** on `Fastory.events` — `onSurfaceLoadFailed` on Android,
  `fastorySurfaceLoadFailed(_:)` on iOS. It carries which surface failed (`FastorySurface.hub` or
  `FastorySurface.game`), a `FastoryLoadFailureReason`, and the cause: the API's own `code` when the
  refusal came from your publishable key, the HTTP `statusCode` when it came from the page itself.
- **Branch on the reason, read the cause.** `FastoryLoadFailureReason.rejected` means something
  answered and refused — `code` or `statusCode` says what. `network` means nothing answered: no
  connection, DNS, timeout. `unknown` is everything else. Three cases, so a simple "is Fastory
  reachable?" check is one branch rather than a match over the codes below.
- **A revoked key is now distinguishable from a phone in a tunnel.** They were not: a revoked key, an
  application identifier your workspace never declared, and no network produced one identical screen
  and one identical silence. The API had been answering `sdk_key_unknown`, `sdk_key_revoked`,
  `sdk_application_not_allowed` and `sdk_rate_limited` all along; the SDK was discarding them. Read
  `sdk_rate_limited` as a signal to back off, not to retry: repeated sanctions escalate to an
  address block with no expiry that is lifted only on request — ask your Fastory contact. With
  the two the SDK mints itself — `http_<status>` and `sdk_application_id_required` — that is six
  things `code` can carry and no others: five names, plus the `http_<status>` family for a refusal
  that named no code of its own. Cover those and you have covered the field. `sdk_key_unknown`
  is the one worth reading twice: it means we know no such key, which covers a key **deleted** in the
  back-office and a workspace that no longer exists, not only a typo in a build you never shipped. An
  app already in the field can meet it.
- **The game sheet now has an error view too**, with Retry — a game that failed to load used to be a
  black sheet. The hub has had one since 0.1.
- **An opening event no longer fires on a surface that failed.** `hubOpened` used to go out while the
  screen showed the error view, so an app counting it counted hubs that never loaded. It now announces
  a surface whose page actually loaded — and a surface that never opened sends no closing event
  either, so `hubOpened` … `hubClosed` still pair up. A hub that was pre-warmed still announces itself
  the instant it appears; nothing about the fast path changed.
- **Nothing is retried for you, and nothing is reported twice.** The SDK reports; you decide. A single
  failed load produces exactly one event, cancellations the SDK causes itself when routing a game or
  an external link produce none, and a failed image or XHR inside a page produces none.
- **Known limitation: Retry does not recover a refused publishable key.** A fix is planned.
  - *What you see.* The hub fails on a refused key exchange, the fan taps Retry, and the same error
    screen comes back. No request leaves the device: Retry reloads the page that failed, and a hub
    configured by key never produced one — the exchange's outcome is remembered per configuration,
    failure included.
  - *What it costs you.* A fan whose exchange failed on a bad connection cannot retry their way out.
    Pages that failed on their own, and the deprecated `fanzoneSlug` path, reload on Retry as before.
  - *The workaround.* Call `configure()` again from your `FastorySurfaceLoadFailed(surface: hub)`
    handler — **any second call, on both platforms**, with the configuration already in force or a
    new one. On Android an equal `configure()` leaves the previous failure readable until the new
    exchange answers, so the recovery can land on the open after next.

  **No longer true.** It was accurate for 0.4.0 and is left as the record of that release: since
  0.4.3 Retry re-runs the exchange itself, and the `configure()` workaround above is no longer
  needed. Read the current guide, not this note.

### Fixed — four defects the pre-release audit found

One of them lets an identity outlive the fan it names.

- **`logout()` revokes the answer the SDK gives your games.** The value set through `setBridgeReply`
  had no end: signing a fan out erased their web session and dropped the warm hub, and the next game
  that asked for the fan's token was still handed the one you set for the fan who just left. The same
  value also survived a reconfiguration, so a token minted for production could be served to a staging
  page. It is dropped at three points — `logout()`, an `identify()` that resolves a *different* fan,
  and a `configure()` that replaces the configuration with a different one — and the next request is
  answered `unavailable` explicitly, never with silence.
  - **What you have to do:** if your app sets a standing answer, set it again after any of those three
    calls. The SDK does not announce the revocation, because all three are calls you just made.
  - **The rule is deliberately coarse on `configure()`:** *any* difference revokes, a `theme` switch
    included. Guessing which parts of a configuration a credential depends on would mean reading the
    credential, and being wrong in that direction is a leak.
  - `SPEC.md` § 13.8.6 is normative; § 2.6.1 and § 7.4 point at it. The example app's *SDK* tab shows
    the revocation on screen when it happens.
- **Android: opening the games twice in a row no longer stacks two hubs.** `openGames()` was not
  idempotent on this platform, and the hub `Activity` declared no launch mode — so a double tap on
  your own "Games" tab, the most ordinary gesture there is, opened a second hub over the first. Your
  app then received two `hubOpened` for one hub the fan could see, `close()` returned them to the hub
  underneath instead of to your app, and the page the hidden hub kept warm on its way out overwrote
  the other one without releasing it, leaking a WebView per stack. Asking for the games while a hub is
  up now does nothing at all, exactly as it always has on iOS.
  - **Nothing to change on your side**, and nothing new to catch: it is a silent no-op, not an error.
    If you were counting `hubOpened` to drive your own UI, the count is now the one you expected.
  - **A `close()` issued in the instant between `openGames()` and the hub appearing is honoured too** —
    the hub finishes on arrival rather than showing up after you asked for it to be gone.
  - `SPEC.md` § 2.1 states the rule for both platforms and § 2.3 the Android launch mode that backs it.
- **iOS: re-configuring no longer opens the previous configuration's fanzone.** A second `configure()`
  with a different configuration replaced the configuration but kept the hub page already warmed for
  the old one, so the next `openGames()` showed the wrong fanzone — a multi-club app opened the wrong
  club, a staging switch opened production. It escaped notice because the teardown sat behind the
  warm-up, which does nothing at all when the SDK is configured by key: the fanzone to open is not
  known until the API answers. So the path that never cleaned up was the publishable-key path — every
  integration configured by key rather than by fanzone slug. Android already behaved correctly;
  `SPEC.md` § 2.1 now states the rule for both, including that re-configuring with an *equal*
  configuration must keep the warm hub.
  - **A warm hub is only reused for the configuration its page was loaded under**, on both platforms.
    Dropping it at `configure()` time is not enough on its own: the hub is put back into the warm slot
    when it is closed, so closing it *after* a re-configure returned the previous club's page to the
    slot the teardown had just emptied. The same stamp applies to a cached publishable-key exchange, so
    a workspace resolved for one configuration can no longer answer for another.
  - **An equal `configure()` no longer costs you a cold hub open on iOS.** Warming up did not check
    whether anything was already warm, so a re-configure with the same configuration flushed every
    preloaded game and replaced the rendered page with one still loading. Android always had that
    guard. `SPEC.md` § 2.1 now binds the warm-up path as explicitly as the teardown.
- **`configure()` can be called from any thread, and no longer competes with your first screen.**
  Initialising the SDK from a background bootstrap used to crash the host app at launch: `configure()`
  allocated a WebView and loaded it on whichever thread you called it on. It now stores your
  configuration on your thread and schedules that work itself.
  - **The hub is warmed once your app is on screen, not during `configure()`.** Building the hub
    WebView at `configure()` competed with your app's first paint on every launch, for every
    integration on the deprecated `fanzoneSlug` path. It is deferred to the first frame, and a
    background launch warms nothing. Opening the hub is unchanged — a deferral, not a removal.
  - **`SPEC.md` § 2.7 is new** and states which thread each method may be called from. Only
    `openGames()` still requires the main thread: it takes your own `UIViewController` / `Context`, so
    you are already in UI code. Everything else is callable from anywhere, and every callback still
    arrives on the main thread as before.

### Fixed — elsewhere

- **`hubOpened` was missing on iOS whenever the hub had been pre-warmed** — which, configured by
  `fanzoneSlug`, is every opening that goes well. The event carries the slug of the fanzone being
  opened, and the SDK only looked that slug up on the path it skips when the page is already loaded, so
  the better the warm-up worked the more reliably the event went missing. It now fires on every
  presentation whose page loaded, warmed or not, and `hubOpened` … `hubClosed` pair up again — a hub
  that fails to load sends `FastorySurfaceLoadFailed` and neither of the pair (see *a surface that
  does not load* above). Android and Flutter on Android were never affected by the missing event.
- **The Android dependencies the plugin bundles can no longer come up short.** They are declared in
  two places and nothing held those equal, so a library added in one could be missing where your
  build reads it, and the failure would only appear at compile time. The two are kept equal now.

### Notes

- **Erasure is scoped, by name and by origin, never wholesale.** On both platforms the cookie and
  web-storage stores are shared with your app, so the SDK expires a declared list of Fastory cookies on
  the Fastory origins rather than calling any "clear everything" API. That is a hard rule, not a
  precaution: the convenient call would sign your users out of your own services.
- An identity change also drops the warm hub and the preloaded games — they were rendered for the
  previous fan. Expect the next `openGames()` after a `logout()` to be a cold open.
- `identify` never blocks and never throws across the bridge. Every failure carries a machine-readable
  code (`identify_mode_unavailable`, `invalid_host_token`, `not_configured`, …) and leaves the SDK in a
  clean anonymous state — never half-identified. Branch on the code, never on the message.

## 0.3.0

Configure the SDK with a workspace publishable key instead of a fanzone slug, and tell the web
surfaces which appearance to render in.

### Added

- **`configure` by publishable key** — create one in the workspace settings and pass it as
  `publishableKey`; the SDK exchanges it for the fanzone to open. Pass `workspaceId` too and a key
  belonging to a different workspace is rejected instead of silently opening someone else's
  fanzone. A malformed key, a bare prefix, or a key minted for another environment fails **at
  configure time**, with a typed error — not later at the first network call.
- **`theme`** — `light` or `dark`, forwarded to the hub and game URLs alongside the existing
  `locale`. The web side does not read it yet, so setting it is inert until it ships there. Neither
  value ever overwrites one the fanzone already put on its own game links.

### Deprecated

- **`fanzoneSlug`** — still accepted, and still behaving exactly as in 0.1, for the whole 0.x line.
  Upgrading without touching your call site does not break: nothing becomes a compile error before
  1.0. Each platform flags it the way its language allows.

### Notes

- **The key exchange is served on staging, not yet on production.** `environment: staging` with an
  `fpk_test_…` key works today; an `fpk_live_…` key against production resolves nothing until the
  endpoint deploys there, and `openGames()` shows the hub's error view. Production integrations stay
  on the deprecated `fanzoneSlug` until then — that path calls no endpoint and is unchanged by this
  release.
  **No longer true.** It was accurate for 0.3.0 and is left as the record of that release: the
  exchange has since been deployed, and live keys are no longer refused for want of the endpoint.
  Read the current guide, not this note.
- Configured by key, the hub cannot be warmed up before the exchange resolves — there is no URL to
  warm yet. The hub's existing loading state covers the round trip, and a rejected key lands on the
  existing native error view rather than a blank web view.
  **No longer true.** It was accurate for 0.3.0 and is left as the record of that release: the hub is now prepared as soon as the exchange resolves, so the first opening no longer pays
  for the round trip. Read the current guide, not this note.
- Errors carry the API's machine-readable code (`sdk_key_revoked`, `sdk_application_not_allowed`,
  `sdk_rate_limited`, …). Branch on the code, never on the message.
- The key only bootstraps for the application identifiers declared on it — your iOS bundle
  identifier and Android package name. Create the key with them, or every call is refused.

## 0.2.0

Native iOS apps can now consume the SDK as a Swift package, and heavy games get the whole device
budget while they are on screen.

### Added

- **Swift package (SwiftPM)** — native iOS apps no longer need Flutter to embed the SDK. Add
  `https://github.com/KrashStudio/fastory-sdk-mobile` in Xcode, or `from: "0.2.0"` in your own
  `Package.swift`, and call `Fastory.configure(_:)` then `Fastory.openGames(from:)`. The Flutter
  plugin is unchanged and keeps its own install path. Every release now publishes both channels
  from the same commit: `sdk-vX.Y.Z` for Flutter, the bare `X.Y.Z` tag that SwiftPM resolves.

  **Superseded.** `from: "0.2.0"` accepts every later 0.x minor, and this line ships source breaks in
  minors. Since 0.4.1 the install instruction is *Up to Next Minor Version* in Xcode, or
  `.upToNextMinor(from:)` in your manifest — the 0.4.1 entry says why.

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

  **No longer true.** The staging host named here is the one 0.1.1 shipped; it became
  `https://staging.story.tl` in 0.2.0.
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
- **Example app** — Flutter demo of a host app embedding the SDK (bottom bar, Games entry).
- Platform floor: iOS 15.0, Android `minSdk 24`, Flutter ≥ 3.10 (Dart ≥ 3.0).
