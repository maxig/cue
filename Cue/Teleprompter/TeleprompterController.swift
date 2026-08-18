import SwiftUI
import AppKit

/// A borderless `NSPanel` reports `canBecomeKey == false`, which leaves any text
/// field inside it unable to take keyboard focus — you can click into the script
/// but not type. Overriding it is the only way to get a borderless panel that
/// accepts typing. `canBecomeMain` stays false so Cue never steals main-window
/// status from the app being recorded.
private final class ScriptPanel: NSPanel {
    /// Off while prompting, so reading a script back never intercepts the
    /// keystrokes meant for whatever is being recorded.
    var acceptsKeyboard = true
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// The floating script panel. It sits beside whatever you're recording so you
/// can read from it, and never appears in the video: Cue's own windows are all
/// excluded from screen capture (`SCContentFilter(display:excludingApplications:)`
/// in `RecordingEngine`), and window capture isolates a single other window.
/// `sharingType = .none` is belt and braces on top of that.
///
/// Unlike the capture-region hint this panel must stay clickable — the whole
/// point is scrolling and pacing your script while you talk.
@MainActor
final class TeleprompterController: ObservableObject {

    enum Mode {
        /// Writing or pasting the script, before recording starts.
        case editing
        /// Reading it back during a recording.
        case prompting
    }

    @Published var mode: Mode = .editing
    /// Whether auto-scroll is currently running, so the view and the panel's
    /// controls agree about it.
    @Published var isScrolling = false

    private var panel: ScriptPanel?
    var isVisible: Bool { panel?.isVisible ?? false }

    func show(appState: AppState, mode: Mode) {
        self.mode = mode
        if mode == .editing { isScrolling = false }

        if panel == nil {
            let root = TeleprompterView()
                .environmentObject(appState)
                .environmentObject(appState.preferences)
                .environmentObject(self)
            let hosting = NSHostingView(rootView: root)
            hosting.translatesAutoresizingMaskIntoConstraints = true

            let panel = ScriptPanel(
                contentRect: Self.defaultFrame(),
                styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            // Keep the script out of any capture, including other apps' and the
            // system's own screenshots.
            panel.sharingType = .none
            panel.contentView = hosting
            panel.setFrameAutosaveName("CueTeleprompter")
            self.panel = panel
        }
        panel?.orderFrontRegardless()
        applyKeyboardPolicy()
    }

    /// Switches modes without disturbing the panel's position, used when the
    /// countdown ends and the script becomes something to read rather than edit.
    func setMode(_ mode: Mode, autoScroll: Bool) {
        self.mode = mode
        isScrolling = mode == .prompting && autoScroll
        applyKeyboardPolicy()
    }

    /// The panel only takes the keyboard while the script is being written.
    /// `.nonactivatingPanel` means it can do that without pulling focus away
    /// from the app in front, which is why it can be typed into from anywhere.
    private func applyKeyboardPolicy() {
        guard let panel else { return }
        let editing = mode == .editing
        panel.acceptsKeyboard = editing
        if editing {
            panel.makeKeyAndOrderFront(nil)
        } else if panel.isKeyWindow {
            // Hand the keyboard back to whatever is being recorded.
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        isScrolling = false
    }

    /// A tall, narrow column down the right-hand side, out of the way of most
    /// content but wide enough to read a sentence at a glance.
    private static func defaultFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: 360, height: 460)
        }
        let visible = screen.visibleFrame
        let width: CGFloat = 360
        let height = max(320, visible.height * 0.46)
        return NSRect(x: visible.maxX - width - 32,
                      y: visible.midY - height / 2,
                      width: width, height: height)
    }
}
