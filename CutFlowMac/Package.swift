// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CutFlowMac",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CutFlowCore", targets: ["CutFlowMac"])],
    dependencies: [.package(path: "Vendor/argmax-oss-swift-1.1.0")],
    targets: [
        .target(name: "CutFlowMac", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift-1.1.0")], exclude: ["CutFlowApp.swift"]),
        .testTarget(name: "CutFlowMacTests", dependencies: ["CutFlowMac", .product(name: "WhisperKit", package: "argmax-oss-swift-1.1.0")])
    ]
)
