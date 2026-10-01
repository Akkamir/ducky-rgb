// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DuckyRGB",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "DuckyRGB", targets: ["DuckyRGB"]),
        .executable(name: "ducky-agent-hook", targets: ["AgentHook"]),
        .library(name: "DuckyCore", targets: ["DuckyCore"]),
    ],
    targets: [
        .target(name: "DuckyCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "DuckyRGB", dependencies: ["DuckyCore"]),
        .executableTarget(name: "AgentHook", dependencies: ["DuckyCore"]),
        .testTarget(name: "DuckyCoreTests", dependencies: ["DuckyCore"]),
    ]
)
