import Foundation

/// One entry of GitHub's `GET /repos/{owner}/{repo}/releases` response (only the fields used).
public struct ReleaseInfo: Decodable, Equatable, Sendable {
    public let tagName: String
    public let htmlURL: String
    public let draft: Bool
    public let prerelease: Bool

    public init(tagName: String, htmlURL: String, draft: Bool = false, prerelease: Bool = false) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.draft = draft
        self.prerelease = prerelease
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft, prerelease
    }
}

/// A newer release the user can download from its release page.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: AppVersion
    public let pageURL: URL
}

/// Pure decisions for the check-and-notify updater. The network request itself lives in the app's
/// `UpdateChecker`; dictation never touches the network.
public enum UpdateCheck {
    public static let interval: TimeInterval = 24 * 60 * 60

    /// The newest release above `current`, or nil if there is none.
    ///
    /// GitHub's `releases/latest` skips pre-releases, so the full list is used instead. Drafts and
    /// tags that aren't versions are ignored. Pre-releases (marked on GitHub or by a `-beta`-style
    /// tag) count while Dictator is below 1.0, where every release is a pre-release, or when the
    /// running version is itself a pre-release; from 1.0 on, stable builds only see stable releases.
    public static func newest(in releases: [ReleaseInfo], current: AppVersion) -> AvailableUpdate? {
        let acceptsPrereleases = current.major < 1 || current.isPrerelease
        return releases
            .compactMap { release -> AvailableUpdate? in
                guard !release.draft,
                      let version = AppVersion(release.tagName),
                      let url = URL(string: release.htmlURL), url.scheme == "https"
                else { return nil }
                if !acceptsPrereleases, release.prerelease || version.isPrerelease { return nil }
                return AvailableUpdate(version: version, pageURL: url)
            }
            .filter { current < $0.version }
            .max { $0.version < $1.version }
    }

    /// Whether the daily automatic check should run now.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A clock set backwards also triggers a check rather than waiting indefinitely.
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck
    }
}
