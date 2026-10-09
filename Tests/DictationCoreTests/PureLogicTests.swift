import Foundation
import DictationCore
import Testing

struct TranscriptCleanerTests {
    @Test(arguments: [
        ("  Hello world. ", "Hello world."),
        ("[BLANK_AUDIO]", ""),
        ("Hi [Music] there", "Hi there"),
        ("<|en|><|transcribe|> Hej med dig", "Hej med dig"),
        ("line one\nline two\tend", "line one line two end"),
        ("bell\u{07}escape\u{1B}", "bellescape"),
        ("👩‍💻 works", "👩‍💻 works"),
    ])
    func cleans(raw: String, expected: String) {
        #expect(TranscriptCleaner.clean(raw) == expected)
    }
}

struct TextChunkerTests {
    @Test func splitsAtLimit() {
        let chunks = TextChunker.chunks(String(repeating: "a", count: 45))
        #expect(chunks.map(\.count) == [20, 20, 5])
    }

    @Test func neverSplitsGraphemeClusters() {
        let text = String(repeating: "👩‍👩‍👧‍👦", count: 5) // 11 UTF-16 units each
        let chunks = TextChunker.chunks(text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= TextChunker.maxUTF16PerEvent })
        #expect(chunks.allSatisfy { $0.allSatisfy { $0 == "👩‍👩‍👧‍👦" } })
    }

    @Test func emptyTextHasNoChunks() {
        #expect(TextChunker.chunks("").isEmpty)
    }
}

struct ShortcutTests {
    typealias Key = Shortcut.Key

    @Test func defaultIsValidAndReadable() throws {
        try Shortcut.default.validate()
        #expect(Shortcut.default.displayString == "⌃⌥D")
    }

    @Test func displayUsesMacModifierOrder() {
        let shortcut = Shortcut(keys: [
            Key(code: 0x31, label: "Space"), Key(code: KeyCode.rightCommand, label: "⌘"),
            Key(code: KeyCode.leftShift, label: "⇧"), Key(code: KeyCode.leftOption, label: "⌥"),
            Key(code: KeyCode.leftControl, label: "⌃"), Key(code: KeyCode.function, label: "fn"),
        ])
        #expect(shortcut.displayString == "fn⌃⌥⇧⌘Space")
    }

    @Test func modifierOnlyShortcutsNameTheSide() {
        #expect(Shortcut(keys: [Key(code: KeyCode.rightOption, label: "⌥")]).displayString == "Right ⌥")
        #expect(Shortcut(keys: [Key(code: KeyCode.function, label: "fn")]).displayString == "fn")
    }

    @Test func multipleRegularKeysAreJoined() {
        let shortcut = Shortcut(keys: [
            Key(code: 0x01, label: "S"), Key(code: 0x00, label: "A"), Key(code: KeyCode.leftCommand, label: "⌘"),
        ])
        #expect(shortcut.displayString == "⌘A+S")
    }

    @Test(arguments: [
        ([KeyCode.rightOption], Shortcut.PassThroughEffect.harmless),
        ([KeyCode.function], .harmless),
        ([KeyCode.capsLock], .harmless),
        ([0x60], .harmless), // F5
        ([KeyCode.leftShift, 0x6F], .harmless), // ⇧F12
        ([KeyCode.leftControl, KeyCode.leftOption, 0x02], .appShortcut), // ⌃⌥D (default)
        ([KeyCode.rightCommand, 0x31], .appShortcut), // Right ⌘ Space
        ([0x00], .typing), // A
        ([0x31], .typing), // Space
        ([0x35], .typing), // ⎋
        ([KeyCode.leftOption, 0x02], .typing), // ⌥D types ∂
        ([KeyCode.leftShift, 0x7E], .typing), // ⇧↑ selects text
        ([0x00, 0x01], .typing), // A+S
    ] as [([UInt16], Shortcut.PassThroughEffect)])
    func passThroughEffect(codes: [UInt16], expected: Shortcut.PassThroughEffect) {
        let shortcut = Shortcut(keys: codes.map { Key(code: $0, label: "") })
        #expect(shortcut.passThroughEffect == expected)
    }

    @Test func defaultShortcutDoesNotType() {
        #expect(Shortcut.default.passThroughEffect != .typing)
    }

    @Test func anySingleKeyIsValid() throws {
        try Shortcut(keys: [Key(code: 0x60, label: "F5")]).validate()
        try Shortcut(keys: [Key(code: KeyCode.capsLock, label: "⇪")]).validate()
    }

    @Test func emptyIsInvalid() {
        #expect(throws: Shortcut.ValidationError.empty) { try Shortcut(keys: []).validate() }
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(Shortcut.default)
        #expect(try JSONDecoder().decode(Shortcut.self, from: data) == .default)
    }

    @Test func decodesLegacyFormat() throws {
        let legacy = #"{"keyCode":2,"modifiers":3,"keyLabel":"D"}"#
        #expect(try JSONDecoder().decode(Shortcut.self, from: Data(legacy.utf8)) == .default)
    }
}

struct KeyLabelsTests {
    @Test func specialKeysHaveFixedLabels() {
        #expect(KeyLabels.label(forKeyCode: 0x31, typed: " ") == "Space")
        #expect(KeyLabels.label(forKeyCode: 0x7A, typed: nil) == "F1")
        #expect(KeyLabels.label(forKeyCode: KeyCode.rightCommand, typed: nil) == "⌘")
    }

