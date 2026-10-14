// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dictator",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Third-party dependencies, pinned exactly; bump deliberately after reviewing the diff.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // Parakeet TDT (Core ML). The NemoTextProcessing trait (a prebuilt binary for text
        // normalisation we don't use) is turned off, so only FluidAudio's own source is linked.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        // Our own shared core (state machine, shortcut model, transcript cleanup), also used by the
        // iOS app. Pinned exactly like everything else.
        .package(url: "https://github.com/captains-chest/DictationCore.git", exact: "0.2.1"),
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

        // The single seam where FluidAudio is used (Parakeet TDT 0.6B v2, English).
        .target(
            name: "ParakeetTranscription",
            dependencies: [
                .product(name: "DictationCore", package: "DictationCore"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        // Release lookup, signature policy and the replace step. Shared with the updater so the
        // unsandboxed helper checks the same facts the app does.
        .target(
            name: "AppUpdate",
            dependencies: [.product(name: "DictationCore", package: "DictationCore")]
        ),

        // macOS app: hotkey, microphone, text insertion, menu bar, overlay, settings.
        .executableTarget(
            name: "Dictator",
            dependencies: [
                .product(name: "DictationCore", package: "DictationCore"),
                "WhisperTranscription",
                "ParakeetTranscription",
                "AppUpdate",
            ]
        ),

        // Unsandboxed XPC service embedded in the app. Replaces Dictator.app and nothing else.
        .executableTarget(
            name: "DictatorUpdater",
            dependencies: ["AppUpdate"]
        ),

        // App-level logic with injected fakes (e.g. keystroke pacing, issue #43).
        .testTarget(
            name: "DictatorTests",
            dependencies: [
                .product(name: "DictationCore", package: "DictationCore"),
                "Dictator",
                "AppUpdate",
                "WhisperTranscription",
            ]
        ),
        .testTarget(name: "ParakeetTranscriptionTests", dependencies: ["ParakeetTranscription"]),
        .testTarget(name: "WhisperTranscriptionTests", dependencies: [.product(name: "DictationCore", package: "DictationCore"), "WhisperTranscription"]),
    ]
)
