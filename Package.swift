// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LightData",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LightData", targets: ["LightData"])
    ],
    targets: [
        .executableTarget(
            name: "LightData",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
