import Foundation

/// Vertical (9:16) layout used by Creative Mode for short-form video. The
/// screen is reframed entirely at compose time, so a recording can be switched
/// between layouts — or back to landscape — long after it was captured.
enum CreativeLayout: String, CaseIterable, Identifiable, Codable {
    /// Screen fills the tall frame (center-cropped), person cut out in front.
    case screenFill
    /// Screen sits as a card in the top half, person below it.
    case stacked
    /// No screen at all — just the person on the canvas background.
    case personOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenFill: return "Screen Fill"
        case .stacked: return "Stacked"
        case .personOnly: return "Just Me"
        }
    }

    var systemImage: String {
        switch self {
        case .screenFill: return "rectangle.portrait.fill"
        case .stacked: return "rectangle.split.1x2"
        case .personOnly: return "person.fill"
        }
    }

    var detail: String {
        switch self {
        case .screenFill: return "Screen fills the frame, you appear in front."
        case .stacked: return "Screen on top, you underneath."
        case .personOnly: return "Just you, no screen."
        }
    }

    /// Portrait output frame. 1080×1920 is what Shorts, TikTok and Reels expect.
    static let renderSize = CGSize(width: 1080, height: 1920)

    /// Where the cut-out person starts out in each layout. `size` is a fraction
    /// of the frame *height* (see `CameraPlacement`), and a `centerY` past the
    /// bottom edge is intentional — it crops the person around the waist.
    var defaultCutoutPlacement: CameraPlacement {
        switch self {
        case .screenFill: return CameraPlacement(centerX: 0.5, centerY: 0.78, size: 0.55)
        case .stacked: return CameraPlacement(centerX: 0.5, centerY: 0.80, size: 0.42)
        case .personOnly: return CameraPlacement(centerX: 0.5, centerY: 0.62, size: 0.85)
        }
    }
}

/// How the camera is drawn into the composite.
///
/// Deliberately separate from `CameraBubbleShape`: a shape is a corner radius
/// applied to a squared-off crop, while `cutout` skips the crop and the mask
/// entirely and composites the segmented person at full extent.
enum CameraStyle: String, CaseIterable, Identifiable, Codable {
    case bubble
    case cutout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bubble: return "Bubble"
        case .cutout: return "Cut-out"
        }
    }
}
