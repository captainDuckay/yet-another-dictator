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
    @Test func defaultIsValidAndReadable() throws {
        try Shortcut.default.validate()
        #expect(Shortcut.default.displayString == "⌃⌥D")
    }

    @Test func displayUsesMacModifierOrder() {
        let shortcut = Shortcut(keyCode: 0x31, modifiers: [.command, .shift, .option, .control], keyLabel: "Space")
        #expect(shortcut.displayString == "⌃⌥⇧⌘Space")
    }

    @Test(arguments: [Shortcut.Modifiers(), [.option], [.shift], [.option, .shift]])
    func rejectsShortcutsWithoutCommandOrControl(modifiers: Shortcut.Modifiers) {
        let shortcut = Shortcut(keyCode: 0x02, modifiers: modifiers, keyLabel: "D")
        #expect(throws: Shortcut.ValidationError.needsCommandOrControl) { try shortcut.validate() }
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(Shortcut.default)
        #expect(try JSONDecoder().decode(Shortcut.self, from: data) == .default)
    }
}

struct KeyLabelsTests {
    @Test func specialKeysHaveFixedLabels() {
        #expect(KeyLabels.label(forKeyCode: 0x31, typed: " ") == "Space")
        #expect(KeyLabels.label(forKeyCode: 0x7A, typed: nil) == "F1")
    }

    @Test func regularKeysUseTypedCharacter() {
        #expect(KeyLabels.label(forKeyCode: 0x02, typed: "d") == "D")
        #expect(KeyLabels.label(forKeyCode: 0x99, typed: nil) == "Key 153")
    }
}
