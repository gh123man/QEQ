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
        .executable(name: "QEQDisplayBench", targets: ["QEQDisplayBench"]),
    ],
    targets: [
        .target(
            name: "QEQHardware", path: "Sources/QEQHardware", exclude: ["LZ4/LICENSE", "LZ4/README.md"],
            publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("IOUSBHost"), .linkedFramework("IOKit"), .linkedLibrary("z")]),
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
            dependencies: ["QEQCore", "MixerDSP", "QEQHardware"],
            path: "Sources/QEQAppSupport",
            linkerSettings: [.linkedFramework("CoreMIDI"), .linkedFramework("Metal")]
        ),
        .executableTarget(name: "QEQDisplayBench", dependencies: ["QEQAppSupport", "QEQHardware"]),
        .target(
            name: "DisplayReceiverTestSupport", dependencies: ["QEQHardware"],
            path: "Tests/DisplayReceiverSupport", exclude: ["README.md"], publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("../../Sources/QEQHardware/LZ4")]),
        .testTarget(
            name: "QEQTests",
            dependencies: ["QEQCore", "QEQAppSupport", "MixerDSP", "QEQHardware", "DisplayReceiverTestSupport"],
            path: "Tests/QEQTests",
            resources: [.process("Fixtures")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
