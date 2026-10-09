import DictationCore
import Testing

struct AppVersionTests {
    @Test func parsesCommonForms() throws {
        let v = try #require(AppVersion("v1.2.3"))
        #expect((v.major, v.minor, v.patch) == (1, 2, 3))
        #expect(AppVersion("0.1")?.description == "0.1.0")
        #expect(AppVersion("0.2.0-beta.1+abc")?.description == "0.2.0-beta.1")
    }

    @Test(arguments: ["", "v", "1.2.3.4", "1..2", "1.x", "1.2.3-", "1.2.3-a..b", "latest"])
    func rejectsGarbage(_ text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func comparesBySemver() throws {
        let ordered = ["0.0.1", "0.1.0-alpha", "0.1.0-alpha.1", "0.1.0-alpha.beta", "0.1.0-beta.2", "0.1.0-beta.11", "0.1.0", "0.1.1", "0.10.0", "1.0.0"]
        let versions = try ordered.map { try #require(AppVersion($0)) }
        for (a, b) in zip(versions, versions.dropFirst()) {
            #expect(a < b, "\(a) < \(b)")
            #expect(!(b < a))
        }
        #expect(AppVersion("v0.1.0") == AppVersion("0.1.0+build.7"))
    }
}

struct ChangelogTests {
    static let markdown = """
        # Changelog

        ## [Unreleased]
        - Not out yet.

        ## [0.2.0] - 2026-11-01
        ### Added
        - Thing two.

        ## [0.1.0] - 2026-10-09
        ### Added
        - Thing one.

        ## 0.0.1
        First build.
        """

    @Test func parsesVersionSections() {
        let entries = Changelog.parse(Self.markdown)
        #expect(entries.map(\.version.description) == ["0.2.0", "0.1.0", "0.0.1"])
        #expect(entries[0].note == "2026-11-01")
        #expect(entries[0].body == "### Added\n- Thing two.")
        #expect(entries[2].note == "")
        #expect(entries[2].body == "First build.")
    }

    static let entries = Changelog.parse(markdown)

    @Test func sameVersionShowsNothing() {
        #expect(WhatsNew.decide(current: AppVersion("0.2.0")!, lastSeen: "0.2.0", changelog: Self.entries) == .none)
    }

    @Test func downgradeShowsNothing() {
        #expect(WhatsNew.decide(current: AppVersion("0.1.0")!, lastSeen: "0.2.0", changelog: Self.entries) == .none)
    }

    @Test func updateShowsEveryVersionSinceLastSeen() {
        let decision = WhatsNew.decide(current: AppVersion("0.2.0")!, lastSeen: "0.0.1", changelog: Self.entries)
        guard case .updated(let shown) = decision else { Issue.record("\(decision)"); return }
        #expect(shown.map(\.version.description) == ["0.2.0", "0.1.0"])
    }

    @Test func freshInstallGetsAWelcomeWithThisVersion() {
        let decision = WhatsNew.decide(current: AppVersion("0.1.0")!, lastSeen: nil, changelog: Self.entries)
        guard case .welcome(let shown) = decision else { Issue.record("\(decision)"); return }
        #expect(shown.map(\.version.description) == ["0.1.0"])
    }

    @Test func unreadableLastSeenShowsThisVersion() {
        let decision = WhatsNew.decide(current: AppVersion("0.2.0")!, lastSeen: "garbage", changelog: Self.entries)
        #expect(decision == .updated([Self.entries[0]]))
    }
}
