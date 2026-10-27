// swift-tools-version: 6.0
import PackageDescription

// Core + CLI + tests build on macOS and Linux. The SwiftUI app is macOS-only and is
// declared under `#if os(macOS)` so `swift build` on Linux skips it.
//
// The CLI target is `L2DatCLI` (product/binary `l2dat`): a target or folder named `l2dat`
// would collide with `L2Dat` on case-insensitive file systems (APFS default).

var products: [Product] = [
    .executable(name: "l2dat", targets: ["L2DatCLI"]),
]

var targets: [Target] = [
    .target(name: "L2Dat"),
    .target(name: "L2Crypt"),
    .executableTarget(
        name: "L2DatCLI",
        dependencies: [
            "L2Dat",
            "L2Crypt",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    .target(name: "TestSupport", path: "Tests/TestSupport"),
    .testTarget(name: "L2DatTests", dependencies: ["L2Dat", "TestSupport"]),
    .testTarget(name: "L2CryptTests", dependencies: ["L2Crypt", "TestSupport"]),
    .testTarget(name: "GoldenCorpusTests", dependencies: ["L2Dat", "L2Crypt", "TestSupport"]),
]

#if os(macOS)
products.append(.executable(name: "L2FileEditor", targets: ["L2FileEditorApp"]))
targets.append(
    .executableTarget(
        name: "L2FileEditorApp",
        dependencies: ["L2Dat", "L2Crypt"],
        resources: [
            .copy("Resources/DAT_defs"),
            .copy("Resources/chronicles.json"),
        ]
    )
)
#endif

let package = Package(
    name: "L2FileEditor",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
