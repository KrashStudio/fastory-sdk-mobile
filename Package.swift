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
    dependencies: [
        // The reference OpenID client, carrying the system-browser leg of identify(.fanId):
        // authorization request, state and PKCE.
        .package(url: "https://github.com/openid/AppAuth-iOS.git", .upToNextMinor(from: "1.7.5"))
    ],
    targets: [
        .target(
            name: "FastorySDK",
            dependencies: [.product(name: "AppAuth", package: "AppAuth-iOS")],
            resources: [.process("Resources")]
        )
    ]
)
