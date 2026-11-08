// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QEQ",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .library(name: "QEQCore", targets: ["QEQCore"]),
        .library(name: "QEQAppSupport", targets: ["QEQAppSupport"]),
    ],
    targets: [
        .target(
            name: "MixerDSP", path: "Sources/MixerDSP", publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(
            name: "QEQCore",
            dependencies: ["MixerDSP"],
            path: "Sources/QEQCore"
        ),
        .target(
            name: "QEQAppSupport",
            dependencies: ["QEQCore", "MixerDSP"],
            path: "Sources/QEQAppSupport",
            linkerSettings: [.linkedFramework("CoreMIDI")]
        ),
        .testTarget(
            name: "QEQTests",
            dependencies: ["QEQCore", "QEQAppSupport", "MixerDSP"],
            path: "Tests/QEQTests",
            resources: [.process("Fixtures")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
