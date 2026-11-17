// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "speakacross",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "speakacross", targets: ["SpeakAcrossApp"]),
        .executable(name: "speakacross-e2e-agent", targets: ["SpeakAcrossE2EAgent"]),
        .executable(name: "speakacross-full-e2e", targets: ["SpeakAcrossFullE2E"]),
        .library(name: "SpeakAcrossCore", targets: ["SpeakAcrossCore"])
    ],
    targets: [
        .target(name: "SpeakAcrossCore"),
        .executableTarget(name: "SpeakAcrossApp", dependencies: ["SpeakAcrossCore"]),
        .executableTarget(name: "SpeakAcrossE2EAgent", dependencies: ["SpeakAcrossCore"]),
        .executableTarget(name: "SpeakAcrossFullE2E", dependencies: ["SpeakAcrossCore"]),
        .testTarget(name: "SpeakAcrossCoreTests", dependencies: ["SpeakAcrossCore"])
    ]
)
