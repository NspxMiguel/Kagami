// swift-tools-version: 6.2
import PackageDescription

// Run the wire protocol and hardware decoder tests without booting a simulator.
let package = Package(
    name: "KagamiCore",
    platforms: [.macOS("15.4")],
    targets: [
        .target(
            name: "KagamiCore", path: "Sources",
            exclude: [
                "UI", "Resources", "Session.swift", "KagamiApp.swift", "Media/AudioOutput.swift",
            ],
            sources: [
                "Protocol", "Media/VideoDecoder.swift", "Media/PipelineStats.swift",
                "Media/VideoIngest.swift",
            ]),
        .testTarget(
            name: "KagamiCoreTests", dependencies: ["KagamiCore"],
            path: "Tests/KagamiCoreTests", resources: [.copy("Fixtures")]),
    ]
)
