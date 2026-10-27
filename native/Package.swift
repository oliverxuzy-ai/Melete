// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpeechPractice",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "SpeechPractice",
            path: "Sources/SpeechPractice",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
