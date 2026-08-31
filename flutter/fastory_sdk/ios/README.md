# fastory_sdk — iOS

The plugin's iOS side. A Flutter plugin ships its native code as sources, so this directory holds the
SDK's iOS implementation in Swift, compiled into your app by CocoaPods like any other pod — there is
nothing here to configure beyond the iOS 15 deployment target the podspec declares.

- `Classes/*.swift`: the SDK itself — the hub view controller, the game sheet, the URL policy and the
  message bridge — plus `FastorySdkPlugin.swift`, the bridge to Dart (MethodChannel `fastory_sdk`,
  EventChannel `fastory_sdk/events`).
- `fastory_sdk.podspec`: the pod definition CocoaPods resolves.

**The SDK's public API is the Dart one.** Nothing in this directory is meant to be called from a host
app: see the plugin's `README.md` for the surface, and `SPEC.md` at the repository root for the
normative contract. Native iOS apps that are not Flutter consume the same code as a Swift package
from this repository's root instead.
