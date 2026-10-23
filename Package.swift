// swift-tools-version: 5.9
import PackageDescription
import Foundation

// CLT's Swift Build engine sometimes omits automatic discovery of the Testing macro library.
let testingPlugin = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugin)
    ? [.unsafeFlags(["-load-plugin-library", testingPlugin])] : []

let package = Package(
    name: "InterviewAudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "InterviewAudio", targets: ["InterviewAudio"]),
        .executable(name: "AudioWorker", targets: ["AudioWorker"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "PromptResources", path: "backend/src/interview_backend/prompts",
                exclude: ["README.md", "agent", "memory", "tools"], resources: [.copy("connection")]),
        .target(name: "AudioCore", dependencies: ["CSQLite", "PromptResources"]),
        .executableTarget(name: "InterviewAudio", dependencies: ["AudioCore"]),
        .executableTarget(name: "AudioWorker", dependencies: ["AudioCore"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore", "InterviewAudio"], swiftSettings: testSettings)
    ]
)
