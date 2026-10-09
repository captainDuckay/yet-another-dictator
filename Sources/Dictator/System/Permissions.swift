import AppKit
import AVFoundation
import CoreGraphics

/// The two permissions Dictator needs, and nothing else.
@MainActor
enum Permissions {
    enum Status { case granted, denied, notDetermined }

    static var microphone: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Posting synthetic key events (listed under Accessibility in System Settings).
    static var canPostEvents: Bool { CGPreflightPostEventAccess() }

    @discardableResult
    static func requestPostEvents() -> Bool { CGRequestPostEventAccess() }

    static func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
