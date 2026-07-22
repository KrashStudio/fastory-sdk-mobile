> Mirrored from packages/sdk/ios — keep in sync until the v0.2 artifact dependency

# fastory_sdk — iOS

- `Classes/Fastory.swift`, `Classes/FastoryConfig.swift`, `Classes/FastoryHubViewController.swift`,
  `Classes/FastoryGameSheetViewController.swift`, `Classes/URLPolicy.swift`: verbatim copies of the
  native Swift package sources (`packages/sdk/ios/Sources/FastorySDK`).
- `Classes/FastorySdkPlugin.swift`: Flutter bridge (MethodChannel `fastory_sdk`, EventChannel
  `fastory_sdk/events`), plugin-specific — not part of the sync.

Any change to the core classes must be made in `packages/sdk/ios`, then mirrored here verbatim.
