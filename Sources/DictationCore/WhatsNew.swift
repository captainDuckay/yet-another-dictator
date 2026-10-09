import Foundation

/// One version's section of CHANGELOG.md.
public struct ChangelogEntry: Equatable, Sendable {
    public let version: AppVersion
    /// The heading's remainder, e.g. the date ("2026-10-09"); may be empty.
    public let note: String
    /// The section's Markdown, without its heading.
    public let body: String
}

public enum Changelog {
    /// Parses `## [0.1.0] - 2026-10-09` / `## 0.1.0` sections, newest first as written.
    /// Sections whose heading isn't a version (e.g. "Unreleased") are skipped.
    public static func parse(_ markdown: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var current: (version: AppVersion, note: String)?
        var lines: [Substring] = []

        func flush() {
            if let current {
                let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(ChangelogEntry(version: current.version, note: current.note, body: body))
            }
            lines = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                current = heading(line.dropFirst(3))
            } else if current != nil {
                lines.append(line)
            }
        }
        flush()
        return entries
    }

    private static func heading(_ text: Substring) -> (AppVersion, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let token = trimmed.prefix { !$0.isWhitespace }
        let versionText = token.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let version = AppVersion(versionText) else { return nil }
        let note = trimmed.dropFirst(token.count).trimmingCharacters(in: CharacterSet(charactersIn: " -–—"))
        return (version, note)
    }
}

/// Decides whether to show the What's New window at launch.
public enum WhatsNew {
    public enum Decision: Equatable, Sendable {
        /// Nothing to show (same version as last time, or a downgrade).
        case none
        /// First launch ever (nothing seen before): a welcome with the current version's notes.
        case welcome([ChangelogEntry])
        /// Updated: the notes of every version after the last one seen, up to this one.
        case updated([ChangelogEntry])
    }

    public static func decide(current: AppVersion, lastSeen: String?, changelog: [ChangelogEntry]) -> Decision {
        guard let lastSeen else {
            return .welcome(changelog.filter { $0.version == current })
        }
        guard let seen = AppVersion(lastSeen) else {
            // Unreadable stored value: treat as an update, showing this version's notes.
            return .updated(changelog.filter { $0.version == current })
        }
        guard seen < current else { return .none }
        let entries = changelog
            .filter { seen < $0.version && $0.version <= current }
            .sorted { $0.version > $1.version }
        return .updated(entries)
    }
}
