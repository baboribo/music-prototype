// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InnerTubeProbe",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "InnerTubeKit", targets: ["InnerTubeKit"]),
    ],
    targets: [
        .target(name: "InnerTubeKit"),
        .executableTarget(name: "itprobe", dependencies: ["InnerTubeKit"]),
    ]
)
