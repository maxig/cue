import Foundation
import ScreenCaptureKit
import AppKit

/// What the user is capturing.
enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case screen
    case window
    case cameraOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Screen"
        case .window: return "Window"
        case .cameraOnly: return "Camera"
        }
    }

    var systemImage: String {
        switch self {
        case .screen: return "display"
        case .window: return "macwindow"
        case .cameraOnly: return "web.camera"
        }
    }
}

/// A selectable display, wrapping a `SCDisplay`.
struct DisplayOption: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    let scDisplay: SCDisplay

    static func == (lhs: DisplayOption, rhs: DisplayOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A selectable window, wrapping a `SCWindow`.
struct WindowOption: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String
    let scWindow: SCWindow
    /// A small live preview of the window, filled in asynchronously.
    var thumbnail: NSImage?

    var displayName: String {
        if title.isEmpty { return appName }
        return "\(appName) — \(title)"
    }

    static func == (lhs: WindowOption, rhs: WindowOption) -> Bool {
        lhs.id == rhs.id && (lhs.thumbnail == nil) == (rhs.thumbnail == nil)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A selectable AV capture device (camera or microphone).
struct DeviceOption: Identifiable, Hashable {
    let id: String        // AVCaptureDevice.uniqueID
    let name: String

    /// Sentinel for "no device" (e.g. "No Camera" / "No Audio").
    static func none(_ label: String) -> DeviceOption { DeviceOption(id: "__none__", name: label) }
    var isNone: Bool { id == "__none__" }
}

/// The user's current capture configuration, surfaced in the popover.
struct CaptureConfiguration {
    var mode: CaptureMode = .screen
    var display: DisplayOption?
    var window: WindowOption?
    var camera: DeviceOption?
    var microphone: DeviceOption?
    var cameraEnabled: Bool = true
    var microphoneEnabled: Bool = true
    var captureSystemAudio: Bool = true
    var countdownSeconds: Int = 3
}
