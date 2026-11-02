// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppMixer",
    platforms: [
        .macOS("14.4")
    ],
    products: [
        .library(name: "AppMixerCore", targets: ["AppMixerCore"]),
        .library(name: "AppMixerAppSupport", targets: ["AppMixerAppSupport"]),
    ],
    targets: [
        .target(
            name: "MixerDSP", path: "Sources/MixerDSP", publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(
            name: "AppMixerCore",
            dependencies: ["MixerDSP"],
            path: "Sources/AppMixerCore"
        ),
        .target(
            name: "AppMixerAppSupport",
            dependencies: ["AppMixerCore", "MixerDSP"],
            path: "Sources/AppMixerAppSupport"
        ),
        .testTarget(
            name: "AppMixerTests",
            dependencies: ["AppMixerCore", "AppMixerAppSupport", "MixerDSP"],
            path: "Tests/AppMixerTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
