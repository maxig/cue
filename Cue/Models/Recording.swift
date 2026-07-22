import Foundation

/// Sharing/upload lifecycle for a recording.
enum ShareStatus: Codable, Hashable {
    case local                 // saved on disk only
    case uploading(progress: Double)
    case shared(url: URL)
    case disabled(url: URL)    // shared, but the owner turned the link off
    case failed(reason: String)
}

/// One pointer sample or click. `t` is content-timeline seconds (lead-in
/// trimmed, pauses excised — matching the composer's frame time); `x`/`y` are
/// normalized to the captured display (0…1, top-left origin).
struct MouseSample: Codable, Hashable {
    var t: Double
    var x: Double
    var y: Double
}

/// Captured pointer activity for a display recording, consumed by cinematic
/// effects (smooth cursor from `moves`, ripples + zoom from `clicks`).
struct MouseActivity: Codable, Hashable {
    var moves: [MouseSample]
    var clicks: [MouseSample]
    static let empty = MouseActivity(moves: [], clicks: [])
    var isEmpty: Bool { moves.isEmpty && clicks.isEmpty }
}

/// Where the camera picture-in-picture sits in the composited frame. Normalized
/// to the render size (origin top-left); `size` is the bubble diameter as a
/// fraction of the frame width. When a recording has no placement the compositor
/// falls back to the corner from its `CompositionPlan`.
struct CameraPlacement: Codable, Hashable {
    var centerX: Double    // 0…1, left → right
    var centerY: Double    // 0…1, top → bottom
    var size: Double       // diameter ÷ frame width

    static let `default` = CameraPlacement(centerX: 0.13, centerY: 0.84, size: 0.22)
}

/// Everything needed to re-compose a recording's `final.mp4` from its retained
/// raw tracks. Captured at first compose so post-record edits (camera reposition,
/// cinematic effects) can re-render without re-recording.
struct CompositionPlan: Codable, Hashable {
    var bubbleShape: CameraBubbleShape
    var mirrored: Bool
    var cameraBackground: CameraBackground
    var corner: CameraCorner
    var padding: Double
    var background: CanvasBackground
    var aspectRatio: Double?
    /// Render rate used for the original composition. Optional so plans saved
    /// before the 30/60 fps setting was added still decode and default to 30.
    var fps: Int?
    var cameraStartOffset: Double?
    var leadTrim: Double?
    var cameraHiddenRanges: [ClosedRange<Double>]
    var screenPauseSpans: [ClosedRange<Double>]
    var cameraPauseSpans: [ClosedRange<Double>]
    /// Post-record camera placement override. Nil = use `corner`.
    var cameraPlacement: CameraPlacement?
    /// Sidecar JSON of captured pointer activity (clicks + path) for cinematic
    /// effects. Nil when nothing was captured (e.g. window / camera-only).
    var activityFileName: String?
    /// Whether pointer smoothing, click ripples, and click-focused auto-zoom are
    /// baked into the current final.mp4. Optional for older saved plans.
    var cinematicEffectsEnabled: Bool?
    /// Whether ScreenCaptureKit baked its native cursor into the retained screen
    /// track. Older plans decode as nil and are treated as true.
    var sourceShowsCursor: Bool?
}

/// Metadata for one captured session. Media files live in a per-recording
/// folder; only relative file names are persisted so the library survives the
/// app's support directory moving.
struct Recording: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval

    /// Relative file names inside the recording's folder.
    var screenFileName: String?
    var cameraFileName: String?
    /// The composited, shareable output (camera PiP + mixed audio).
    var finalFileName: String?
    /// Audio-only sidecar (`audio.m4a`) used for transcription — uploaded
    /// alongside the video so the backend never transcribes the whole movie.
    var audioFileName: String?
    var thumbnailFileName: String?

    /// Pixel dimensions of the composited output. Optional so older library
    /// entries (written before compositing existed) still decode.
    var width: Int?
    var height: Int?

    var captureMode: CaptureMode
    var share: ShareStatus
    /// Stable Cue-server URL allocated before the media upload begins. Keeping it
    /// in the local index lets an interrupted upload resume against the same link
    /// after a relaunch instead of minting duplicate remote records.
    var preparedShareURL: URL?
    /// Backend used for the current remote copy. Optional for recordings saved
    /// before this field existed; those are safely re-registered when needed.
    var uploadBackend: UploadBackend?

    /// AI insights cached locally so the Library can show them without opening
    /// or signing in to the web dashboard.
    var transcript: String?
    var transcriptVTT: String?
    var summary: String?

    /// Per-field clocks used to reconcile offline native edits with changes
    /// made in the web Library. Optional so recordings saved by older Cue
    /// versions continue to decode; the first successful sync backfills them.
    var titleUpdatedAt: Date?
    var transcriptUpdatedAt: Date?
    var summaryUpdatedAt: Date?

    /// Saved compose inputs, enabling post-record re-rendering (camera reposition
    /// + cinematic effects). Nil for entries recorded before this existed.
    var plan: CompositionPlan?

    init(id: UUID = UUID(),
         title: String,
         createdAt: Date = .now,
         duration: TimeInterval = 0,
         screenFileName: String? = nil,
         cameraFileName: String? = nil,
         finalFileName: String? = nil,
         audioFileName: String? = nil,
         thumbnailFileName: String? = nil,
         width: Int? = nil,
         height: Int? = nil,
         captureMode: CaptureMode = .screen,
         share: ShareStatus = .local,
         preparedShareURL: URL? = nil,
         uploadBackend: UploadBackend? = nil,
         transcript: String? = nil,
         transcriptVTT: String? = nil,
         summary: String? = nil,
         titleUpdatedAt: Date? = nil,
         transcriptUpdatedAt: Date? = nil,
         summaryUpdatedAt: Date? = nil,
         plan: CompositionPlan? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.screenFileName = screenFileName
        self.cameraFileName = cameraFileName
        self.finalFileName = finalFileName
        self.audioFileName = audioFileName
        self.thumbnailFileName = thumbnailFileName
        self.width = width
        self.height = height
        self.captureMode = captureMode
        self.share = share
        self.preparedShareURL = preparedShareURL
        self.uploadBackend = uploadBackend
        self.transcript = transcript
        self.transcriptVTT = transcriptVTT
        self.summary = summary
        self.titleUpdatedAt = titleUpdatedAt ?? createdAt
        self.transcriptUpdatedAt = transcriptUpdatedAt
        self.summaryUpdatedAt = summaryUpdatedAt
        self.plan = plan
    }

    var shareURL: URL? {
        switch share {
        case let .shared(url), let .disabled(url): return url
        default: return preparedShareURL
        }
    }

    var formattedDuration: String {
        let total = Int(duration.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
