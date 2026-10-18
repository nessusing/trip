// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Trip",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "Trip",
            targets: ["Trip"]
        ),
    ],
    targets: [
        .target(
            name: "Trip",
            resources: [.copy("Resources/pois.json")]
        ),
    ]
)
