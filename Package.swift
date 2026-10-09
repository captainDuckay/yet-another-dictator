// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dictator",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The only third-party dependency. Pinned exactly; bump deliberately after reviewing the diff.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        // Pure dictation logic: state machine, shortcut model, transcript cleanup. No third-party code.
        .target(name: "DictationCore"),

        // The single seam where WhisperKit is used.
        .target(
            name: "WhisperTranscription",
            dependencies: [
                "DictationCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),

        // macOS app: hotkey, microphone, text insertion, menu bar, overlay, settings.
        .executableTarget(
            name: "Dictator",
            dependencies: ["DictationCore", "WhisperTranscription"]
        ),

        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
        .testTarget(name: "WhisperTranscriptionTests", dependencies: ["WhisperTranscription"]),
    ]
)
