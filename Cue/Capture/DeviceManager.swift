import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreAudio

/// Enumerates the capture sources shown in the popover pickers:
/// cameras, microphones, displays, and windows.
@MainActor
final class DeviceManager: ObservableObject {

    @Published private(set) var cameras: [DeviceOption] = []
    @Published private(set) var microphones: [DeviceOption] = []
    @Published private(set) var displays: [DisplayOption] = []
    @Published private(set) var windows: [WindowOption] = []

    // MARK: AV devices (camera / mic)

    func refreshAVDevices() {
        let cameraTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .external, .continuityCamera
        ]
        let cameraSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: cameraTypes, mediaType: .video, position: .unspecified
        )
        cameras = Self.options(from: cameraSession.devices)

        let micSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        )
        microphones = Self.options(from: micSession.devices)
    }

    /// Maps devices to options, ordering physical devices first: built-in,
    /// then real external (USB/Bluetooth/Continuity), then virtual/aggregate
    /// devices last (e.g. "Microsoft Teams Audio", "BlackHole", "OBS Camera").
    private static func options(from devices: [AVCaptureDevice]) -> [DeviceOption] {
        devices
            .sorted { lhs, rhs in
                let l = transportRank(lhs), r = transportRank(rhs)
                if l != r { return l < r }
                return lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
            }
            .map { DeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Processes whose (rare) layer-0 windows we never want to offer as capture
    /// targets, even if they slip past the window-layer filter. Finder is here
    /// because its only enumerated "window" is usually the desktop, which
    /// ScreenCaptureKit returns blank — never a useful recording target.
    private static func isSystemApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        let blocked: Set<String> = [
            "com.apple.dock",
            "com.apple.controlcenter",
            "com.apple.WindowManager",
            "com.apple.notificationcenterui",
            "com.apple.systemuiserver",
            "com.apple.wallpaper.agent",
            "com.apple.screencaptureui",
            "com.apple.Spotlight",
            "com.apple.coreservices.uiagent",
            "com.apple.finder"
        ]
        return blocked.contains(id)
    }

    private static func transportRank(_ device: AVCaptureDevice) -> Int {
        switch UInt32(bitPattern: device.transportType) {
        case kAudioDeviceTransportTypeBuiltIn:
            return 0
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            return 2
        default:
            return 1
        }
    }

    func device(withID id: String, mediaType: AVMediaType) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: id)
    }

    // MARK: Screen content (displays / windows)

    /// Refreshes displays + windows. Returns `true` if ScreenCaptureKit actually
    /// returned content — `false` means screen recording isn't truly working
    /// (either never granted, or a stale TCC grant that needs a relaunch), which
    /// the caller uses to drive the permission gate.
    @discardableResult
    func refreshScreenContent() async -> Bool {
        do {
            let content = try await SCShareableContent.current
            let main = CGMainDisplayID()
            displays = content.displays.enumerated().map { index, display in
                let name = display.displayID == main ? "Main Display" : "Display \(index + 1)"
                return DisplayOption(
                    id: display.displayID,
                    name: "\(name) · \(display.width)×\(display.height)",
                    width: display.width,
                    height: display.height,
                    scDisplay: display
                )
            }

            let ownBundleID = Bundle.main.bundleIdentifier
            var appsResolved = 0

            windows = content.windows.compactMap { window -> WindowOption? in
                let app = window.owningApplication
                if app != nil { appsResolved += 1 }
                // Normal app windows on the CURRENT Space only. `isOnScreen` is
                // false for minimized windows and windows on other Spaces;
                // `windowLayer == 0` excludes the Dock, wallpaper, Control Center
                // overlays, the desktop, menu-bar extras, tooltips, etc.
                guard window.isOnScreen, window.windowLayer == 0 else { return nil }
                guard let app else { return nil }
                if app.bundleIdentifier == ownBundleID { return nil }
                if Self.isSystemApp(app.bundleIdentifier) { return nil }
                guard window.frame.width >= 80, window.frame.height >= 60 else { return nil }
                let title = window.title ?? ""
                let appName = app.applicationName
                if title.isEmpty && appName.isEmpty { return nil }
                return WindowOption(
                    id: window.windowID,
                    title: title,
                    appName: appName.isEmpty ? "Window" : appName,
                    scWindow: window
                )
            }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }

            // Fill in window thumbnails in the background (Loom-style previews).
            Task { await loadWindowThumbnails() }

            // Screen recording truly works only if windows resolve their owning
            // app — displays enumerate even without the grant, so they're not a
            // reliable signal.
            return appsResolved > 0 || (content.windows.isEmpty && !content.displays.isEmpty)
        } catch {
            // Most commonly: screen-recording permission not granted (or stale).
            NSLog("Cue: SCShareableContent failed — \(error.localizedDescription)")
            displays = []
            windows = []
            return false
        }
    }

    /// Captures a small still of each window so the picker can show previews.
    private func loadWindowThumbnails() async {
        // Cap the number we snapshot to keep this light.
        let targets = Array(windows.prefix(24))
        for option in targets {
            if let image = await Self.captureThumbnail(for: option.scWindow),
               let index = windows.firstIndex(where: { $0.id == option.id }) {
                windows[index].thumbnail = image
            }
        }
    }

    private static func captureThumbnail(for window: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let maxWidth = 480.0
        let w = max(1.0, min(window.frame.width, maxWidth))
        let scale = w / max(window.frame.width, 1)
        config.width = Int(w)
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        do {
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }
}
