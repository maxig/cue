import SwiftUI
import AppKit

/// A borderless overlay needs `canBecomeKey` overridden or it never receives
/// keys — Escape and Return would both be dead.
private final class RegionPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Full-screen overlay for choosing which 9:16 slice of a display a vertical
/// recording frames. The rectangle is locked to 9:16 — it is the shape of the
/// finished video, so anything else would have to be cropped again later.
@MainActor
final class ScreenRegionPicker {

    private var panel: RegionPickerPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// What the user chose to do with the area.
    enum Outcome {
        case cancelled
        case saved(ScreenRegion)
        /// Save it and start recording — opening the picker closes the popover,
        /// so without this there is nothing left on screen to press Record in.
        case record(ScreenRegion)
    }

    /// Shows the picker over `screen`, reporting what the user decided.
    func pick(on screen: NSScreen,
              initial: ScreenRegion?,
              completion: @escaping (Outcome) -> Void) {
        close()

        let frame = screen.frame
        let aspect = frame.height > 0 ? frame.width / frame.height : 16.0 / 9.0
        let start = initial ?? .centered(sourceAspect: aspect)

        let panel = RegionPickerPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // The picker is a Cue window, so it is already excluded from capture;
        // this also keeps it out of other apps' recordings and screenshots.
        panel.sharingType = .none

        let view = ScreenRegionPickerView(
            initial: start,
            backingScale: screen.backingScaleFactor,
            onFinish: { [weak self] outcome in
                self?.close()
                completion(outcome)
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrame(frame, display: true)
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The overlay itself: everything outside the rectangle is dimmed, and the
/// rectangle can be dragged around or resized from its corners.
private struct ScreenRegionPickerView: View {
    let initial: ScreenRegion
    let backingScale: CGFloat
    let onFinish: (ScreenRegionPicker.Outcome) -> Void

    /// Live rectangle in view points, top-left origin.
    @State private var rect: CGRect = .zero
    @State private var dragStart: CGRect?
    @State private var isDragging = false

    private static let aspect = 9.0 / 16.0
    private static let minHeight: CGFloat = 160
    /// How close to an edge or the centre counts as "on it". Without this,
    /// landing exactly on the screen bounds by hand is near impossible.
    private static let snap: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                dimming(in: geo.size)
                selection(in: geo.size)
                hud(in: geo.size)
            }
            .contentShape(Rectangle())
            .onAppear {
                if rect == .zero { rect = clamped(denormalize(initial, in: geo.size), in: geo.size) }
            }
            .onKeyPress(.escape) { onFinish(.cancelled); return .handled }
        }
        .ignoresSafeArea()
    }

    // MARK: Pieces

    private func dimming(in size: CGSize) -> some View {
        Color.black.opacity(0.55)
            .mask {
                // Punch the selection out of the dimming layer.
                ZStack {
                    Rectangle().fill(.white)
                    Rectangle()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private func selection(in size: CGSize) -> some View {
        ZStack {
            Rectangle()
                .strokeBorder(.white.opacity(0.95), lineWidth: 2)
                .background(Color.white.opacity(0.001))   // catches the drag
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .cursor(isDragging ? .closedHand : .openHand)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let base = dragStart ?? rect
                            if dragStart == nil { dragStart = rect; isDragging = true }
                            let moved = CGRect(x: base.minX + value.translation.width,
                                               y: base.minY + value.translation.height,
                                               width: base.width, height: base.height)
                            rect = clamped(snapped(moved, in: size), in: size)
                        }
                        .onEnded { _ in dragStart = nil; isDragging = false }
                )

            ForEach(Corner.allCases, id: \.self) { corner in
                handle(corner, in: size)
            }
        }
    }

    private func handle(_ corner: Corner, in size: CGSize) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: 18, height: 18)
            .position(corner.point(in: rect))
            .cursor(corner.cursor)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStart ?? rect
                        if dragStart == nil { dragStart = rect; isDragging = true }
                        let resized = corner.resize(base, by: value.translation,
                                                    aspect: Self.aspect, minHeight: Self.minHeight,
                                                    screen: size, snap: Self.snap)
                        rect = clamped(snapped(resized, in: size), in: size)
                    }
                    .onEnded { _ in dragStart = nil; isDragging = false }
            )
    }

    /// Sits in the middle of the selection, so the controls are always with the
    /// area being chosen rather than adrift somewhere else on the display.
    private func hud(in size: CGSize) -> some View {
        VStack(spacing: 9) {
            Text("Drag to move · corners to resize")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(sizeLabel)
                .font(.system(size: 10.5, weight: .regular).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 8) {
                Button("Cancel") { onFinish(.cancelled) }
                Button("Save Area") { onFinish(.saved(normalize(rect, in: size))) }
                Button("Start Recording") { onFinish(.record(normalize(rect, in: size))) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .fixedSize()
        .position(x: rect.midX, y: rect.midY)
    }

    /// The captured size in real pixels, so it's obvious when a selection is
    /// smaller than the 1080x1920 it will be stretched to.
    private var sizeLabel: String {
        let w = Int((rect.width * backingScale).rounded())
        let h = Int((rect.height * backingScale).rounded())
        return h < 1920 ? "\(w) x \(h) px — smaller than the video" : "\(w) x \(h) px"
    }

    // MARK: Geometry

    private func denormalize(_ region: ScreenRegion, in size: CGSize) -> CGRect {
        region.rect(in: size)
    }

    private func normalize(_ r: CGRect, in size: CGSize) -> ScreenRegion {
        guard size.width > 0, size.height > 0 else { return initial }
        return ScreenRegion(x: r.minX / size.width, y: r.minY / size.height,
                            width: r.width / size.width, height: r.height / size.height)
    }

    /// Pulls the rectangle onto the screen edges and centre lines when it is
    /// already close, without changing its shape.
    private func snapped(_ r: CGRect, in size: CGSize) -> CGRect {
        var out = r
        if abs(out.minX) < Self.snap { out.origin.x = 0 }
        if abs(out.minY) < Self.snap { out.origin.y = 0 }
        if abs(size.width - out.maxX) < Self.snap { out.origin.x = size.width - out.width }
        if abs(size.height - out.maxY) < Self.snap { out.origin.y = size.height - out.height }
        if abs(out.midX - size.width / 2) < Self.snap { out.origin.x = (size.width - out.width) / 2 }
        if abs(out.midY - size.height / 2) < Self.snap { out.origin.y = (size.height - out.height) / 2 }
        return out
    }

    /// Keeps the rectangle on the display without changing its shape.
    private func clamped(_ r: CGRect, in size: CGSize) -> CGRect {
        var out = r
        if out.height > size.height {
            out.size = CGSize(width: size.height * Self.aspect, height: size.height)
        }
        if out.width > size.width {
            out.size = CGSize(width: size.width, height: size.width / Self.aspect)
        }
        out.origin.x = min(max(0, out.minX), max(0, size.width - out.width))
        out.origin.y = min(max(0, out.minY), max(0, size.height - out.height))
        return out
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }

        var cursor: NSCursor {
            switch self {
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            }
        }

        /// Resizes from this corner, keeping the opposite corner pinned and the
        /// rectangle locked to `aspect`. Height drives the shape because the
        /// frame is far taller than it is wide.
        func resize(_ r: CGRect, by t: CGSize, aspect: CGFloat, minHeight: CGFloat,
                    screen: CGSize, snap: CGFloat) -> CGRect {
            let dy: CGFloat
            switch self {
            case .topLeft, .topRight: dy = -t.height
            case .bottomLeft, .bottomRight: dy = t.height
            }
            var height = max(minHeight, r.height + dy)
            // Full screen height is the most useful size there is; make it stick.
            if abs(height - screen.height) < snap { height = screen.height }
            let width = height * aspect

            var x = r.minX
            var y = r.minY
            switch self {
            case .topLeft:
                x = r.maxX - width
                y = r.maxY - height
            case .topRight:
                y = r.maxY - height
            case .bottomLeft:
                x = r.maxX - width
            case .bottomRight:
                break
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
}

/// Swaps the pointer while hovering, so resize handles look like resize handles.
private struct CursorOnHover: ViewModifier {
    let cursor: NSCursor
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View { modifier(CursorOnHover(cursor: cursor)) }
}
