import Foundation
import AppKit
import QuartzCore

/// Captures the pointer path + clicks during a *display* recording so the
/// composer can later add cinematic effects (smooth cursor, click ripples,
/// zoom-on-click). Timestamps are host-clock (`CACurrentMediaTime`) and
/// positions are global screen points; `finish` converts them to the content
/// timeline (lead-in trimmed, pauses excised) and normalizes them to the
/// captured display, matching the compositor's frame time and coordinate space.
@MainActor
final class MouseActivityRecorder {

    private struct RawEvent {
        let t: CFTimeInterval
        let point: CGPoint
        let isClick: Bool
    }

    private var events: [RawEvent] = []
    private var monitors: [Any] = []
    private var lastMoveT: CFTimeInterval = 0
    /// Throttle pointer-move sampling (clicks are never throttled).
    private let moveInterval: CFTimeInterval = 1.0 / 30.0

    /// Largest pointer-move sample count we keep, to bound the sidecar file.
    private let maxMoves = 6000

    /// Begins observing global mouse moves + clicks. No-op if already running.
    /// Global monitors observe events while *other* apps are focused (i.e. while
    /// the user is recording their screen) and need no accessibility grant for
    /// mouse events.
    @discardableResult
    func start() -> Bool {
        guard monitors.isEmpty else { return true }
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let clickMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            self?.record(isClick: false)
        }) { monitors.append(m) }
        if let c = NSEvent.addGlobalMonitorForEvents(matching: clickMask, handler: { [weak self] _ in
            self?.record(isClick: true)
        }) { monitors.append(c) }
        return !monitors.isEmpty
    }

    /// Seeds the content timeline with the cursor's current position so a custom
    /// smoothed cursor is visible even before the user first moves the mouse.
    func markContentStart() {
        guard !monitors.isEmpty else { return }
        let now = CACurrentMediaTime()
        events.append(RawEvent(t: now, point: NSEvent.mouseLocation, isClick: false))
        lastMoveT = now
    }

    private func record(isClick: Bool) {
        let now = CACurrentMediaTime()
        if !isClick {
            guard now - lastMoveT >= moveInterval else { return }
            lastMoveT = now
        }
        events.append(RawEvent(t: now, point: NSEvent.mouseLocation, isClick: isClick))
    }

    /// Stops observing and discards everything (recording cancelled).
    func cancel() {
        removeMonitors()
        events.removeAll()
    }

    /// Stops observing and returns the captured activity converted to the content
    /// timeline + normalized to `displayFrame` (in the global, bottom-left-origin
    /// point space that `NSEvent.mouseLocation` uses). Returns nil if nothing
    /// usable was captured.
    func finish(contentStartAnchor: CFTimeInterval?,
                pauseSpansHost: [(start: CFTimeInterval, end: CFTimeInterval)],
                displayFrame: CGRect) -> MouseActivity? {
        removeMonitors()
        defer { events.removeAll() }

        guard let start = contentStartAnchor,
              displayFrame.width > 0, displayFrame.height > 0 else { return nil }

        let spans = pauseSpansHost.filter { $0.end > $0.start }.sorted { $0.start < $1.start }

        // Host time → content seconds: drop the countdown lead-in and any event
        // landing inside a pause, and subtract paused time that elapsed before it.
        func contentSeconds(_ h: CFTimeInterval) -> Double? {
            if h < start { return nil }
            var paused = 0.0
            for s in spans {
                if h >= s.start, h <= s.end { return nil }
                if s.end < h { paused += s.end - s.start }
            }
            return (h - start) - paused
        }

        // Global point (bottom-left origin) → display-normalized (top-left origin).
        func normalized(_ p: CGPoint) -> CGPoint? {
            let rx = (p.x - displayFrame.minX) / displayFrame.width
            let ry = 1 - (p.y - displayFrame.minY) / displayFrame.height   // flip Y
            guard rx >= 0, rx <= 1, ry >= 0, ry <= 1 else { return nil }    // off this display
            return CGPoint(x: rx, y: ry)
        }

        var moves: [MouseSample] = []
        var clicks: [MouseSample] = []
        for e in events {
            guard let t = contentSeconds(e.t), let n = normalized(e.point) else { continue }
            let sample = MouseSample(t: t, x: Double(n.x), y: Double(n.y))
            if e.isClick { clicks.append(sample) } else { moves.append(sample) }
        }

        if moves.count > maxMoves {
            let stride = Int((Double(moves.count) / Double(maxMoves)).rounded(.up))
            moves = moves.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
        }

        let activity = MouseActivity(moves: moves, clicks: clicks)
        return activity.isEmpty ? nil : activity
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }
}
