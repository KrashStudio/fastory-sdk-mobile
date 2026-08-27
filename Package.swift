// swift-tools-version: 5.9
import PackageDescription

// The manifest that ships to the public mirror as its root Package.swift — SwiftPM cannot resolve a
// package held in a subdirectory, so this one governs the whole repo while the Flutter plugin keeps
// living under flutter/ (outside every declared target path, therefore invisible to SwiftPM).
//
// Deliberately not the development manifest: Tests/ never ships. The dormant v1 contracts name
// unreleased features and internal Linear issues, and the shared fixtures are the cross-platform
// truth tables the suites run against — an integrator has no use for either. Dropping the test
// target also drops the only resources declaration, so this package is pure sources — nothing to
// process, nothing to leak.
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
