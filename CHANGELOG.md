# Changelog

All notable changes to Dictator. The newest version is shown in the app's What's New window.

## [Unreleased]

## [0.1.2] - 2026-10-10

### Fixed
- After updating from 0.1.0, Input Monitoring and Accessibility could stay "not granted" even though they were switched on in System Settings. That switch belonged to the old unsigned build. Settings now explains this and opens the right page: remove Dictator from the list with −, then click Grant… again. From 0.1.1 on, updates keep these permissions.

## [0.1.1] - 2026-10-10

Signed and notarized.

### Changed
- Dictator is now signed with an Apple Developer ID and notarized by Apple. It opens without the "Open Anyway" step, and macOS keeps its Microphone, Input Monitoring and Accessibility permissions when you update. If you're coming from 0.1.0, grant them once more.
- Cancel Dictation now also stops typing a long dictation part-way. The part already typed stays, but it isn't offered for Undo.
- The dictation core now comes from the shared [DictationCore](https://github.com/captains-chest/DictationCore) package, so a future iOS app can use the same code. The app behaves the same.
- The app bundle includes its license and third-party notices.

### Fixed
- A recording that reaches the 10-minute limit now stops and is typed, with a short notice, instead of silently dropping everything said after 10 minutes.

## [0.1.0] - 2026-10-09

### Added
- Undo Last Dictation: from the menu, or with an optional shortcut set in Settings. Removes exactly what was just typed, as long as you haven't typed or clicked since.
- Smart spacing and capitals: dictations continue the sentence with the right space and capitalisation.
- Update check: once a day Dictator asks GitHub whether a newer version exists and offers the download page. Nothing is downloaded automatically, and you can turn it off in Settings.
- What's New window, shown once after an update; reopen it from the menu.
- Choose the dictation language: Automatic, Dansk or English.
- Open at login.
- Keep microphone ready (optional): catches the first word if you start speaking as you press the shortcut.
- Settings shows when the shortcut's keys also reach the app you're typing in.
- Any key or key combination can be the shortcut, shown on a keyboard.

### Improved
- Sentences end with proper punctuation, and the last word is no longer cut off.
- Faster first dictation: the model is warmed up at launch.
- Starting a dictation never blocks the keyboard or the app; the microphone follows headset and input changes.
- Silence and very quiet recordings are no longer turned into made-up text.

### Fixed
- Transcription can be cancelled and stops itself if it takes far too long.
- Dictator checks it may type before you speak, and keeps text it couldn't type in the menu so you can type it again.
- Only one copy of Dictator runs at a time.
- Granting Accessibility now prompts a relaunch so it takes effect.

## [0.0.1] - 2026-10-09

First build: hold or tap a shortcut, speak, and the text is typed where your cursor is. Runs entirely on your Mac with a bundled Whisper model.
