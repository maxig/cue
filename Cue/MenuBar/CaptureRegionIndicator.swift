import AppKit

/// A click-through, non-activating overlay that draws a red rounded border
/// around the region Cue is about to capture (a display or a window) — the same
/// "this is what will be recorded" affordance Loom shows. It is purely a preview
/// hint: it appears while the recorder popover is open and during the countdown,
/// and is hidden the moment recording begins so it can never end up in the video.
@MainActor
final class CaptureRegionIndicator {

    private var panel: NSPanel?
    private var view: RegionBorderView?

    /// Shows (or repositions) the indicator over `rect`, given in Cocoa screen
    /// coordinates (bottom-left origin, points).
    func show(rect: NSRect, label: String) {
        guard rect.width > 8, rect.height > 8 else { hide(); return }

        if panel == nil {
            let v = RegionBorderView(frame: NSRect(origin: .zero, size: rect.size))
            let p = NSPanel(
                contentRect: rect,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            p.isFloatingPanel = true
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true          // fully click-through
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .ignoresCycle, .stationary]
            p.contentView = v
            self.panel = p
            self.view = v
        }

        panel?.setFrame(rect, display: true)
        if let view {
            view.frame = NSRect(origin: .zero, size: rect.size)
            view.label = label
            view.needsDisplay = true
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }
}

/// Draws the red border, a soft glow, and a small label pill at the bottom.
private final class RegionBorderView: NSView {

    var label: String = ""

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let red = NSColor.systemRed
        let lineWidth: CGFloat = 3
        let radius: CGFloat = 12
        let rect = bounds.insetBy(dx: lineWidth, dy: lineWidth)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 9, color: red.withAlphaComponent(0.85).cgColor)
        red.setStroke()
        path.stroke()
        ctx.restoreGState()

        drawLabelPill(in: rect)
    }

    private func drawLabelPill(in rect: NSRect) {
        let text = label.isEmpty ? "Cue will record this" : label
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()

        let dot: CGFloat = 7, hPad: CGFloat = 11, vPad: CGFloat = 6, gap: CGFloat = 6
        let pillW = dot + gap + textSize.width + hPad * 2
        let pillH = max(textSize.height, dot) + vPad * 2
        // Bottom-center, inside the bottom border (avoids the menu bar in screen mode).
        let pillRect = NSRect(x: rect.midX - pillW / 2,
                              y: rect.minY + 14,
                              width: pillW, height: pillH)
        guard pillRect.minX >= rect.minX else { return }   // too narrow → skip label

        let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        pill.fill()

        let dotRect = NSRect(x: pillRect.minX + hPad, y: pillRect.midY - dot / 2, width: dot, height: dot)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        str.draw(at: NSPoint(x: dotRect.maxX + gap, y: pillRect.midY - textSize.height / 2))
    }
}
