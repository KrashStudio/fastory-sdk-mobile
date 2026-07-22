> Mirrored from packages/sdk/android — keep in sync until the v0.2 artifact dependency

# fastory_sdk — Android

- `src/main/kotlin/com/fastory/sdk/` : copie des classes cœur du SDK Android natif (`Fastory`, `FastoryConfig`, `FastoryHubActivity`, `GameBottomSheet`, `UrlPolicy`). Seule adaptation autorisée : l'import `com.fastory.sdk.flutter.R` (le namespace Gradle du plugin diffère de celui du module natif).
- `src/main/kotlin/com/fastory/sdk/flutter/FastorySdkPlugin.kt` : pont Flutter (MethodChannel `fastory_sdk`, EventChannel `fastory_sdk/events`), spécifique au plugin — pas concerné par la synchronisation.
- `src/main/res/` et `src/main/AndroidManifest.xml` : copies des ressources et du manifest du module natif.

Toute évolution des classes cœur doit être faite dans `packages/sdk/android` puis reportée ici à l'identique.
