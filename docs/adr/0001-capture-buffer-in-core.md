# 1. CaptureBuffer lives in DictationCore

- Status: Accepted
- Date: 2026-10-09

## Context

`CaptureBuffer` holds the samples of a dictation while the realtime audio thread appends to them:
the 0.4 s pre-roll ring, the capture itself, its 10-minute capacity, and the level callback. It
was a private part of `MicrophoneRecorder.swift` in the `Dictator` target, which only builds on
macOS and has no unit tests, so its logic (pre-roll prepending, truncation, clearing) was only
ever exercised by hand.

At the capacity it truncated silently: a recording kept "running" while every further word was
thrown away. Fixing that needs a callback at the moment of the first truncation, which is exactly
the kind of edge case that should be tested.

## Decision

Move `CaptureBuffer` into `DictationCore` as a public `Sendable` class guarded by a `Mutex`
(Synchronization), with identical behaviour, and add `onCapacityReached`: called once per capture,
on the first chunk that doesn't fit, outside the lock and without blocking, because it runs on the
realtime audio thread. The controller handles it with `recordingReachedLimit()`, which finishes the
recording normally (so the 10 minutes are transcribed and typed) and says why it stopped.

The AVAudioEngine tap, format conversion and device handling stay in the app
(`MicrophoneRecorder` / `AudioEngineHost`): they need AVFoundation and real hardware.

## Consequences

- The buffer's behaviour is covered by `CaptureBufferTests`, which run anywhere DictationCore
  builds (including Linux) as well as in the macOS quality gate.
- DictationCore gains a dependency on the standard `Synchronization` module (no third-party code).
- Callbacks from the buffer must stay non-blocking; the app hops to the main actor with
  `Task { @MainActor in … }`.
- Out of scope: changing the 10-minute value, transcribing long recordings in chunks, and any UI.

> Update (2026-10-10): DictationCore is now its own package; see ADR 0002.
