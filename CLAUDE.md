# Fastory Mobile SDK

Context for AI assistants working in this repository.

## What this repository is

The **release distribution** of the Fastory Mobile SDK — a thin native WebView container that embeds
the Fastory Fanzone games experience inside a host mobile app. Each release is a curated snapshot
tagged `sdk-vX.Y.Z` (SemVer; the tag always matches the Flutter plugin's `pubspec.yaml` version).

This repo is **read-only for integrators**: no development happens here, there are no feature
branches, and pull requests are not accepted. Consume a tag; report issues to your Fastory contact.

## Layout

```
README.md              # the integration guide — start here
SPEC.md                # normative contract: public API, URL rules, events, platform channels
QA_CHECKLIST.md        # device-matrix QA scenarios for sign-off
flutter/fastory_sdk/   # the Flutter plugin (Dart API + bundled iOS/Android native code)
```

## Integrating

Add the plugin as a git dependency pinned to a release tag:

```yaml
dependencies:
  fastory_sdk:
    git:
      url: https://github.com/KrashStudio/fastory-sdk-mobile
      path: flutter/fastory_sdk
      ref: sdk-v0.2.0
```

Public API surface (normative in `SPEC.md §2`): **3 methods** — `Fastory.configure(FastoryConfig)`,
`Fastory.openGames()`, `Fastory.close()` — and **5 events** on `Fastory.events` (`FastoryHubOpened`,
`FastoryHubClosed`, `FastoryGameOpened(slug)`, `FastoryGameClosed`, `FastoryExternalLink(url)`).
Minimum platforms: iOS 15.0, Android `minSdk 24`, Flutter ≥ 3.10 (Dart ≥ 3.0).

## Rules for AI assistants

- `SPEC.md` is the source of truth for behavior; `README.md` for integration steps. Prefer them over
  inferring behavior from the native sources.
- Do not suggest modifying files in this repository — changes ship through Fastory's release process
  and arrive as a new tag. To adopt a fix, bump `ref:` to the newer tag.
- The bundled iOS (`flutter/fastory_sdk/ios/`) and Android (`flutter/fastory_sdk/android/`) sources
  are internal to the plugin; host apps interact only with the Dart API.
- v0.1 is intentionally ultra-light: no authentication, no analytics, no JS injection, no
  `postMessage` bridge (see `SPEC.md §11` for the non-goals and `README.md` for known limitations).
