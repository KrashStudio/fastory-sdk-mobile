> Mirrored from packages/sdk/ios — keep in sync until the v0.2 artifact dependency

# fastory_sdk — iOS

- `Classes/Fastory.swift`, `Classes/FastoryConfig.swift`, `Classes/FastoryHubViewController.swift`, `Classes/FastoryGameSheetViewController.swift`, `Classes/URLPolicy.swift` : copies à l'identique des sources du package Swift natif (`packages/sdk/ios/Sources/FastorySDK`).
- `Classes/FastorySdkPlugin.swift` : pont Flutter (MethodChannel `fastory_sdk`, EventChannel `fastory_sdk/events`), spécifique au plugin — pas concerné par la synchronisation.

Toute évolution des classes cœur doit être faite dans `packages/sdk/ios` puis reportée ici à l'identique.
