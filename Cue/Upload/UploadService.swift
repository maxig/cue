import Foundation

/// Abstraction over "where a recording goes when you share it." Swapping the
/// concrete implementation (local stub today, self-hosted MinIO next) doesn't
/// touch the rest of the app.
protocol UploadService: AnyObject {
    var displayName: String { get }
    /// Whether a successful upload produces a link that is immediately public.
    /// Bucket-only links and an explicit Cue share are public; private insight
    /// uploads intentionally remain disabled.
    var linksArePublicOnUpload: Bool { get }

    /// Allocates any remote metadata before bytes move and returns the stable
    /// share URL. Backends without a metadata service use the default nil result.
    func prepare(recording: Recording, fileURL: URL) async throws -> URL?

    /// Upload `fileURL` for `recording` and return the public share URL.
    /// `progress` is called on the main actor with values in 0...1.
    func upload(
        recording: Recording,
        fileURL: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL

    /// Called only after Cue has durably saved the successful upload state in
    /// its local Library. Services may then discard any completion receipt that
    /// protects against re-uploading after a local index-write failure.
    func confirmUploadPersisted(recording: Recording, fileURL: URL)
}

extension UploadService {
    var linksArePublicOnUpload: Bool { true }

    func prepare(recording: Recording, fileURL: URL) async throws -> URL? { nil }
    func confirmUploadPersisted(recording: Recording, fileURL: URL) {}
}

enum UploadError: LocalizedError {
    case notConfigured(String)
    case server(status: Int, body: String)
    case fileMissing
    case invalidResponse(String)
    case invalidUploadState(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "Upload isn't configured: \(what)."
        case .server(let status, let body):
            return "Upload failed (HTTP \(status)). \(body.prefix(200))"
        case .fileMissing: return "The recording file is missing."
        case .invalidResponse(let detail): return "The Cue server returned an invalid response. \(detail)"
        case .invalidUploadState(let detail): return "The upload could not be resumed. \(detail)"
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
