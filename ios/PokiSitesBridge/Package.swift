// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PokiSitesBridge",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PokiSitesBridge", targets: ["PokiSitesBridge"]),
    ],
    targets: [
        .target(name: "PokiSitesBridge"),
        .testTarget(
            name: "PokiSitesBridgeTests",
            dependencies: ["PokiSitesBridge"]
        ),
    ]
)
