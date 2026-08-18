import Foundation
import SwiftUI

/// Shape of the live camera bubble (and the baked picture-in-picture).
enum CameraBubbleShape: String, CaseIterable, Identifiable, Codable {
    case circle
    case roundedSquare
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle: return "Circle"
        case .roundedSquare: return "Rounded"
        case .square: return "Square"
        }
    }

    var systemImage: String {
        switch self {
        case .circle: return "circle"
        case .roundedSquare: return "app.dashed"
        case .square: return "square"
        }
    }

    /// Corner radius for a bubble of side length `size`.
    func cornerRadius(for size: CGFloat) -> CGFloat {
        switch self {
        case .circle: return size / 2
        case .roundedSquare: return size * 0.24
        case .square: return 0
        }
    }
}

/// Which corner the camera bubble / PiP sits in.
enum CameraCorner: String, CaseIterable, Identifiable, Codable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        }
    }
}

/// Treatment for the camera's own background inside the bubble — applied live
/// and baked into the final. `none` keeps your real background; the others
/// segment you out and replace what's behind you.
enum CameraBackground: String, CaseIterable, Identifiable, Codable {
    case none, transparent, blur, gradient, color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Off"
        case .transparent: return "Transparent"
        case .blur: return "Blur"
        case .gradient: return "Gradient"
        case .color: return "Color"
        }
    }

    /// Whether this mode needs person segmentation (everything but `none`).
    var removesBackground: Bool { self != .none }
}

/// Canvas background applied behind a padded screen recording (Cap/Screen
/// Studio style). `none` keeps the screen full-bleed with no padding.
enum CanvasBackground: String, CaseIterable, Identifiable, Codable {
    case none, graphite, midnight, ocean, sunset, lavender, mint, snow
    case auroraVeil, desertGlass, mossStudio, lunarMesh
    var id: String { rawValue }
    var isVisible: Bool { self != .none }
    var isArtwork: Bool { assetName != nil }
    var title: String {
        switch self {
        case .none: return "None"
        case .graphite: return "Graphite"
        case .midnight: return "Midnight"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .lavender: return "Lavender"
        case .mint: return "Mint"
        case .snow: return "Snow"
        case .auroraVeil: return "Aurora Veil"
        case .desertGlass: return "Desert Glass"
        case .mossStudio: return "Moss Studio"
        case .lunarMesh: return "Lunar Mesh"
        }
    }

    /// Asset-catalog name for artwork backgrounds. Gradient presets return nil.
    var assetName: String? {
        switch self {
        case .auroraVeil: return "CanvasAurora"
        case .desertGlass: return "CanvasDesertGlass"
        case .mossStudio: return "CanvasMossStudio"
        case .lunarMesh: return "CanvasLunarMesh"
        default: return nil
        }
    }

    /// Gradient stops as sRGB (top, bottom). Nil for `.none` and artwork.
    var gradient: (top: (Double, Double, Double), bottom: (Double, Double, Double))? {
        switch self {
        case .none, .auroraVeil, .desertGlass, .mossStudio, .lunarMesh: return nil
        case .graphite: return ((0.18, 0.19, 0.22), (0.08, 0.08, 0.10))
        case .midnight: return ((0.16, 0.18, 0.42), (0.05, 0.05, 0.16))
        case .ocean: return ((0.16, 0.55, 0.86), (0.05, 0.22, 0.45))
        case .sunset: return ((0.98, 0.58, 0.35), (0.83, 0.27, 0.46))
        case .lavender: return ((0.62, 0.56, 0.93), (0.39, 0.34, 0.78))
        case .mint: return ((0.40, 0.85, 0.70), (0.16, 0.55, 0.51))
        case .snow: return ((0.95, 0.96, 0.98), (0.82, 0.85, 0.90))
        }
    }
}

/// Output aspect ratio for recordings.
enum AspectRatioMode: String, CaseIterable, Identifiable, Codable {
    case sixteenNine
    case native

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sixteenNine: return "16:9"
        case .native: return "Follow screen"
        }
    }
    /// Target width/height, or nil to follow the captured source's own ratio.
    var ratio: CGFloat? {
        switch self {
        case .sixteenNine: return 16.0 / 9.0
        case .native: return nil
        }
    }
}

