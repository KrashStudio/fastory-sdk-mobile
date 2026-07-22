# fastory_sdk

Plugin Flutter du SDK mobile Fastory v0.1 (ultra-light). Il ouvre le hub de jeux d'une fanzone dans une vue native plein écran (WebView A), chaque jeu dans un bottom sheet natif (WebView B, cookies partagés avec la WebView A), et toute origine externe dans le navigateur système.

## Prérequis

- Flutter ≥ 3.10, Dart ≥ 3.0
- iOS 15+ (le Podfile de l'app hôte doit déclarer `platform :ios, '15.0'`)
- Android minSdk 24 (l'app hôte doit déclarer `minSdk = 24`)

## Installation (git dependency)

```yaml
dependencies:
  fastory_sdk:
    git:
      url: git@github.com:KrashStudio/fastory.git
      ref: dev
      path: packages/sdk/flutter/fastory_sdk
```

## API

### Configuration

```dart
import 'package:fastory_sdk/fastory_sdk.dart';

await Fastory.configure(
  const FastoryConfig(
    fanzoneSlug: '433',
    environment: FastoryEnvironment.production,
    hubTabSlug: 'games-app',
    locale: 'fr',
  ),
);
```

| Champ | Type | Défaut | Description |
|---|---|---|---|
| `fanzoneSlug` | `String` | requis | Slug de la fanzone (ex : `433`) |
| `environment` | `FastoryEnvironment` | `production` | `production` (fanzone.me), `staging` (placeholder, à confirmer), `development` |
| `hubTabSlug` | `String` | `games-app` | Tab caché de la fanzone servant de hub |
| `locale` | `String?` | `null` | Locale forcée du hub |
| `developmentBaseUrl` | `String?` | `null` | Base URL, requis si `environment` est `development` |

### Ouverture / fermeture

```dart
await Fastory.openGames();
await Fastory.close();
```

`openGames()` présente le hub plein écran. Un clic sur un jeu (`/s/{slug}`) ouvre le bottom sheet natif avec `embed=1&utm_source=sdk`. Toute origine différente de la base fanzone (ou tout scheme non http(s) : `mailto`, `tel`, `intent`, `market`) part dans le navigateur système. Sur Android, le bouton back ferme d'abord le bottom sheet, puis remonte l'historique de la WebView du hub, puis ferme la vue.

### Événements

```dart
final subscription = Fastory.events.listen((event) {
  switch (event) {
    case FastoryGameOpened(:final slug):
      print('game opened: $slug');
    case FastoryExternalLink(:final url):
      print('external link: $url');
    case FastoryHubOpened():
    case FastoryHubClosed():
    case FastoryGameClosed():
      break;
  }
});
```

| Événement | Payload |
|---|---|
| `FastoryHubOpened` | — |
| `FastoryHubClosed` | — |
| `FastoryGameOpened` | `slug` |
| `FastoryGameClosed` | — |
| `FastoryExternalLink` | `url` |

## Architecture

Le plugin est autonome : `android/` et `ios/` contiennent une copie des classes cœur des SDKs natifs (`packages/sdk/android` et `packages/sdk/ios`). Voir les notes de synchronisation en tête de `android/README.md` et `ios/README.md`. Cette duplication disparaîtra en v0.2 au profit d'une dépendance d'artefact (Maven / SPM).

- Dart ↔ natif : `MethodChannel('fastory_sdk')` (`configure`, `openGames`, `close`) et `EventChannel('fastory_sdk/events')`
- Android : `FastorySdkPlugin` (`com.fastory.sdk.flutter`) délègue aux classes cœur (`com.fastory.sdk`)
- iOS : `FastorySdkPlugin` délègue aux classes cœur copiées dans `ios/Classes/`

## Boucle de dev

```bash
cd packages/sdk/flutter/fastory_sdk/example
flutter create --org com.fastory.example --platforms android,ios .
# puis appliquer les ajustements minSdk / iOS 15 décrits dans example/README.md
flutter pub get
flutter run
```
