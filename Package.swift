// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DevCleaner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
        .library(name: "DevCleanerUI", targets: ["DevCleanerUI"]),
        .executable(name: "devcleaner", targets: ["devcleaner"]),
        .executable(name: "DevCleanerApp", targets: ["DevCleanerApp"]),
    ],
    targets: [
        .target(name: "CleanerCore"),
        // Every decision and every user-facing string. A test target cannot import an
        // executable target, so anything checkable lives here rather than in DevCleanerApp.
        .target(name: "DevCleanerUI", dependencies: ["CleanerCore"]),
        .executableTarget(name: "devcleaner", dependencies: ["CleanerCore"]),
        .executableTarget(name: "DevCleanerApp", dependencies: ["DevCleanerUI"]),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
        .testTarget(name: "DevCleanerUITests", dependencies: ["DevCleanerUI"]),
    ]
)
