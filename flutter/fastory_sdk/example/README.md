# fastory_sdk_example

App de démonstration du plugin `fastory_sdk` : une app sombre avec une bottom bar Home / Matches / Games / Profile. L'item **Games** appelle `Fastory.openGames()` et ouvre le hub de jeux de la fanzone `433`.

## Runners natifs non versionnés

Seuls `pubspec.yaml` et `lib/main.dart` sont versionnés. Les runners `android/` et `ios/` sont régénérés par `flutter create .` :

```bash
flutter create --org com.fastory.example --platforms android,ios .
```

Puis deux ajustements obligatoires :

1. **Android** — dans `android/app/build.gradle` (ou `.kts`), remplacer le `minSdk` par défaut :

   ```
   minSdk = 24
   ```

2. **iOS** — dans `ios/Podfile`, décommenter et fixer la plateforme :

   ```ruby
   platform :ios, '15.0'
   ```

   et aligner `IPHONEOS_DEPLOYMENT_TARGET` sur `15.0` dans Xcode si besoin.

## Lancer

```bash
flutter pub get
flutter run
```
