// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeCutMac",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CodeCutCore", targets: ["CodeCutMac"])],
    dependencies: [.package(path: "Vendor/argmax-oss-swift-1.1.0")],
    targets: [
        .target(name: "CodeCutMac", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift-1.1.0")], exclude: ["CodeCutApp.swift"]),
        .testTarget(name: "CodeCutMacTests", dependencies: ["CodeCutMac", .product(name: "WhisperKit", package: "argmax-oss-swift-1.1.0")])
    ]
)
