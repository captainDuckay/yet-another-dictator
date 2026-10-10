# Dictator roadmap

Feature tiers (Nicki's rules):

- **Core** (ship without asking): instant start/pre-roll, smart spacing/capitalization, model preload, reliability fixes.
- **Need-to-have** (build): language choice, launch at login, undo last dictation.
- **Nice-to-have** (Nicki decides — do not build): live preview, personal vocabulary, sounds, history, cloud models, AI rewriting, per-app profiles.

Offline only (update check may use network). No clipboard. Minimal entitlements. Exact version pins in `Package.swift`.

## Ops / Dependabot notes

- **2026-10-10 — Dependabot `illformed_requirement` on DictationCore:** Dependabot Updates run 38051879049 (swift) failed on main while Quality gate stayed green. Root cause: platform default 3-day cooldown filtered DictationCore's only tag (`0.1.0`, released the same day), so "Latest version is" was empty and the updater crashed with `illformed_requirement {message: "Illformed requirement [\"<=\"]"}` for `github.com/captains-chest/dictationcore`. WhisperKit survived because older tags (e.g. 1.1.0) remained after cooldown. Fix: `.github/dependabot.yml` keeps weekly schedule + exact-pin review, sets an explicit `cooldown.default-days: 3`, and `cooldown.exclude`s `*DictationCore*` / `*dictationcore*` so a single brand-new exact pin cannot break the updater. Do not switch away from `exact:` pins.
