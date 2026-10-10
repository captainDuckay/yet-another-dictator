// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dictator",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The only third-party dependency. Pinned exactly; bump deliberately after reviewing the diff.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // Our own shared core (state machine, shortcut model, transcript cleanup), also used by the
        // iOS app. Pinned exactly like everything else.
        .package(url: "https://github.com/captains-chest/DictationCore.git", exact: "0.1.0"),
    ],
    targets: [
        // The single seam where WhisperKit is used.
        .target(
            name: "WhisperTranscription",
            dependencies: [
                .product(name: "DictationCore", package: "DictationCore"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),

        // macOS app: hotkey, microphone, text insertion, menu bar, overlay, settings.
        .executableTarget(
            name: "Dictator",
            dependencies: [.product(name: "DictationCore", package: "DictationCore"), "WhisperTranscription"]
        ),

        .testTarget(name: "WhisperTranscriptionTests", dependencies: [.product(name: "DictationCore", package: "DictationCore"), "WhisperTranscription"]),
    ]
)
