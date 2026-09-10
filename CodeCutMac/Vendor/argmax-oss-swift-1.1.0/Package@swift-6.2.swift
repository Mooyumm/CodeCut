// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "argmax-oss-swift",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WhisperKit", targets: ["WhisperKit"])],
    targets: [
        .target(name: "ArgmaxCore"),
        .target(name: "WhisperKit", dependencies: ["ArgmaxCore"])
    ],
    swiftLanguageModes: [.v5]
)
