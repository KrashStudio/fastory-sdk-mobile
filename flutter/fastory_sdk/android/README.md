# fastory_sdk — Android

The plugin's Android side. A Flutter plugin ships its native code as sources, so this directory holds
the SDK's Android implementation in Kotlin, compiled into your app by Gradle like any other Android
library — there is nothing here to configure.

- `src/main/kotlin/com/fastory/sdk/`: the SDK itself — the hub activity, the game sheet, the URL
  policy and the message bridge.
- `src/main/kotlin/com/fastory/sdk/flutter/`: the bridge to Dart (MethodChannel `fastory_sdk`,
  EventChannel `fastory_sdk/events`).
- `src/main/res/`, `src/main/AndroidManifest.xml`, `consumer-rules.pro`: the resources, the manifest
  entries the SDK needs, and the R8 keep rule applied to your application through
  `consumerProguardFiles` — which is why you need no ProGuard rule of your own.

**The SDK's public API is the Dart one.** Nothing in this directory is meant to be called from a host
app: see the plugin's `README.md` for the surface, and `SPEC.md` at the repository root for the
normative contract.
