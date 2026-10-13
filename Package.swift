// swift-tools-version: 5.9
import PackageDescription

// The Fastory Mobile SDK's native Swift channel. It sits at the repository root because SwiftPM
// cannot resolve a package held in a subdirectory; the Flutter plugin under flutter/ falls outside
// every declared target path, so the two channels coexist here without SwiftPM ever seeing it.
//
// A single library target. Its only resources are the string tables the native error view
// reads, one per language, which is why the manifest names a default localization.
let package = Package(
    name: "FastorySDK",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "FastorySDK", targets: ["FastorySDK"])
    ],
    targets: [
        .target(
            name: "FastorySDK",
            resources: [.process("Resources")]
        )
    ]
)
