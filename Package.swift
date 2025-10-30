// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "fdb-record-layer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
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
            url: "https://github.com/foundationdb/fdb-swift-bindings.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.33.3"
        ),
    ],
    targets: [
        .target(
            name: "FDBRecordLayer",
            dependencies: [
                .product(name: "FoundationDB", package: "fdb-swift-bindings"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/FDBRecordLayer"
        ),
        .testTarget(
            name: "FDBRecordLayerTests",
            dependencies: ["FDBRecordLayer"],
            path: "Tests/FDBRecordLayerTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
