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

    /// Shows the picker over `screen`. `completion` gets the chosen region
    /// normalized to that display, or nil if the user cancelled.
    func pick(on screen: NSScreen,
              initial: ScreenRegion?,
              completion: @escaping (ScreenRegion?) -> Void) {
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
            onConfirm: { [weak self] region in
                self?.close()
                completion(region)
            },
            onCancel: { [weak self] in
                self?.close()
                completion(nil)
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
    let onConfirm: (ScreenRegion) -> Void
    let onCancel: () -> Void

    /// Live rectangle in view points, top-left origin.
    @State private var rect: CGRect = .zero
    @State private var dragStart: CGRect?

    private static let aspect = 9.0 / 16.0
    private static let minHeight: CGFloat = 160

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                dimming(in: geo.size)
                selection
                hud(in: geo.size)
            }
            .contentShape(Rectangle())
            .onAppear { if rect == .zero { rect = denormalize(initial, in: geo.size) } }
            .onKeyPress(.escape) { onCancel(); return .handled }
            .onKeyPress(.return) { confirm(in: geo.size); return .handled }
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
            .onTapGesture { onCancel() }
    }

    private var selection: some View {
        ZStack {
            Rectangle()
                .strokeBorder(.white.opacity(0.95), lineWidth: 2)
                .background(Color.white.opacity(0.001))   // catches the drag
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let base = dragStart ?? rect
                            if dragStart == nil { dragStart = rect }
                            rect = CGRect(x: base.minX + value.translation.width,
                                          y: base.minY + value.translation.height,
                                          width: base.width, height: base.height)
                        }
                        .onEnded { _ in dragStart = nil }
                )

            ForEach(Corner.allCases, id: \.self) { corner in
                handle(corner)
            }
        }
    }

    private func handle(_ corner: Corner) -> some View {
        let point = corner.point(in: rect)
        return Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: 16, height: 16)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStart ?? rect
                        if dragStart == nil { dragStart = rect }
                        rect = corner.resize(base, by: value.translation,
                                             aspect: Self.aspect, minHeight: Self.minHeight)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    private func hud(in size: CGSize) -> some View {
        VStack(spacing: 10) {
            Text("Drag to choose the part of the screen to record")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            Text("This is the 9:16 shape your video will be")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 10) {
                Button("Cancel") { onCancel() }
                Button("Use this area") { confirm(in: size) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        // Sits below the selection when the selection is high, and above when low.
        .position(x: size.width / 2,
                  y: rect.maxY + 90 < size.height ? rect.maxY + 90 : max(110, rect.minY - 90))
    }

    // MARK: Geometry

    private func confirm(in size: CGSize) {
        onConfirm(normalize(clamped(rect, in: size), in: size))
    }

    private func denormalize(_ region: ScreenRegion, in size: CGSize) -> CGRect {
        region.rect(in: size)
    }

    private func normalize(_ r: CGRect, in size: CGSize) -> ScreenRegion {
        guard size.width > 0, size.height > 0 else { return initial }
        return ScreenRegion(x: r.minX / size.width, y: r.minY / size.height,
                            width: r.width / size.width, height: r.height / size.height)
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
        out.origin.x = min(max(0, out.minX), size.width - out.width)
        out.origin.y = min(max(0, out.minY), size.height - out.height)
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

        /// Resizes from this corner, keeping the opposite corner pinned and the
        /// rectangle locked to `aspect`. Height drives the shape because the
        /// frame is far taller than it is wide.
        func resize(_ r: CGRect, by t: CGSize, aspect: CGFloat, minHeight: CGFloat) -> CGRect {
            let dy: CGFloat
            switch self {
            case .topLeft, .topRight: dy = -t.height
            case .bottomLeft, .bottomRight: dy = t.height
            }
            let height = max(minHeight, r.height + dy)
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
