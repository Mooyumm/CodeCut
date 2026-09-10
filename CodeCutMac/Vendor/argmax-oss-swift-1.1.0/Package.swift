// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "argmax-oss-swift",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WhisperKit", targets: ["WhisperKit"])],
    targets: [
        .target(name: "ArgmaxCore", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "WhisperKit", dependencies: ["ArgmaxCore"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")])
    ],
    swiftLanguageVersions: [.v5]
)
