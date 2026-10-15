# 6. Let the user choose the speech model; download nothing until they do

- Status: Accepted
- Date: 2026-10-14
- Note (2026-10-15): Dictator is English-only; Dansk is no longer offered. Whisper remains for Automatic/English when Parakeet is not chosen.
- Supersedes: [ADR 0004](0004-download-model-on-first-launch.md) (automatic first-launch download)

## Context

ADR 0004 downloaded Whisper Large v3 Turbo (about 1.6 GB) automatically on first launch. Research
(14 Oct 2026, Open ASR Leaderboard) shows NVIDIA Parakeet TDT 0.6B v2 is more accurate for English
(6.05 vs 7.83 average WER), many times faster, and about a third of the download. It is English
only, so Whisper stays available for Automatic or English language selection. The same choice is being added to
the iOS and Android apps.

## Decision

- Two models, ranked best first: **Parakeet TDT 0.6B v2** (`parakeet-tdt-0.6b-v2`, Core ML
  conversion `FluidInference/parakeet-tdt-0.6b-v2-coreml@ee09c56`, run with FluidAudio 0.17.7) and
  **Whisper Large v3 Turbo** (unchanged).
- **No automatic download.** On launch, only if no model has been chosen, a picker lists the models
  best first with size, accuracy and speed. Only the chosen model is downloaded. A copy that already
  has a verified Whisper download adopts it as the choice and is not asked.
- The choice is stored in UserDefaults (`speechModel`). Settings → Model switches models (download
  on demand) and can delete a model that isn't in use.
- Both models are pinned in the same bundled `model-manifest.txt` (SHA-256 and size per file, one
  model-id each) and use the same `ModelInstaller`: Range-request resume, retry, verification,
  `.complete` marker. The manifest stays the only trust anchor and is never fetched.
- FluidAudio sits behind the existing `Transcribing` seam in its own `ParakeetTranscription` target.
  It loads with `AsrModels.loadLocal` and never downloads. Its NemoTextProcessing binary trait is
  off. The Whisper 30-second splitter is not used for Parakeet, which windows long audio itself.
- Parakeet is English only; the language picker is disabled while it is in use.
- Attribution for the CC-BY-4.0 model is in `THIRD_PARTY_NOTICES.md` (bundled) and the README.

## Consequences

- A fresh install needs one choice before dictation works; nothing touches the network before it.
- One more pinned dependency (FluidAudio, Apache 2.0, no transitive dependencies with the trait off).
- Model folders are kept while in the manifest; switching back to an installed model is instant.
