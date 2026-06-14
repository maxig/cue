import Foundation

/// Default backend until real storage is configured. It doesn't actually
/// upload anything — it mints a deterministic placeholder share URL and
/// simulates upload progress so the share UI behaves exactly as it will with
/// a real backend. Swap to `MinIOUploadService` in Settings to go live.
final class LocalStubUploadService: UploadService {

    var displayName: String { "Local (placeholder link)" }

    func upload(
        recording: Recording,
        fileURL: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadError.fileMissing
        }

        // Simulate a smooth upload so the progress UI is exercised end-to-end.
        let steps = 24
        for step in 1...steps {
            try await Task.sleep(nanoseconds: 45_000_000)
            let value = Double(step) / Double(steps)
            await progress(value)
        }

        let slug = Self.shortSlug(from: recording.id)
        guard let url = URL(string: "https://cue.link/v/\(slug)") else {
            throw UploadError.notConfigured("link generation")
        }
        return url
    }

    /// A short, URL-friendly id derived from the recording UUID.
    private static func shortSlug(from id: UUID) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(10))
    }
}
