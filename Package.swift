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
    dependencies: [
        .package(url: "https://github.com/duckdb/duckdb-swift", .upToNextMajor(from: "1.0.0"))
    ],
    targets: [
        .target(
            name: "LightDataCore",
            dependencies: [
                .product(name: "DuckDB", package: "duckdb-swift")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "LightData",
            dependencies: [
                "LightDataCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
