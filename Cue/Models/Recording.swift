import Foundation

/// Sharing/upload lifecycle for a recording.
enum ShareStatus: Codable, Hashable {
    case local                 // saved on disk only
    case uploading(progress: Double)
    case shared(url: URL)
    case disabled(url: URL)    // shared, but the owner turned the link off
    case failed(reason: String)
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
         share: ShareStatus = .local) {
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
    }

    var shareURL: URL? {
        switch share {
        case let .shared(url), let .disabled(url): return url
        default: return nil
        }
    }

    /// `m:ss`, or `h:mm:ss` once past an hour (shares `TimeInterval.clockString`).
    var formattedDuration: String { duration.clockString }
}
