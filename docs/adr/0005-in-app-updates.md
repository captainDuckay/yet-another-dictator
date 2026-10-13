# 5. Updates install from the menu

- Status: Accepted
- Date: 2026-10-13

## Context

The menu could see a newer GitHub release, then sent the user to the release page to download a
zip, unzip it, and replace `Dictator.app` by hand. That is easy to get wrong, and it is the step
people skip. The app is sandboxed, so it cannot write into `/Applications` itself. ADR 0003 also
assumed a single static executable and no helper.

## Decision

- The daily check is unchanged: GitHub's public releases API, no token, nothing downloaded until
  the user chooses **Install Update**. The check can be turned off, and then Dictator makes no
  update request at all.
- The archive is the same `Dictator-<tag>-macos-arm64.zip` the release workflow already publishes,
  plus its `.sha256`. Both URLs must be `https://github.com/captains-chest/yet-another-dictator/releases/download/…`.
  Redirects may only go to `github.com`, `release-assets.githubusercontent.com`, or
  `objects.githubusercontent.com`.
- Before anything is replaced, the zip's SHA-256 must match the published checksum, the archive
  entries must stay inside the unpack directory, and the unpacked app must pass a Developer ID
  requirement for team `55GY5DC584` and identifier `com.captainduckay.dictator`, with hardened
  runtime, a stapled notarization ticket, nested code checked, and `spctl` accepting it.
  Downgrades are refused. The running copy only has to be Dictator at an older version, so an
  ad-hoc local build can move onto a signed release.
- The sandboxed app cannot do the replace. `DictatorUpdater.xpc` is embedded, signed inside-out
  with hardened runtime, and has no sandbox entitlement. It is started by launchd, checks the
  caller against the main executable's designated requirement, checks the staged app again, and
  replaces only the host `Dictator.app`. The previous copy is `Dictator.previous.app`, removed on
  the next launch. The new copy is then relaunched.
- A release without that zip still offers the release page. Versions before this one keep sending
  people to the page; the first update onto this mechanism is the last manual one.

This amends ADR 0003's "no helpers" consequence. The app stays sandboxed. There is still no
third-party updater framework.

## Consequences

- Installing an update needs one menu action and a relaunch. Microphone, Input Monitoring and
  Accessibility stay granted because the Developer ID is unchanged.
- The updater is a second executable in the notarized app. A sandboxed updater would not be able
  to replace the app, so its missing sandbox entitlement is checked in `scripts/build-app.sh` and
  in the release workflows.
- Someone who opens Dictator from the download without moving it (App Translocation) is told to
  move it to Applications first. The temporary copy is not writable.
- The trust decision is the published checksum plus Apple's signature. A substituted zip fails one
  of those checks and is not installed.
