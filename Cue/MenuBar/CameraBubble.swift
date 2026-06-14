import AppKit
import AVFoundation

/// The layer-backed view that renders the live camera with the chosen shape
/// mask, a white rim, and a shape-matched drop shadow.
final class CameraBubbleNSView: NSView {

    private let shadowContainer = CALayer()
    private let maskedContainer = CALayer()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    /// Shows the background-processed camera (cutout / blur / gradient / color)
    /// on top of the raw preview; hidden when the background mode is `off`.
    private let processedLayer = CALayer()

    private let pad: CGFloat = 14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()

        shadowContainer.shadowColor = NSColor.black.cgColor
        shadowContainer.shadowOpacity = 0.4
        shadowContainer.shadowRadius = 12
        shadowContainer.shadowOffset = CGSize(width: 0, height: -3)
        layer?.addSublayer(shadowContainer)

        maskedContainer.masksToBounds = true
        maskedContainer.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        maskedContainer.borderWidth = 3
        maskedContainer.backgroundColor = NSColor.black.cgColor
        shadowContainer.addSublayer(maskedContainer)

        previewLayer.videoGravity = .resizeAspectFill
        maskedContainer.addSublayer(previewLayer)

        processedLayer.contentsGravity = .resizeAspectFill
        processedLayer.masksToBounds = true
        processedLayer.isHidden = true
        maskedContainer.addSublayer(processedLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The capture preview layer; wired to a session by `CameraEngine` on its
    /// session queue (never on the main thread).
    var captureLayer: AVCaptureVideoPreviewLayer { previewLayer }

    /// The layer the engine pushes background-processed frames into.
    var processedContentLayer: CALayer { processedLayer }

    /// Switches between the raw preview and the processed overlay. Transparent
    /// mode clears the backing so the desktop shows through the cutout.
    func setBackgroundMode(_ mode: CameraBackground) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let processed = mode.removesBackground
        processedLayer.isHidden = !processed
        // Opaque modes (blur/gradient/color) keep the raw preview underneath so
        // the bubble still shows something if processed frames don't arrive; the
        // opaque overlay covers it once they do. Transparent must hide it, or the
        // raw background would show through the cutout instead of the screen.
        previewLayer.isHidden = (mode == .transparent)
        maskedContainer.backgroundColor = (mode == .transparent)
            ? NSColor.clear.cgColor : NSColor.black.cgColor
        if !processed { processedLayer.contents = nil }
        CATransaction.commit()
    }

    func apply(shape: CameraBubbleShape, size: CGFloat) {
        let rect = CGRect(x: pad, y: pad, width: size, height: size)
        let radius = shape.cornerRadius(for: size)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowContainer.frame = bounds
        shadowContainer.shadowPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        maskedContainer.frame = rect
        maskedContainer.cornerRadius = radius
        previewLayer.frame = maskedContainer.bounds
        processedLayer.frame = maskedContainer.bounds
        CATransaction.commit()
    }

    var contentInset: CGFloat { pad }
}

/// Manages the floating, draggable, always-on-top camera bubble panel.
@MainActor
final class CameraBubbleController {

    private var panel: NSPanel?
    private var bubbleView: CameraBubbleNSView?

    /// The preview layer for the current bubble (nil if not shown). Passed to
    /// `CameraEngine` to be wired to the session on its queue.
    var previewLayer: AVCaptureVideoPreviewLayer? { bubbleView?.captureLayer }

    /// The layer the engine renders background-processed frames into.
    var processedLayer: CALayer? { bubbleView?.processedContentLayer }

    /// Switches the bubble between raw preview and the processed overlay.
    func setBackgroundMode(_ mode: CameraBackground) {
        bubbleView?.setBackgroundMode(mode)
    }

    func show(shape: CameraBubbleShape, size: CGFloat, corner: CameraCorner = .bottomLeft) {
        let total = size + 28   // room for shadow + rim
        if panel == nil {
            let view = CameraBubbleNSView(frame: NSRect(x: 0, y: 0, width: total, height: total))
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: total, height: total),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = view
            self.panel = panel
            self.bubbleView = view
            position(panel, corner: corner)
        } else if let panel {
            panel.setContentSize(NSSize(width: total, height: total))
            bubbleView?.frame = NSRect(x: 0, y: 0, width: total, height: total)
            position(panel, corner: corner)
        }
        bubbleView?.apply(shape: shape, size: size)
        panel?.orderFrontRegardless()
    }

    func update(shape: CameraBubbleShape, size: CGFloat) {
        guard panel != nil else { return }
        let total = size + 28
        panel?.setContentSize(NSSize(width: total, height: total))
        bubbleView?.frame = NSRect(x: 0, y: 0, width: total, height: total)
        bubbleView?.apply(shape: shape, size: size)
    }

    /// Temporarily hides/shows the bubble without destroying it (keeps the
    /// preview layer wired to the session) — used by the in-recording camera toggle.
    ///
    /// Hides by going fully transparent rather than `orderOut`: an off-screen
    /// window lets macOS suspend its `AVCaptureVideoPreviewLayer`, which then
    /// freezes on the last frame when shown again. Staying composited (alpha 0)
    /// keeps the live preview running, so toggling the camera back on resumes
    /// instantly. Cue's own windows are already excluded from the screen capture,
    /// so a transparent bubble is never baked into the recording.
    func setHidden(_ hidden: Bool) {
        guard let panel else { return }
        panel.ignoresMouseEvents = hidden
        if hidden {
            panel.alphaValue = 0
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        bubbleView = nil
    }

    private func position(_ panel: NSPanel, corner: CameraCorner) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let m: CGFloat = 24
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .bottomLeft:  x = visible.minX + m;                       y = visible.minY + m
        case .bottomRight: x = visible.maxX - size.width - m;          y = visible.minY + m
        case .topLeft:     x = visible.minX + m;                       y = visible.maxY - size.height - m
        case .topRight:    x = visible.maxX - size.width - m;          y = visible.maxY - size.height - m
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
