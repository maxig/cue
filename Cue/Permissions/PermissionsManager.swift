import Foundation
import AVFoundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

/// Tracks and requests the three privacy permissions Cue needs:
/// screen recording, camera, and microphone.
@MainActor
final class PermissionsManager: ObservableObject {

    enum Status: Equatable {
        case notDetermined
        case granted
        case denied

        var isGranted: Bool { self == .granted }
    }

    @Published private(set) var camera: Status = .notDetermined
    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var screenRecording: Status = .notDetermined

    init() { refresh() }

    /// True once screen recording is available — the one permission that's
    /// strictly required before any capture can start.
    var canRecordScreen: Bool { screenRecording == .granted }

    var allGranted: Bool {
        camera == .granted && microphone == .granted && screenRecording == .granted
    }

    func refresh() {
        camera = Self.avStatus(for: .video)
        microphone = Self.avStatus(for: .audio)
        // CGPreflight returns false both when denied and when not-yet-requested;
        // we surface it as `.notDetermined` until the user has clearly denied.
        if CGPreflightScreenCaptureAccess() {
            screenRecording = .granted
        } else if screenRecording != .denied {
            screenRecording = .notDetermined
        }
    }

    /// Authoritative screen-recording check: actually ask ScreenCaptureKit for
    /// content. `CGPreflightScreenCaptureAccess()` can report access while a
    /// stale TCC grant (common right after the app binary changes) returns
    /// nothing — that's indistinguishable from "no permission" to the user, so
    /// we treat it as such and prompt a re-grant + relaunch.
    func verifyScreenRecording() async {
        let working: Bool
        do {
            let content = try await SCShareableContent.current
            working = !content.displays.isEmpty
        } catch {
            working = false
        }
        reflectScreenRecording(working: working)
    }

    /// Updates `screenRecording` from a real capability probe result.
    func reflectScreenRecording(working: Bool) {
        if working {
            screenRecording = .granted
        } else if CGPreflightScreenCaptureAccess() {
            // OS says allowed but capture returns nothing → stale grant.
            screenRecording = .denied
        } else if screenRecording != .denied {
            screenRecording = .notDetermined
        }
    }

    private static func avStatus(for type: AVMediaType) -> Status {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    // MARK: Requests

    func requestCamera() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        camera = granted ? .granted : .denied
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : .denied
    }

    /// Triggers the system screen-recording prompt. macOS grants this on the
    /// next launch, so we also flip our local state to `.denied` if the OS
    /// still reports no access, prompting the user to enable it in Settings.
    func requestScreenRecording() {
        let granted = CGRequestScreenCaptureAccess()
        screenRecording = granted ? .granted : .denied
    }

    // MARK: Deep links into System Settings

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
