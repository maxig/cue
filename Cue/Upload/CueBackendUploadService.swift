import Foundation

/// The full self-hosted flow: PUT the file to MinIO, then register it with the
/// Cue backend, which returns a player URL (e.g. http://localhost:8787/v/<id>)
/// that resolves to a real web player streaming from MinIO.
final class CueBackendUploadService: UploadService {

    private let minio: MinIOUploadService
    private let backendBaseURL: String
    private let ownerToken: String

    init(minioConfig: MinIOUploadService.Config, backendBaseURL: String, ownerToken: String = "") {
        self.minio = MinIOUploadService(config: minioConfig)
        self.backendBaseURL = backendBaseURL
        self.ownerToken = ownerToken
    }

    var displayName: String { "Cue server" }

    func upload(
        recording: Recording,
        fileURL: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        guard !backendBaseURL.isEmpty, URL(string: backendBaseURL) != nil else {
            throw UploadError.notConfigured("backend URL")
        }

        // 1) Upload the media to MinIO.
        let objectKey = minio.objectKey(for: recording, fileURL: fileURL)
        _ = try await minio.putObject(objectKey: objectKey, fileURL: fileURL, progress: progress)

        // 1b) Upload the audio-only sidecar (used for transcription) if present,
        // so the backend transcribes audio rather than the full video. It lives
        // next to the video in the recording folder.
        var audioKey: String?
        var audioBytes = 0
        if let audioName = recording.audioFileName {
            let audioURL = fileURL.deletingLastPathComponent().appendingPathComponent(audioName)
            if FileManager.default.fileExists(atPath: audioURL.path) {
                let key = minio.objectKey(for: recording, fileURL: audioURL)
                _ = try await minio.putObject(objectKey: key, fileURL: audioURL,
                                              contentType: "audio/mp4", progress: { _ in })
                audioKey = key
                audioBytes = fileSize(audioURL)
            }
        }

        // 2) Register metadata with the backend.
        let base = backendBaseURL.trimmingTrailingSlash()
        guard let endpoint = URL(string: base + "/api/videos") else {
            throw UploadError.notConfigured("backend URL")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !ownerToken.isEmpty {
            request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
        }

        let isoFormatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "id": recording.id.uuidString.lowercased(),
            "title": recording.title,
            "durationSeconds": recording.duration,
            "objectKey": objectKey,
            "bytes": fileSize(fileURL) + audioBytes,
            "width": recording.width ?? 0,
            "height": recording.height ?? 0,
            "captureMode": recording.captureMode.rawValue,
            "createdAt": isoFormatter.string(from: recording.createdAt)
        ]
        if let audioKey { payload["audioKey"] = audioKey }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UploadError.server(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let urlString = json["url"] as? String, let url = URL(string: urlString) {
            return url
        }
        guard let fallback = URL(string: "\(base)/v/\(recording.id.uuidString.lowercased())") else {
            throw UploadError.notConfigured("share URL")
        }
        return fallback
    }

    // MARK: Owner actions

    /// Deletes the recording from R2 + backend metadata (owner action).
    func deleteRemote(recording: Recording) async throws {
        try await ownerRequest(path: "/api/videos/\(recording.id.uuidString.lowercased())", method: "DELETE")
    }

    /// Disables or re-enables the public share link (owner action).
    func setShareDisabled(_ disabled: Bool, recording: Recording) async throws {
        let action = disabled ? "disable" : "enable"
        try await ownerRequest(path: "/api/videos/\(recording.id.uuidString.lowercased())/\(action)", method: "POST")
    }

    private func ownerRequest(path: String, method: String) async throws {
        let base = backendBaseURL.trimmingTrailingSlash()
        guard !base.isEmpty, let url = URL(string: base + path) else {
            throw UploadError.notConfigured("backend URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !ownerToken.isEmpty {
            request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UploadError.server(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }
}
