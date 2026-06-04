// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LightDataCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LightDataCore", targets: ["LightDataCore"])
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
        .testTarget(
            name: "LightDataCoreTests",
            dependencies: [
                "LightDataCore",
                .product(name: "DuckDB", package: "duckdb-swift")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