/// Lightweight, UserDefaults-backed app preferences.
@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard
    private enum Key {
        static let bubbleShape = "cue.camera.bubbleShape"
        static let bubbleSize = "cue.camera.bubbleSize"
        static let showBubble = "cue.camera.showBubble"
        static let mirrored = "cue.camera.mirrored"
        static let cameraBackground = "cue.camera.bgMode"
        static let centerStage = "cue.camera.centerStage"
        static let cameraCorner = "cue.camera.corner"
        static let screenPadding = "cue.canvas.padding"
        static let background = "cue.canvas.background"
        static let onboardingDone = "cue.onboarding.done"
        static let lastCameraID = "cue.device.lastCameraID"
        static let lastMicID = "cue.device.lastMicID"
        static let lastMode = "cue.capture.lastMode"
        static let aspectMode = "cue.canvas.aspectMode"
        static let captureFPS = "cue.capture.fps"
        static let cinematicEffects = "cue.capture.cinematicEffects"
        static let creativeEnabled = "cue.creative.enabled"
        static let creativeLayout = "cue.creative.layout"
        static let scriptDraft = "cue.creative.scriptDraft"
        static let screenRegion = "cue.creative.screenRegion"
        static let captionsEnabled = "cue.captions.enabled"
        static let captionStyle = "cue.captions.style"
        static let captionLocale = "cue.captions.locale"
        static let teleprompterFontSize = "cue.teleprompter.fontSize"
        static let teleprompterAutoScroll = "cue.teleprompter.autoScroll"
        static let teleprompterSpeed = "cue.teleprompter.speed"
    }

    @Published var cameraBubbleShape: CameraBubbleShape {
        didSet { defaults.set(cameraBubbleShape.rawValue, forKey: Key.bubbleShape) }
    }
    @Published var cameraBubbleSize: Double {
        didSet { defaults.set(cameraBubbleSize, forKey: Key.bubbleSize) }
    }
    @Published var showCameraBubble: Bool {
        didSet { defaults.set(showCameraBubble, forKey: Key.showBubble) }
    }
    /// Whether the camera is shown/recorded mirrored (selfie-style). Default is
    /// natural (un-mirrored).
    @Published var cameraMirrored: Bool {
        didSet { defaults.set(cameraMirrored, forKey: Key.mirrored) }
    }
    /// How the camera's background is treated in the bubble (off / transparent /
    /// blur / gradient / color) — applied live and baked into the final.
    @Published var cameraBackground: CameraBackground {
        didSet { defaults.set(cameraBackground.rawValue, forKey: Key.cameraBackground) }
    }
    /// Whether Center Stage auto-framing is enabled (when the camera supports it).
    @Published var centerStageEnabled: Bool {
        didSet { defaults.set(centerStageEnabled, forKey: Key.centerStage) }
    }
    /// Which corner the camera sits in (live bubble + baked PiP).
    @Published var cameraCorner: CameraCorner {
        didSet { defaults.set(cameraCorner.rawValue, forKey: Key.cameraCorner) }
    }
    /// Padding around the screen recording as a fraction of width (0…0.18).
    /// Only takes effect when a canvas background is selected.
    @Published var screenPadding: Double {
        didSet { defaults.set(screenPadding, forKey: Key.screenPadding) }
    }
    /// Canvas background behind the padded screen.
    @Published var canvasBackground: CanvasBackground {
        didSet { defaults.set(canvasBackground.rawValue, forKey: Key.background) }
    }
    /// Output aspect ratio. Defaults to 16:9 so clips never letterbox in players;
    /// non-matching screens are fit onto a gradient canvas (no black, no crop).
    @Published var aspectMode: AspectRatioMode {
        didSet { defaults.set(aspectMode.rawValue, forKey: Key.aspectMode) }
    }
    /// Screen capture frame rate. 30 fps by default; 60 fps for smoother motion
    /// (larger files). Only 30 or 60 are offered.
    @Published var captureFPS: Int {
        didSet { defaults.set(captureFPS, forKey: Key.captureFPS) }
    }
    /// Draws a smoothed cursor and adds click ripples + gentle click-focused
    /// zooms to display recordings during post-record composition.
    @Published var cinematicEffectsEnabled: Bool {
        didSet { defaults.set(cinematicEffectsEnabled, forKey: Key.cinematicEffects) }
    }
    /// Records vertically for Shorts/TikTok/Reels, cutting you out of your
    /// background instead of boxing you into a bubble.
    @Published var creativeModeEnabled: Bool {
        didSet { defaults.set(creativeModeEnabled, forKey: Key.creativeEnabled) }
    }
    @Published var creativeLayout: CreativeLayout {
        didSet { defaults.set(creativeLayout.rawValue, forKey: Key.creativeLayout) }
    }
    /// The teleprompter script. Kept across launches and takes — re-recording
    /// the same script is the normal case.
    @Published var scriptDraft: String {
        didSet { defaults.set(scriptDraft, forKey: Key.scriptDraft) }
    }
    /// The slice of the screen vertical recordings frame. Nil records the
    /// middle of the display.
    @Published var creativeScreenRegion: ScreenRegion? {
        didSet {
            if let creativeScreenRegion, let data = try? JSONEncoder().encode(creativeScreenRegion) {
                defaults.set(data, forKey: Key.screenRegion)
            } else {
                defaults.removeObject(forKey: Key.screenRegion)
            }
        }
    }
    /// Burns spoken words into the video as captions (Creative Mode only).
    @Published var captionsEnabled: Bool {
        didSet { defaults.set(captionsEnabled, forKey: Key.captionsEnabled) }
    }
    @Published var captionStyle: CaptionStyle {
        didSet { defaults.set(captionStyle.rawValue, forKey: Key.captionStyle) }
    }
    /// Language to transcribe in. Nil follows the Mac's own language.
    @Published var captionLocaleIdentifier: String? {
        didSet { defaults.set(captionLocaleIdentifier, forKey: Key.captionLocale) }
    }
    @Published var teleprompterFontSize: Double {
        didSet { defaults.set(teleprompterFontSize, forKey: Key.teleprompterFontSize) }
    }
    @Published var teleprompterAutoScroll: Bool {
        didSet { defaults.set(teleprompterAutoScroll, forKey: Key.teleprompterAutoScroll) }
    }
    /// Auto-scroll speed in points per second.
    @Published var teleprompterSpeed: Double {
        didSet { defaults.set(teleprompterSpeed, forKey: Key.teleprompterSpeed) }
    }
    @Published var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: Key.onboardingDone) }
    }
    /// Last-used device/source selections, restored on next launch so the user
    /// doesn't have to re-pick (and so a virtual device isn't auto-selected).
    @Published var lastCameraID: String? {
        didSet { defaults.set(lastCameraID, forKey: Key.lastCameraID) }
    }
    @Published var lastMicrophoneID: String? {
        didSet { defaults.set(lastMicrophoneID, forKey: Key.lastMicID) }
    }
    @Published var lastMode: CaptureMode {
        didSet { defaults.set(lastMode.rawValue, forKey: Key.lastMode) }
    }

    init() {
        cameraBubbleShape = CameraBubbleShape(rawValue: defaults.string(forKey: Key.bubbleShape) ?? "") ?? .circle
        let size = defaults.double(forKey: Key.bubbleSize)
        cameraBubbleSize = size == 0 ? 180 : size
        showCameraBubble = defaults.object(forKey: Key.showBubble) as? Bool ?? true
        cameraMirrored = defaults.bool(forKey: Key.mirrored)
        cameraBackground = CameraBackground(rawValue: defaults.string(forKey: Key.cameraBackground) ?? "") ?? .transparent
        centerStageEnabled = defaults.object(forKey: Key.centerStage) as? Bool ?? true
        cameraCorner = CameraCorner(rawValue: defaults.string(forKey: Key.cameraCorner) ?? "") ?? .bottomLeft
        let pad = defaults.double(forKey: Key.screenPadding)
        screenPadding = min(max(pad, 0), 0.08)
        canvasBackground = CanvasBackground(rawValue: defaults.string(forKey: Key.background) ?? "") ?? .none
        aspectMode = AspectRatioMode(rawValue: defaults.string(forKey: Key.aspectMode) ?? "") ?? .sixteenNine
        captureFPS = defaults.integer(forKey: Key.captureFPS) == 60 ? 60 : 30
        cinematicEffectsEnabled = defaults.object(forKey: Key.cinematicEffects) as? Bool ?? true
        creativeModeEnabled = defaults.bool(forKey: Key.creativeEnabled)
        creativeLayout = CreativeLayout(rawValue: defaults.string(forKey: Key.creativeLayout) ?? "") ?? .screenFill
        scriptDraft = defaults.string(forKey: Key.scriptDraft) ?? ""
        creativeScreenRegion = defaults.data(forKey: Key.screenRegion)
            .flatMap { try? JSONDecoder().decode(ScreenRegion.self, from: $0) }
        captionsEnabled = defaults.object(forKey: Key.captionsEnabled) as? Bool ?? true
        captionStyle = CaptionStyle(rawValue: defaults.string(forKey: Key.captionStyle) ?? "") ?? .boldOutline
        captionLocaleIdentifier = defaults.string(forKey: Key.captionLocale)
        let promptSize = defaults.double(forKey: Key.teleprompterFontSize)
        teleprompterFontSize = promptSize == 0 ? 24 : min(max(promptSize, 14), 48)
        teleprompterAutoScroll = defaults.object(forKey: Key.teleprompterAutoScroll) as? Bool ?? true
        let promptSpeed = defaults.double(forKey: Key.teleprompterSpeed)
        teleprompterSpeed = promptSpeed == 0 ? 40 : min(max(promptSpeed, 10), 120)
        onboardingDone = defaults.bool(forKey: Key.onboardingDone)
        lastCameraID = defaults.string(forKey: Key.lastCameraID)
        lastMicrophoneID = defaults.string(forKey: Key.lastMicID)
        lastMode = CaptureMode(rawValue: defaults.string(forKey: Key.lastMode) ?? "") ?? .screen
    }
}
