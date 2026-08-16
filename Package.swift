// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Macquet",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacquetCore", targets: ["MacquetCore"]),
        .executable(name: "Macquet", targets: ["Macquet"]),
        .executable(name: "MacquetQL", targets: ["MacquetQL"]),
    ],
    dependencies: [
        .package(url: "https://github.com/duckdb/duckdb-swift.git", exact: "1.1.3"),
    ],
    targets: [
        .target(
            name: "MacquetCore",
            dependencies: [.product(name: "DuckDB", package: "duckdb-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Macquet",
            dependencies: ["MacquetCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The Quick Look extension. It is assembled into an `.appex` bundle by
        // Scripts/build-app.sh, which is why the entry point is overridden:
        // an app extension is launched through `NSExtensionMain`, not `main`.
        .executableTarget(
            name: "MacquetQuickLook",
            dependencies: ["MacquetCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        .executableTarget(
            name: "MacquetQL",
            dependencies: [
                "MacquetCore",
                .product(name: "DuckDB", package: "duckdb-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
