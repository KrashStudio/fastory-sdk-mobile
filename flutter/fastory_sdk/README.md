# fastory_sdk

Flutter plugin of the Fastory Mobile SDK v0.1 (ultra-light). It opens a fanzone's games hub in a
full-screen native view (WebView A), each game in a native bottom sheet (WebView B, cookies shared
with WebView A), and any external origin in the system browser.

## Requirements

- Flutter ≥ 3.10, Dart ≥ 3.0
- iOS 15+ (the host app's Podfile must declare `platform :ios, '15.0'`)
- Android minSdk 24 (the host app must declare `minSdk = 24`)

## Installation (git dependency)

Consume the public distribution repo, pinned to a release tag:

```yaml
dependencies:
  fastory_sdk:
    git:
      url: https://github.com/KrashStudio/fastory-sdk-mobile
      path: flutter/fastory_sdk
      ref: sdk-v0.1.1
```

## API

### Configuration

```dart
import 'package:fastory_sdk/fastory_sdk.dart';

await Fastory.configure(
  const FastoryConfig(
    fanzoneSlug: 'your-fanzone',
    environment: FastoryEnvironment.production,
    hubTabSlug: 'games',
    locale: 'fr',
  ),
);
```

| Field | Type | Default | Description |
|---|---|---|---|
| `fanzoneSlug` | `String` | required | Fanzone slug (e.g. `your-fanzone`) |
| `environment` | `FastoryEnvironment` | `production` | `production` (`fanzone.me`), `staging` (`staging.fanzone.me`), `development` |
| `hubTabSlug` | `String` | `games` | Hidden fanzone tab used as the hub |
| `locale` | `String?` | `null` | Forced hub locale |
| `developmentBaseUrl` | `String?` | `null` | Base URL, required when `environment` is `development` |

Call `configure()` once before `openGames()`. If you call it straight from `main()`, call
`WidgetsFlutterBinding.ensureInitialized()` first so the platform channel has a binding.

### Open / close

```dart
await Fastory.openGames();
await Fastory.close();
```

`openGames()` presents the hub full screen. Tapping a game (`/s/{slug}`) opens the native bottom
sheet with `embed=1&utm_source=sdk&consent=0`. Any origin other than the fanzone base (or any
non-http(s) scheme: `mailto`, `tel`, `intent`, `market`) opens in the system browser. On Android the
back button first closes the bottom sheet, then walks the hub WebView history, then closes the view.

### Events

```dart
final subscription = Fastory.events.listen((event) {
  switch (event) {
    case FastoryHubOpened(:final fanzoneSlug):
      print('hub opened: $fanzoneSlug');
    case FastoryGameOpened(:final slug):
      print('game opened: $slug');
    case FastoryExternalLink(:final url):
      print('external link: $url');
    case FastoryHubClosed():
    case FastoryGameClosed():
      break;
  }
});
```

| Event | Payload |
|---|---|
| `FastoryHubOpened` | `fanzoneSlug` |
| `FastoryHubClosed` | — |
| `FastoryGameOpened` | `slug` |
| `FastoryGameClosed` | — |
| `FastoryExternalLink` | `url` |

## Architecture

The plugin is self-contained: `android/` and `ios/` hold a copy of the native SDK core classes
(`packages/sdk/android` and `packages/sdk/ios`). See the sync notes at the top of `android/README.md`
and `ios/README.md`. This duplication goes away in v0.2 in favor of an artifact dependency
(Maven / SPM).

- Dart ↔ native: `MethodChannel('fastory_sdk')` (`configure`, `openGames`, `close`) and
  `EventChannel('fastory_sdk/events')`
- Android: `FastorySdkPlugin` (`com.fastory.sdk.flutter`) delegates to the core classes
  (`com.fastory.sdk`)
- iOS: `FastorySdkPlugin` delegates to the core classes copied into `ios/Classes/`

## Dev loop

```bash
cd packages/sdk/flutter/fastory_sdk/example
flutter create --org com.fastory.example --platforms android,ios .
# then apply the minSdk / iOS 15 tweaks described in example/README.md
flutter pub get
flutter run
```
