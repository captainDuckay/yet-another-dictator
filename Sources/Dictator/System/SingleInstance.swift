import AppKit

/// Keeps Dictator to one running copy. Two copies would each install a keyboard tap, so every
/// shortcut press would start two recordings and the text would be typed twice.
@MainActor
enum SingleInstance {
    private static let relaunchKey = "relaunchRequestedAt"
    /// How long a relaunch marker stays valid, and how long the new copy waits for the old one.
    private static let relaunchWindow: TimeInterval = 15
    private static let relaunchWait: Duration = .seconds(5)

    /// Call just before relaunching: the new copy then waits for this one to quit instead of
    /// giving way to it. (Launch arguments don't reach a sandboxed relaunch, so defaults carry it.)
    static func markRelaunch() {
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: relaunchKey)
    }

    /// Returns true if this process should keep running, false if an earlier copy owns the role.
    static func claim() async -> Bool {
        let relaunching = consumeRelaunchMarker()
        let deadline = ContinuousClock.now + (relaunching ? relaunchWait : .zero)
        while true {
            if earlierCopies().isEmpty { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Other running copies that launched before this one (ties broken by PID), so two copies
    /// started at the same moment don't both quit.
    private static func earlierCopies() -> [NSRunningApplication] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        let me = NSRunningApplication.current
        let myLaunch = me.launchDate ?? .now
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { other in
            guard other.processIdentifier != me.processIdentifier, !other.isTerminated else { return false }
            let theirLaunch = other.launchDate ?? .distantPast
            return theirLaunch < myLaunch
                || (theirLaunch == myLaunch && other.processIdentifier < me.processIdentifier)
        }
    }

    private static func consumeRelaunchMarker() -> Bool {
        let defaults = UserDefaults.standard
        let markedAt = defaults.double(forKey: relaunchKey)
        defaults.removeObject(forKey: relaunchKey)
        return markedAt > 0 && Date.now.timeIntervalSince1970 - markedAt < relaunchWindow
    }
}
