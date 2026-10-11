# 4. Download the model on first launch instead of bundling it

- Status: Accepted
- Date: 2026-10-11

## Context

The app bundled Whisper Large v3 Turbo (about 1.6 GB) in `Contents/Resources/Model`. Every release
and update carried the full model, notarization uploads were huge, and adding a second model (for
example a Dansk-only fine-tune) would double the download for everyone. The iOS and Android apps are
moving to downloading the model after install too.

## Decision

- The model is **not bundled**. `scripts/build-app.sh` copies only `scripts/model-manifest.txt` into
  `Contents/Resources/model-manifest.txt`, where the app's signature seals it.
- **The bundled manifest is the only trust anchor and is never fetched from the network.** Each line
  is `<model-id> <sha256> <bytes> <huggingface-path> <local-path>`, pinned to an immutable Hugging
  Face commit (`argmaxinc/whisperkit-coreml@0f63a78`, tokenizer from `openai/whisper-large-v3-turbo`).
- On launch, `ModelDownload` (app) / `ModelInstaller` (WhisperTranscription) download any missing
  file **automatically** into `Application Support/Models/<model-id>/` in the sandbox container,
  excluded from backup: HTTP Range requests in 8 MB chunks appended to a `.part` file (so it resumes
  after a quit or a dropped connection), size + SHA-256 checked before the file is moved into place,
  up to five attempts with exponential backoff, and a `.complete` marker holding a digest of the
  model's manifest lines written last. Models no longer in the manifest are deleted.
- Progress and failures show in the menu bar menu and Settings, with **Retry Model Download**.
- WhisperKit keeps `download: false` and a local tokenizer folder; it never downloads by itself.
- The model-id column allows a second model (e.g. `thorhojhus/whisper-large-v3-turbo-danish`
  converted to Core ML and hosted on a captains-chest Hugging Face repo) as extra manifest lines.

## Consequences

- Wording changes from "offline, bundled" to: "Audio never leaves the device; the one-time model
  download is the only network use" (plus the optional update check).
- Dictation needs one online launch before it works. A Mac that is never online can't dictate.
- The app zip and notarization upload shrink by about 1.6 GB. The downloaded Core ML files are data
  outside the app's signature; integrity comes from the signed manifest's hashes.
- Existing `network.client` entitlement covers the download; no new entitlement or permission.
- Updating from a release that bundled the model triggers one download on the first launch.
