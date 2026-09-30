// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DuckyRGB",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DuckyRGB", targets: ["DuckyRGB"])],
    targets: [
        .target(name: "DuckyCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "DuckyRGB", dependencies: ["DuckyCore"]),
        .testTarget(name: "DuckyCoreTests", dependencies: ["DuckyCore"]),
    ]
)
