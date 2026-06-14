import SwiftUI
import AppKit

/// Manages the floating, always-on-top recorder panel shown during countdown
/// and recording. It's a non-activating panel so clicking Stop doesn't pull
/// focus away from whatever the user is recording.
@MainActor
final class OverlayController {

    private var panel: NSPanel?

    func show(appState: AppState) {
        if panel == nil {
            let root = RecordingOverlayView().environmentObject(appState)
            let hosting = NSHostingView(rootView: root)
            hosting.translatesAutoresizingMaskIntoConstraints = true

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 84),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = hosting
            panel.hidesOnDeactivate = false
            self.panel = panel
            positionBottomCenter(panel)
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func positionBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 44
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
