// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "AudioSpike", platforms: [.macOS("14.2")],
    dependencies: [.package(path: "../../app")],
    targets: [.executableTarget(name: "AudioSpike", dependencies: [.product(name: "DuckyCore", package: "app")])])