    @Test func regularKeysUseTypedCharacter() {
        #expect(KeyLabels.label(forKeyCode: 0x02, typed: "d") == "D")
        #expect(KeyLabels.label(forKeyCode: 0x99, typed: nil) == "Key 153")
    }
}

struct ChordMatcherTests {
    typealias Key = Shortcut.Key
    static let control: UInt64 = 0x1, rightControl: UInt64 = 0x2000, option: UInt64 = 0x20
    static let rightOption: UInt64 = 0x40, command: UInt64 = 0x8

    func matcher(_ codes: UInt16...) -> ChordMatcher {
        ChordMatcher(Shortcut(keys: codes.map { Key(code: $0, label: "") }))
    }

    @Test func modifiersPlusKeyPressAndRelease() {
        var m = matcher(KeyCode.leftControl, KeyCode.leftOption, 0x02)
        #expect(m.handle(.flagsChanged(KeyCode.leftControl, flags: Self.control)).actions == [])
        #expect(m.handle(.flagsChanged(KeyCode.leftOption, flags: Self.control | Self.option)).actions == [])
        #expect(m.handle(.down(0x02)) == ([.pressed], true))
        #expect(m.handle(.down(0x02)) == ([], true)) // key repeat
        #expect(m.handle(.up(0x02)) == ([.released], true))
    }

    @Test func modifierSideDoesNotMatterWithRegularKey() {
        var m = matcher(KeyCode.leftControl, 0x02)
        _ = m.handle(.flagsChanged(KeyCode.rightControl, flags: Self.rightControl))
        #expect(m.handle(.down(0x02)).actions == [.pressed])
    }

    @Test func extraModifierDoesNotMatchAndKeyPassesThrough() {
        var m = matcher(KeyCode.leftControl, 0x02)
        _ = m.handle(.flagsChanged(KeyCode.leftControl, flags: Self.control))
        _ = m.handle(.flagsChanged(KeyCode.leftCommand, flags: Self.control | Self.command))
        #expect(m.handle(.down(0x02)) == ([], false))
        #expect(m.handle(.up(0x02)) == ([], false))
    }

    @Test func releasingModifierFirstStillSwallowsKeyUp() {
        var m = matcher(KeyCode.leftControl, 0x02)
        _ = m.handle(.flagsChanged(KeyCode.leftControl, flags: Self.control))
        _ = m.handle(.down(0x02))
        #expect(m.handle(.flagsChanged(KeyCode.leftControl, flags: 0)) == ([.released], false))
        #expect(m.handle(.up(0x02)) == ([], true))
    }

    @Test func bareKeyWorks() {
        var m = matcher(0x60) // F5
        #expect(m.handle(.down(0x60)) == ([.pressed], true))
        #expect(m.handle(.up(0x60)) == ([.released], true))
        #expect(m.handle(.down(0x00)) == ([], false))
    }

    @Test func multiKeyChord() {
        var m = matcher(0x00, 0x01)
        #expect(m.handle(.down(0x00)) == ([], false))
        #expect(m.handle(.down(0x01)) == ([.pressed], true))
        #expect(m.handle(.up(0x00)).actions == [.released])
    }

    @Test func modifierOnlyIsSideSpecific() {
        var m = matcher(KeyCode.rightOption)
        #expect(m.handle(.flagsChanged(KeyCode.leftOption, flags: Self.option)).actions == [])
        _ = m.handle(.flagsChanged(KeyCode.leftOption, flags: 0))
        #expect(m.handle(.flagsChanged(KeyCode.rightOption, flags: Self.rightOption)).actions == [.pressed])
        #expect(m.handle(.flagsChanged(KeyCode.rightOption, flags: 0)).actions == [.released])
    }

    @Test func modifierOnlyIsInterruptedByAnotherKey() {
        var m = matcher(KeyCode.leftCommand)
        #expect(m.handle(.flagsChanged(KeyCode.leftCommand, flags: Self.command)).actions == [.pressed])
        #expect(m.handle(.down(0x08)) == ([.interrupted], false)) // ⌘C
    }

    @Test func capsLockActsAsATap() {
        var m = matcher(KeyCode.capsLock)
        #expect(m.handle(.flagsChanged(KeyCode.capsLock, flags: 0x10000)).actions == [.pressed, .released])
        #expect(m.handle(.flagsChanged(KeyCode.capsLock, flags: 0)).actions == [.pressed, .released])
    }

    @Test func flagsRecoverFromMissedModifierRelease() {
        var m = matcher(KeyCode.leftControl, 0x02)
        _ = m.handle(.flagsChanged(KeyCode.leftCommand, flags: Self.command)) // ⌘ release missed
        _ = m.handle(.flagsChanged(KeyCode.leftControl, flags: Self.control))
        #expect(m.handle(.down(0x02)).actions == [.pressed])
    }
}

struct ChordRecorderTests {
    @Test func recordsEverythingHeldUntilAllReleased() {
        var r = ChordRecorder()
        #expect(r.apply(.flagsChanged(KeyCode.leftControl, flags: 0x1)) == nil)
        #expect(r.apply(.down(0x02)) == nil)
        #expect(r.held == [KeyCode.leftControl, 0x02])
        #expect(r.apply(.up(0x02)) == nil)
        #expect(r.apply(.flagsChanged(KeyCode.leftControl, flags: 0)) == [KeyCode.leftControl, 0x02])
        #expect(r.held.isEmpty)
    }

    @Test func recordsCapsLock() {
        var r = ChordRecorder()
        #expect(r.apply(.flagsChanged(KeyCode.capsLock, flags: 0x10000)) == [KeyCode.capsLock])
    }
}
