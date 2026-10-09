# Dictator

Minimal, local-only dictation for macOS. Press a shortcut, talk, and the text is typed into
whatever field has focus. Transcription runs on-device with **Whisper Large v3 Turbo** (WhisperKit
Core ML), bundled inside the app.

- **Tap** the shortcut to start, tap again to stop.
- **Hold** the shortcut to talk, release to finish.
- Default shortcut: **⌃⌥D**. Change it in Settings (menu bar icon → Settings…).

That's the whole feature set.

## Build

Requires macOS 15+, Apple silicon, Xcode 26+ (Swift 6.2+).

```sh
scripts/build-app.sh            # fetches + verifies the model, builds, signs → build/Dictator.app
open build/Dictator.app
```

First launch: grant **Microphone** and **Accessibility** (needed to type into other apps). The
first model load specialises Core ML for your chip and can take a few minutes; later launches take
about a second.

For a stable signature (so macOS remembers permissions across rebuilds), sign with your own
identity: `SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh`. Ad-hoc builds (the default)
must be re-granted Accessibility after each rebuild.

## Test

```sh
swift test
```

`WhisperTranscriptionTests` runs a real end-to-end transcription (speech synthesised with `say`)
when `Model/` exists; run `scripts/fetch-model.sh` first.

## CI / Release

- **Quality gate** (`.github/workflows/quality-gate.yml`): every push to any branch resolves
  dependencies against `Package.resolved`, builds release, and runs `swift test` (the model-based
  end-to-end test is skipped).
- **Release** (`.github/workflows/release.yml`): publishing a GitHub release builds
  `Dictator.app` (version taken from the tag, `v` prefix stripped) and attaches
  `Dictator-<tag>-macos-arm64.zip` plus its `.sha256`. Builds are ad-hoc signed and not notarised,
  so users must right-click → Open (or remove quarantine) on first launch.

## Architecture

```mermaid
flowchart LR
    Hotkey[CarbonHotkey] --> Controller
    subgraph DictationCore [DictationCore · no dependencies]
        Controller[DictationController<br/>state machine]
        Ports[[AudioRecording · Transcribing · TextInserting]]
    end
    Controller --> Ports
    Mic[MicrophoneRecorder<br/>AVAudioEngine → 16 kHz] -.implements.-> Ports
    Whisper[WhisperKitTranscriber<br/>WhisperTranscription target] -.implements.-> Ports
    Typer[KeystrokeTextInserter<br/>CGEvent unicode] -.implements.-> Ports
    Controller --> UI[Menu bar · Overlay · Settings]
```

| Target | Responsibility |
| --- | --- |
| `DictationCore` | Pure logic: tap/hold state machine, shortcut model, transcript cleanup, text chunking. Defines the ports. Fully unit-tested with fakes. |
| `WhisperTranscription` | The **only** code that imports WhisperKit. Swap the model/engine here. |
| `Dictator` | macOS adapters (hotkey, mic, typing, permissions) and SwiftUI/AppKit UI. Composition root is `AppModel`. |

## Security

- **Offline by construction.** The app is sandboxed with no network entitlement, so it cannot open
  connections. WhisperKit is configured with `download: false` and the tokenizer is bundled; the
  transcriber refuses to load if any required file is missing (WhisperKit would otherwise fall
  back to downloading).
- **Minimal entitlements:** App Sandbox + microphone. Hardened runtime.
- **No clipboard.** Text is typed via synthetic Unicode key events, so dictations never pass
  through the pasteboard (clipboard managers, other apps) and your clipboard is untouched.
- **Output is sanitised:** single line only (newlines/tabs become spaces, so dictation can't press
  Enter and submit a form) and control characters are stripped.
- **Audio stays in memory** for one dictation only, capped at 10 minutes, never written to disk.
  Transcripts are never logged.
- **Hotkey via Carbon `RegisterEventHotKey`:** sees only the registered shortcut. No Input
  Monitoring permission, no global key logging.
- **Supply chain:** one third-party dependency, WhisperKit, pinned to an exact version
  (`Package.resolved` is committed). Model files are pinned to immutable Hugging Face commits and
  verified by SHA-256 (`scripts/model-manifest.txt`); LFS hashes were cross-checked against
  Hugging Face's published hashes.

### Updating dependencies

- **WhisperKit:** bump `exact:` in `Package.swift`, review the upstream diff, `swift package resolve`,
  run `swift test`.
- **Model:** regenerate `scripts/model-manifest.txt` against a new pinned commit, then delete
  `Model/` and run `scripts/fetch-model.sh`.
