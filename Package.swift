// swift-tools-version: 5.9
import PackageDescription

// The Fastory Mobile SDK's native Swift channel. It sits at the repository root because SwiftPM
// cannot resolve a package held in a subdirectory; the Flutter plugin under flutter/ falls outside
// every declared target path, so the two channels coexist here without SwiftPM ever seeing it.
//
// One target, sources only: no test target and therefore no resources declaration, so there is
// nothing for SwiftPM to process before it compiles.
let package = Package(
    name: "FastorySDK",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "FastorySDK", targets: ["FastorySDK"])
    ],
    targets: [
        .target(name: "FastorySDK")
    ]
)
