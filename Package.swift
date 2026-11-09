// swift-tools-version: 6.1
// BelfryCore: everything a Belfry chat client does that is not UI (SPEC.md), tested against
// vectors/*.json. The iOS app (App/, built with XcodeGen) depends on it.
import PackageDescription

let package = Package(
    name: "BelfryCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BelfryCore", targets: ["BelfryCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
    ],
    targets: [
        .target(
            name: "BelfryCore",
            dependencies: [.product(name: "P256K", package: "swift-secp256k1")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BelfryCoreTests",
            dependencies: ["BelfryCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
