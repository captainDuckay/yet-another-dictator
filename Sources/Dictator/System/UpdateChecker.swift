import DictationCore
import Foundation

/// The app's only network code: asks GitHub's public releases API whether a newer Dictator exists.
///
/// Check and notify only: nothing is downloaded or installed, the user opens the release page in
/// the browser. The request carries no token, cookies or user data (an ephemeral session with a
/// fixed User-Agent), so GitHub sees only the IP address and that a Dictator asked.
struct UpdateChecker: Sendable {
    static let releasesURL = URL(string: "https://api.github.com/repos/captainDuckay/yet-another-dictator/releases?per_page=30")!

    enum Failure: LocalizedError {
        case badResponse(Int)
        var errorDescription: String? {
            switch self {
            case .badResponse(let status): "GitHub answered with status \(status)."
            }
        }
    }

    func newestRelease(above current: AppVersion) async throws -> AvailableUpdate? {
        var request = URLRequest(url: Self.releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Dictator-update-check", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.badResponse(status) }
        let releases = try JSONDecoder().decode([ReleaseInfo].self, from: data)
        return UpdateCheck.newest(in: releases, current: current)
    }
}
