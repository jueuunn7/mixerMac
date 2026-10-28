// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mixerMac",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "MixerCore", targets: ["MixerCore"]),
        .library(name: "MixerStandardNodes", targets: ["MixerStandardNodes"]),
        .library(name: "MixerAudio", targets: ["MixerAudio"]),
        .executable(name: "mixerMac", targets: ["mixerMac"])
    ],
    targets: [
        .target(name: "MixerCore"),
        .target(name: "MixerStandardNodes", dependencies: ["MixerCore"]),
        .target(name: "mixerMacDSP", publicHeadersPath: "include"),
        .target(name: "MixerAudio", dependencies: ["MixerCore", "MixerStandardNodes", "mixerMacDSP"]),
        .executableTarget(name: "mixerMac", dependencies: ["MixerCore", "MixerStandardNodes", "MixerAudio"]),
        .target(name: "MixerExtensionFixtures", dependencies: ["MixerCore"], path: "Tests/ExtensionFixtures"),
        .target(name: "MixerAudioExtensionFixtures", dependencies: ["MixerCore", "MixerAudio"], path: "Tests/AudioExtensionFixtures"),
        .testTarget(name: "MixerCoreTests", dependencies: ["MixerCore", "MixerExtensionFixtures"]),
        .testTarget(name: "MixerStandardNodesTests", dependencies: ["MixerCore", "MixerStandardNodes"]),
        .testTarget(name: "mixerMacTests", dependencies: ["mixerMac", "MixerCore", "MixerStandardNodes", "MixerAudio", "MixerAudioExtensionFixtures"])
    ]
)
