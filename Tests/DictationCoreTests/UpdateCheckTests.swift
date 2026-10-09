import DictationCore
import Foundation
import Testing

struct UpdateCheckTests {
    static func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> ReleaseInfo {
        ReleaseInfo(tagName: tag, htmlURL: "https://github.com/o/r/releases/tag/\(tag)", draft: draft, prerelease: prerelease)
    }

    @Test func decodesGitHubReleasesJSON() throws {
        let json = """
            [{"tag_name": "v0.2.0", "html_url": "https://github.com/o/r/releases/tag/v0.2.0",
              "draft": false, "prerelease": true, "name": "v0.2.0", "assets": []}]
            """
        let releases = try JSONDecoder().decode([ReleaseInfo].self, from: Data(json.utf8))
        #expect(releases == [Self.release("v0.2.0", prerelease: true)])
    }

    @Test func picksTheNewestHigherVersion() {
        let update = UpdateCheck.newest(
            in: [Self.release("v0.1.0"), Self.release("v0.3.0"), Self.release("v0.2.5"), Self.release("nightly")],
            current: AppVersion("0.1.0")!
        )
        #expect(update?.version.description == "0.3.0")
        #expect(update?.pageURL.absoluteString == "https://github.com/o/r/releases/tag/v0.3.0")
    }

    @Test func nothingWhenUpToDateOrAhead() {
        let releases = [Self.release("v0.1.0"), Self.release("v0.0.1")]
        #expect(UpdateCheck.newest(in: releases, current: AppVersion("0.1.0")!) == nil)
        #expect(UpdateCheck.newest(in: releases, current: AppVersion("0.2.0")!) == nil)
        #expect(UpdateCheck.newest(in: [], current: AppVersion("0.1.0")!) == nil)
    }

    @Test func ignoresDrafts() {
        let releases = [Self.release("v0.9.0", draft: true), Self.release("v0.2.0")]
        #expect(UpdateCheck.newest(in: releases, current: AppVersion("0.1.0")!)?.version.description == "0.2.0")
    }

    @Test func belowOnePointOhGitHubPrereleasesCount() {
        let releases = [Self.release("v0.2.0", prerelease: true)]
        #expect(UpdateCheck.newest(in: releases, current: AppVersion("0.1.0")!)?.version.description == "0.2.0")
    }

    @Test func stableBuildsFromOnePointOhSkipPrereleases() {
        let releases = [
            Self.release("v1.1.0", prerelease: true), Self.release("v1.2.0-beta.1"), Self.release("v1.0.1"),
        ]
        #expect(UpdateCheck.newest(in: releases, current: AppVersion("1.0.0")!)?.version.description == "1.0.1")
        #expect(UpdateCheck.newest(in: releases, current: AppVersion("1.1.0-beta.1")!)?.version.description == "1.2.0-beta.1")
    }

    @Test func aReleaseBeatsItsOwnPrerelease() {
        let releases = [Self.release("v0.2.0")]
        #expect(UpdateCheck.newest(in: releases, current: AppVersion("0.2.0-beta.3")!)?.version.description == "0.2.0")
    }

    @Test func rejectsNonHTTPSPages() {
        let releases = [ReleaseInfo(tagName: "v9.0.0", htmlURL: "http://example.com/x")]
        #expect(UpdateCheck.newest(in: releases, current: AppVersion("0.1.0")!) == nil)
    }

    @Test func checksDaily() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateCheck.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(3600), now: now)) // clock went back
    }
}
