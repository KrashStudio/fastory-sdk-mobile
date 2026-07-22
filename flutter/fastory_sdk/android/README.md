> Mirrored from packages/sdk/android — keep in sync until the v0.2 artifact dependency

# fastory_sdk — Android

- `src/main/kotlin/com/fastory/sdk/`: copy of the native Android SDK core classes (`Fastory`,
  `FastoryConfig`, `FastoryHubActivity`, `GameBottomSheet`, `UrlPolicy`). The only allowed
  adaptation is the `com.fastory.sdk.flutter.R` import (the plugin's Gradle namespace differs from
  the native module's).
- `src/main/kotlin/com/fastory/sdk/flutter/FastorySdkPlugin.kt`: Flutter bridge (MethodChannel
  `fastory_sdk`, EventChannel `fastory_sdk/events`), plugin-specific — not part of the sync.
- `src/main/res/` and `src/main/AndroidManifest.xml`: copies of the native module's resources and
  manifest.

Any change to the core classes must be made in `packages/sdk/android`, then mirrored here verbatim.
