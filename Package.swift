// swift-tools-version: 6.0
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "fdb-record-layer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "FDBRecordCore",
            targets: ["FDBRecordCore"]
        ),
        .library(
            name: "FDBRecordLayer",
            targets: ["FDBRecordLayer"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.6.4"
        ),
        .package(
            url: "https://github.com/apple/swift-metrics.git",
            from: "2.5.0"
        ),
        .package(
            url: "https://github.com/MrLotU/SwiftPrometheus.git",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/1amageek/fdb-swift-bindings.git",
            branch: "feature/directory-layer"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.33.3"
        ),
        .package(
            url: "https://github.com/apple/swift-collections.git",
            from: "1.3.0"
        ),
        .package(
            url: "https://github.com/apple/swift-syntax.git",
            from: "600.0.0"
        ),
    ],
    targets: [
        // Macro implementation (compiler plugin)
        .macro(
            name: "FDBRecordLayerMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/FDBRecordLayerMacros"
        ),

        // Core library (FDB-independent, shared by client and server)
        .target(
            name: "FDBRecordCore",
            dependencies: [
                "FDBRecordLayerMacros",
            ],
            path: "Sources/FDBRecordCore"
        ),

        // Main library (FDB-dependent, server-only)
        .target(
            name: "FDBRecordLayer",
            dependencies: [
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "SwiftPrometheus", package: "SwiftPrometheus"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Collections", package: "swift-collections"),
                "FDBRecordCore",
                "FDBRecordLayerMacros",
            ],
            path: "Sources/FDBRecordLayer"
        ),
        .testTarget(
            name: "FDBRecordLayerTests",
            dependencies: [
                "FDBRecordLayer",
                "FDBRecordLayerMacros",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/FDBRecordLayerTests",
            // Note: Swift 6 already enables BareSlashRegexLiterals, ConciseMagicFile,
            // ExistentialAny, ForwardTrailingClosures, and ImplicitOpenExistentials by default
            // Note: StrictConcurrency is NOT enabled for tests to allow flexible initialization patterns
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
            ]
        ),
    ]
)
