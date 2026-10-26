// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mixerMac",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "mixerMac", targets: ["mixerMac"])
    ],
    targets: [
        .target(name: "mixerMacDSP", publicHeadersPath: "include"),
        .executableTarget(name: "mixerMac", dependencies: ["mixerMacDSP"]),
        .testTarget(name: "mixerMacTests", dependencies: ["mixerMac"])
    ]
)
