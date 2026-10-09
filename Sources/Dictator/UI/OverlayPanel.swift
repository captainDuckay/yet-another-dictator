import AppKit
import DictationCore
import SwiftUI

/// Small floating pill shown while listening/transcribing. Never takes focus or mouse input, so
/// the text field you're dictating into stays focused.
@MainActor
final class OverlayPanel {
    private let panel: NSPanel

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayView(controller: controller))
    }

    func update(for state: DictationState) {
        switch state {
        case .recording, .transcribing:
            if !panel.isVisible { position() }
            panel.orderFrontRegardless()
        case .ready, .loadingModel, .unavailable:
            panel.orderOut(nil)
        }
    }

    /// Bottom-centre of the screen the mouse is on.
    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 48))
    }
}

private struct OverlayView: View {
    let controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            if controller.state == .transcribing {
                ProgressView().controlSize(.small)
                Text("Transcribing")
            } else {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Listening")
                LevelBars(level: controller.level)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: 200, height: 44)
        .background(.black.opacity(0.8), in: Capsule())
    }
}

private struct LevelBars: View {
    let level: Float
    private let weights: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: CGFloat(4 + 16 * min(1, level * weights[index])))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
