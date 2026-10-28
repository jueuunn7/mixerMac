// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mixerMac",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "MixerCore", targets: ["MixerCore"]),
        .library(name: "MixerAudio", targets: ["MixerAudio"]),
        .executable(name: "mixerMac", targets: ["mixerMac"])
    ],
    targets: [
        .target(name: "MixerCore"),
        .target(name: "mixerMacDSP", publicHeadersPath: "include"),
        .target(name: "MixerAudio", dependencies: ["MixerCore", "mixerMacDSP"]),
        .executableTarget(name: "mixerMac", dependencies: ["MixerCore", "MixerAudio"]),
        .testTarget(name: "MixerCoreTests", dependencies: ["MixerCore"]),
        .testTarget(name: "mixerMacTests", dependencies: ["mixerMac", "MixerCore", "MixerAudio"])
    ]
)
