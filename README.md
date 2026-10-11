# Dictator

Minimal, local-only dictation for macOS. Press a shortcut, talk, and the text is typed into
whatever field has focus. Transcription runs on-device with **Whisper Large v3 Turbo** (WhisperKit
Core ML), downloaded once on first launch (about 1.6 GB) and verified against a SHA-256 manifest
built into the app. Audio never leaves the device; the one-time model download is the only network
use (besides the optional update check).

- **Tap** the shortcut to start, tap again to stop.
- **Hold** the shortcut to talk, release to finish.
- Default shortcut: **⌃⌥D**. Change it in Settings (menu bar icon → Settings…): click the
  shortcut, hold any key or combination and let go. Anything works: bare keys, several keys at
  once, a single modifier (e.g. Right ⌥), fn or Caps Lock. A keyboard drawing shows the shortcut
  and lights up keys live while recording.

- **Undo Last Dictation** from the menu (or an optional shortcut) removes exactly what was just
  typed, as long as you haven't typed or clicked since.
- Consecutive dictations are spaced and capitalised to continue the sentence.
- **Language:** Automatic, Dansk or English (Settings → Model).
- Optional: open at login, keep the microphone ready (catches the first word), daily update check.

That's the whole feature set. See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

## Install

1. Download `Dictator-<version>-macos-arm64.zip` from the
   [latest release](https://github.com/captains-chest/yet-another-dictator/releases) (optionally
   check it against the `.sha256` with `shasum -a 256 -c`).
2. Unzip it and move `Dictator.app` to `/Applications`.
3. Open it. Signed, notarized releases (v0.1.1 and later) open without a Gatekeeper warning.
4. Grant Microphone, Input Monitoring and Accessibility when asked. These permissions stay granted
   when you update to a later signed release. If you're coming from v0.1.0 or earlier (ad-hoc
   signed), grant them once more.

## Build

Requires macOS 15+, Apple silicon, Xcode 26+ (Swift 6.2+).

```sh
scripts/build-app.sh            # builds, signs → build/Dictator.app (no model inside)
open build/Dictator.app
```

First launch: grant **Microphone**, **Input Monitoring** (needed to detect the shortcut) and
**Accessibility** (needed to type into other apps). Dictator then downloads the model
automatically (progress in the menu; it resumes after a quit or a dropped connection, and the menu
offers Retry if it fails). The first model load specialises Core ML for your chip and can take a few minutes; later launches take
about a second.

For a stable signature (so macOS remembers permissions across rebuilds), sign with your own
identity: `SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh` (or an Apple
Development identity). A real identity also gets a secure timestamp. Ad-hoc builds (the default)
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
  `Dictator-<tag>-macos-arm64.zip` plus its `.sha256`. From v0.1.1 the app is signed with
  Developer ID, notarized and stapled (see `docs/adr/0003`), so it opens without a Gatekeeper
  warning and macOS keeps its permissions across updates. Running the workflow manually
  (`workflow_dispatch`) is a dry run: same pipeline, the zip is uploaded as an artifact, nothing
  is published. v0.1.0 and earlier are ad-hoc signed and need System Settings → Privacy &
  Security → Open Anyway on first launch.

## Architecture

```mermaid
flowchart LR
    Hotkey[EventTapHotkey<br/>CGEvent tap] --> Controller
    subgraph DictationCore [DictationCore package · no dependencies]
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
| `DictationCore` | **Separate package**, [captains-chest/DictationCore](https://github.com/captains-chest/DictationCore), pinned exactly and shared with the iOS app. Pure logic: tap/hold state machine, shortcut chord model and matcher, transcript cleanup and smart spacing, the punctuation prompt given to Whisper, text chunking, capture buffer, undo history, version/What's New/update-check logic. Defines the ports. Its tests (with fakes) live in that repo. Change it there, tag a release, then bump the exact pin here (see `docs/adr/0002`). |
| `WhisperTranscription` | The **only** code that imports WhisperKit. Swap the model/engine here. |
| `Dictator` | macOS adapters (hotkey, mic, typing, permissions) and SwiftUI/AppKit UI. Composition root is `AppModel`. |

## Security

- **Audio never leaves the device; the one-time model download is the only network use** (plus the
  optional update check below). On first launch `ModelInstaller` downloads the files listed in
  `model-manifest.txt`, which ships inside the signed app and is never fetched from the network, from
  immutable Hugging Face commits into `~/Library/Containers/com.captainduckay.dictator/Data/Library/Application Support/Models`
  (excluded from backup). Every file must match its size and SHA-256 before it is used; a `.complete`
  marker is written last. WhisperKit itself runs with `download: false` and a local tokenizer, and the
  transcriber refuses to load if any required file is missing (ADR 0004).
- **The update check, and you can turn it off.** Once a day, `UpdateChecker` asks GitHub's public releases API whether a newer version exists, and the menu
  offers to open the release page. Nothing is downloaded or installed, no token or user data is
  sent (ephemeral session), and Settings → General → *Check for updates daily* turns it off.
- **Minimal entitlements:** App Sandbox + microphone + outgoing network connections (for the
  model download and the update check). Hardened runtime.
- **No clipboard.** Text is typed via synthetic Unicode key events, so dictations never pass
  through the pasteboard (clipboard managers, other apps) and your clipboard is untouched.
- **Output is sanitised:** single line only (newlines/tabs become spaces, so dictation can't press
  Enter and submit a form) and control characters are stripped.
- **Audio stays in memory** for one dictation only, capped at 10 minutes, never written to disk.
  Transcripts are never logged. If typing fails, that one transcript is kept in memory (never on
  disk) so it can be typed again from the menu, until it's discarded or the next dictation succeeds.
- **Hotkey via a CoreGraphics event tap** so any key combination can be the shortcut. This needs
  Input Monitoring: the tap sees every key event, but each is only compared in memory against the
  shortcut and immediately dropped; nothing is stored, logged or published. Dictator's own typed
  text is ignored. The shortcut's non-modifier keys are withheld from other apps when macOS allows
  an active tap (otherwise they pass through, and Settings warns if the shortcut would type into
  the focused app). Modifier keys, fn and Caps Lock always reach other
  apps (Caps Lock still toggles, and fn may still open the emoji picker depending on System
  Settings). Like all event taps, it can't see keys while a password field has secure input on.
- **Supply chain:** one third-party dependency, WhisperKit, pinned to an exact version
  (`Package.resolved` is committed). Model files are pinned to immutable Hugging Face commits and
  verified by SHA-256 (`scripts/model-manifest.txt`); LFS hashes were cross-checked against
  Hugging Face's published hashes.

### Updating dependencies

- **WhisperKit:** bump `exact:` in `Package.swift`, review the upstream diff, `swift package resolve`,
  run `swift test`.
- **Model:** regenerate `scripts/model-manifest.txt` (`<model-id> <sha256> <bytes> <hf-path>
  <local-path>`) against a new pinned commit, then delete `Model/` and run `scripts/fetch-model.sh`
  for the end-to-end test. Installed apps download the new files on their next launch and delete
  models no longer in the manifest. A second model (e.g. Dansk-only) is extra lines with its own
  model-id.

## License

MIT © 2026 CaptainDuckay. See [LICENSE](LICENSE). Third-party components (WhisperKit,
the downloaded Whisper model) are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
