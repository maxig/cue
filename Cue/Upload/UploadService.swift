import Foundation

/// Abstraction over "where a recording goes when you share it." Swapping the
/// concrete implementation (local stub today, self-hosted MinIO next) doesn't
/// touch the rest of the app.
protocol UploadService: AnyObject {
    var displayName: String { get }

    /// Upload `fileURL` for `recording` and return the public share URL.
    /// `progress` is called on the main actor with values in 0...1.
    func upload(
        recording: Recording,
        fileURL: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL
}

enum UploadError: LocalizedError {
    case notConfigured(String)
    case server(status: Int, body: String)
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "Upload isn't configured: \(what)."
        case .server(let status, let body):
            return "Upload failed (HTTP \(status)). \(body.prefix(200))"
        case .fileMissing: return "The recording file is missing."
        }
    }
}

/// Which backend the app uploads to.
enum UploadBackend: String, CaseIterable, Identifiable, Codable {
    case localStub
    case minio
    case cueServer

    var id: String { rawValue }
    var title: String {
        switch self {
        case .localStub: return "Local only (no upload)"
        case .minio: return "Bucket only (direct link)"
        case .cueServer: return "Cue server (web player)"
        }
    }
}
