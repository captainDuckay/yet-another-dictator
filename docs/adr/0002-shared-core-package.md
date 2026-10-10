# 2. The dictation core is a separate, shared package

- Status: Accepted
- Date: 2026-10-10

## Context

All platform-free logic (the `DictationController` state machine and its ports, transcript
cleanup, smart spacing, undo history, the capture buffer, shortcuts, and the version, What's New
and update-check logic) lived in the app's `DictationCore` target. A future iOS app needs the same
logic. Copying it would let the two drift apart.

## Decision

Move `DictationCore` to its own repository, [captains-chest/DictationCore](https://github.com/captains-chest/DictationCore),
with the module and product name unchanged, so `import DictationCore` stays the same. The package
supports macOS 15 and iOS 18. iOS 18 is required because `CaptureBuffer` uses
`Synchronization.Mutex`.

- The app depends on it with an **exact** pin (`exact: "0.1.0"`), following the repo's
  supply-chain rule. Dependabot proposes bumps in their own group.
- The core's tests moved with it. The app keeps only `WhisperTranscriptionTests`.
- Release 0.1.0 was made from the app's core at main after #26, so there is no behaviour change.

## Consequences

- Changing core logic takes two steps: a PR plus a tag in the package, then a pin bump here.
- The package must stay pure (no AppKit, UIKit or third-party code) and keep building on Linux.
- The app's macOS CI no longer runs the core tests, so the package needs its own CI. A workflow
  is proposed in its `docs/ci.yml` but has to be enabled by an account with the `workflow` scope.
- ADR 0001 still applies; `CaptureBuffer` and its tests now live in the package.
