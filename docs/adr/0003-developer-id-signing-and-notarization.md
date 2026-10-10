# 3. Releases are signed with Developer ID and notarized

- Status: Accepted
- Date: 2026-10-10

## Context

Until v0.1.0, releases were ad-hoc signed and not notarized. That had two costs:

- Gatekeeper blocked the first launch, so users had to find System Settings → Privacy & Security
  → Open Anyway (or remove the quarantine flag by hand).
- macOS keys privacy permissions (Microphone, Input Monitoring, Accessibility) to the app's code
  identity. An ad-hoc identity is the binary's hash, so every update looked like a new app and
  permissions had to be granted again (see `docs/research/accessibility-permission-detection.md`).

## Decision

- The Release workflow signs `Dictator.app` with the **Developer ID Application** identity of team
  55GY5DC584, using hardened runtime (`--options runtime`), a secure timestamp and the existing
  sandbox entitlements. No new entitlements are needed.
- Only the app is signed, without `--deep`: the executable is statically linked (no frameworks,
  dylibs or helpers), and the Core ML `.mlmodelc` folders are data, sealed by the app's signature.
- It is **notarized** with `notarytool` using an App Store Connect API key, then **stapled**, so
  Gatekeeper accepts it offline. It is verified with `codesign --verify --strict --deep`,
  `spctl -a -t exec` and `stapler validate`, also on the app unzipped from the final archive.
- Secrets live in encrypted repo secrets (`APPLE_DEVELOPER_ID_P12_*`, `APPLE_ASC_*`,
  `APPLE_TEAM_ID`). They're used only in the Release job: a temporary keychain (always deleted)
  and a mode-600 key file (always removed). They are never echoed.
- `workflow_dispatch` runs the same pipeline as a dry run and uploads the zip as an artifact, so
  signing can be tested without publishing.

## Consequences

- The app opens without a Gatekeeper warning, and permissions survive updates. Because the
  identity is now stable, users only grant them again once, when moving from an ad-hoc build to
  the first signed one.
- A release takes a few minutes longer while Apple's notary service runs.
- The certificate expires in 2031, and the API key can be revoked. Either one breaks releases
  until the secret is replaced. Rotate both by updating the repo secrets; no code changes.
- Local builds stay ad-hoc unless `SIGN_IDENTITY` is set. With a Developer ID identity they get
  a secure timestamp, but they're not notarized.
