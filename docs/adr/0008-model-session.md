# 8. One ModelSession runs every speech model

- Status: Accepted
- Date: 2026-10-17

## Context

WhisperKit and Parakeet each grew the same machinery in their own target: check the downloaded
files, load the engine once (in a detached, user-initiated task, shared between concurrent
`prepare` calls, cleared after failure so a retry works), let `transcribe` load first if needed,
serialise transcriptions so a new one waits for an abandoned one, and cancel by flagging a stop
signal. `WhisperKitTranscriber` and `ParakeetTranscriber` duplicated all of it, with drift:
Parakeet returned an empty string when its manager was somehow missing, and Whisper had a
`notLoaded` failure the session could really guarantee away.

Architect's brief called this ADR 0009, assuming 0008 was taken by microphone routing. It is not:
0007 is ADR 0007 in #58, so the next free number is 0008.

## Decision

A new `ModelSession` target (DictationCore and Foundation only) holds an
`actor ModelSession: Transcribing`. It owns folder checking (`Failure.missingModelFiles`, and the
load closure is never called when files are missing), loading once as above, latest-chain
serialisation, and cancellation: cancellation sets that transcription's `StopSignal` and cancels
its work task, so a stopped transcription throws `CancellationError`.

An adapter supplies only what is specific to its engine:

- `protocol LoadedSpeechModel` with one `transcribe(_:language:stop:)` method, and a
  `@Sendable (URL) async throws -> any LoadedSpeechModel` load closure.
- `ModelSession.whisperKit(modelFolder:)` builds WhisperKit with its required files, tokenised
  prompt, long-audio splitting at pauses (from #48), Whisper's repetition/compression filter and
  prompt-echo handling.
- `ModelSession.parakeet(modelFolder:)` builds FluidAudio's `AsrManager`; a stop set while
  Parakeet runs means `CancellationError` on return, so Parakeet can no longer return `""` for an
  unloaded model, and Whisper's `notLoaded` case is gone because the session guarantees a loaded
  model.

Call sites use `ModelSession.parakeet(modelFolder:)` / `.whisperKit(modelFolder:)`. The
`Transcribing` seam, `ActiveTranscriber` and the controller are unchanged.

### Rejected: A. A generic session over engine protocols

Parameterising the session over separate `ModelLoading`/`ModelRunning` protocol types, or a
generic `ModelSession<Engine>`, would keep the same runtime behaviour while exposing engine types
in the session's interface. The load closure and one `LoadedSpeechModel` method are smaller and
keep WhisperKit and FluidAudio types inside their own targets.

## Consequences

- Loading, ordering and cancellation are tested once, offline, with a gated fake loader, including
  a transcription cancelled while queued behind another, which never reaches the model.
- Intended behaviour changes: stopping a transcription surfaces as `CancellationError` for both
  models. Parakeet's old unloaded-empty-string path and Whisper's `notLoaded` failure are removed.
- Each adapter still checks its own required-file list before loading: `tokenizer.json` for
  WhisperKit (so it never falls back to downloading a tokenizer) and `parakeet_vocab.json` for
  Parakeet.
- WhisperKit and FluidAudio remain each inside one target; the comments naming that single seam
  stay accurate.
