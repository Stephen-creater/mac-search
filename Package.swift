// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacSearch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacSearchCore", targets: ["MacSearchCore"]),
        .library(name: "MacSearchApp", targets: ["MacSearchApp"]),
        .executable(name: "MacSearch", targets: ["MacSearch"]),
        .executable(name: "macsearch-cli", targets: ["macsearch-cli"])
    ],
    targets: [
        .target(name: "CMacSearch", publicHeadersPath: "include"),
        .target(name: "MacSearchCore", dependencies: ["CMacSearch"]),
        .target(name: "MacSearchApp", dependencies: ["MacSearchCore"]),
        .executableTarget(name: "MacSearch", dependencies: ["MacSearchApp"]),
        .executableTarget(name: "macsearch-cli", dependencies: ["MacSearchCore"]),
        .testTarget(name: "MacSearchCoreTests", dependencies: ["MacSearchCore", "CMacSearch"]),
        .testTarget(name: "MacSearchUITests", dependencies: ["MacSearchApp", "MacSearchCore"])
    ],
    swiftLanguageVersions: [.v5]
)
