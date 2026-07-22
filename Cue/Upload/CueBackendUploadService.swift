import Foundation

struct CueTranscriptResult: Sendable {
    let text: String
    let vtt: String?
    let updatedAt: Date?
}

struct CueSummaryResult: Sendable {
    let title: String
    let summary: String
}

struct CueRemoteRecording: Decodable, Sendable {
    let id: String
    let title: String
    let transcript: String?
    let transcriptVTT: String?
    let summary: String?
    let titleUpdatedAt: Date?
    let transcriptUpdatedAt: Date?
    let summaryUpdatedAt: Date?
    let disabled: Bool?
    let shareURL: URL?
    let uploadStatus: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, transcript, summary, titleUpdatedAt, transcriptUpdatedAt, summaryUpdatedAt, disabled, shareURL, uploadStatus
        case transcriptVTT = "transcriptVtt"
    }
}

enum CueMetadataField: Hashable, Sendable {
    case title
    case transcript
    case summary
}

/// The full self-hosted flow: PUT the file to MinIO, then register it with the
/// Cue backend, which returns a player URL (e.g. http://localhost:8787/v/<id>)
/// that resolves to a real web player streaming from MinIO.
final class CueBackendUploadService: UploadService {

    private let minio: MinIOUploadService
    private let backendBaseURL: String
    private let ownerToken: String
    private let publishOnUpload: Bool

    init(
        minioConfig: MinIOUploadService.Config,
        backendBaseURL: String,
        ownerToken: String = "",
        publishOnUpload: Bool = false
    ) {
        self.minio = MinIOUploadService(config: minioConfig)
        self.backendBaseURL = backendBaseURL
        self.ownerToken = ownerToken
        self.publishOnUpload = publishOnUpload
    }

    var displayName: String { "Cue server" }
    var linksArePublicOnUpload: Bool { publishOnUpload }

    func prepare(recording: Recording, fileURL: URL) async throws -> URL? {
        guard !backendBaseURL.isEmpty, URL(string: backendBaseURL) != nil else {
            throw UploadError.notConfigured("backend URL")
        }
        let objectKey = minio.objectKey(for: recording, fileURL: fileURL)
        let audioKey = recording.audioFileName.map {
            minio.objectKey(
                for: recording,
                fileURL: fileURL.deletingLastPathComponent().appendingPathComponent($0)
            )
        }
        return try await register(
            recording: recording,
            objectKey: objectKey,
            audioKey: audioKey,
            bytes: 0,
            status: "uploading"
        )
    }

    func upload(
        recording: Recording,
        fileURL: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        guard !backendBaseURL.isEmpty, URL(string: backendBaseURL) != nil else {
            throw UploadError.notConfigured("backend URL")
        }

        let objectKey = minio.objectKey(for: recording, fileURL: fileURL)
        var audioKey: String?
        var audioBytes = 0
        let audioURL = recording.audioFileName.map {
            fileURL.deletingLastPathComponent().appendingPathComponent($0)
        }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if let audioURL { audioKey = minio.objectKey(for: recording, fileURL: audioURL) }

        // Allocate the stable link before moving bytes. This call is idempotent,
        // so relaunch recovery reuses the same entity and multipart checkpoint.
        _ = try await register(
            recording: recording,
            objectKey: objectKey,
            audioKey: audioKey,
            bytes: 0,
            status: "uploading"
        )

        do {
            _ = try await minio.putObject(
                objectKey: objectKey,
                fileURL: fileURL,
                retainCompletionCheckpoint: true,
                progress: progress
            )
            if let audioURL, let audioKey {
                _ = try await minio.putObject(
                    objectKey: audioKey,
                    fileURL: audioURL,
                    contentType: "audio/mp4",
                    retainCompletionCheckpoint: true,
                    progress: { _ in }
                )
                audioBytes = fileSize(audioURL)
            }

            let readyURL = try await register(
                recording: recording,
                objectKey: objectKey,
                audioKey: audioKey,
                bytes: fileSize(fileURL) + audioBytes,
                status: "ready"
            )
            return readyURL
        } catch {
            // Best effort only: the resumable checkpoint remains authoritative on
            // this Mac even if the status update cannot reach the backend.
            _ = try? await register(
                recording: recording,
                objectKey: objectKey,
                audioKey: audioKey,
                bytes: 0,
                status: "failed"
            )
            throw error
        }
    }

    func confirmUploadPersisted(recording: Recording, fileURL: URL) {
        let objectKey = minio.objectKey(for: recording, fileURL: fileURL)
        minio.clearUploadCheckpoint(objectKey: objectKey, fileURL: fileURL)
        if let audioName = recording.audioFileName {
            let audioURL = fileURL.deletingLastPathComponent().appendingPathComponent(audioName)
            let audioKey = minio.objectKey(for: recording, fileURL: audioURL)
            minio.clearUploadCheckpoint(objectKey: audioKey, fileURL: audioURL)
        }
    }

    private func register(
        recording: Recording,
        objectKey: String,
        audioKey: String?,
        bytes: Int,
        status: String
    ) async throws -> URL {
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
            "bytes": bytes,
            "width": recording.width ?? 0,
            "height": recording.height ?? 0,
            "captureMode": recording.captureMode.rawValue,
            "createdAt": isoFormatter.string(from: recording.createdAt),
            "uploadStatus": status,
            "disabled": !publishOnUpload
        ]
        if let updatedAt = recording.titleUpdatedAt {
            payload["titleUpdatedAt"] = Self.isoString(updatedAt)
        }
        if let audioKey { payload["audioKey"] = audioKey }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await Self.dataWithRetry(for: request)
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

    /// Metadata registration is idempotent by recording UUID, so retrying a
    /// transient failure is safe and avoids making a completed multipart upload
    /// look failed because of one brief API outage.
    private static func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                let result = try await URLSession.shared.data(for: request)
                let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) || ![408, 429, 500, 502, 503, 504].contains(status) {
                    return result
                }
                lastError = UploadError.server(
                    status: status,
                    body: String(data: result.0, encoding: .utf8) ?? ""
                )
            } catch {
                lastError = error
            }
            guard attempt < 3 else { break }
            try await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
        }
        throw lastError ?? UploadError.invalidResponse("No metadata response was received.")
    }

    // MARK: Owner actions

    /// Deletes the recording from R2 + backend metadata (owner action).
    func deleteRemote(recording: Recording) async throws {
        _ = try await ownerRequest(path: "/api/videos/\(recording.id.uuidString.lowercased())", method: "DELETE")
    }

    /// Disables or re-enables the public share link (owner action).
    func setShareDisabled(_ disabled: Bool, recording: Recording) async throws {
        let action = disabled ? "disable" : "enable"
        _ = try await ownerRequest(path: "/api/videos/\(recording.id.uuidString.lowercased())/\(action)", method: "POST")
    }

    /// Updates the server-side title so native and web libraries stay in sync.
    func updateTitle(_ title: String, recording: Recording) async throws -> String {
        var payload: [String: Any] = ["title": title]
        if let updatedAt = recording.titleUpdatedAt {
            payload["titleUpdatedAt"] = Self.isoString(updatedAt)
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = try await ownerRequest(
            path: "/api/videos/\(recording.id.uuidString.lowercased())/title",
            method: "POST",
            body: data
        )
        struct Payload: Decodable { let title: String; let titleUpdatedAt: Date? }
        return try decode(Payload.self, from: response).title
    }

    /// Runs Whisper for a recording already registered with the Cue server.
    func transcribe(recording: Recording) async throws -> CueTranscriptResult {
        let data = try await ownerRequest(
            path: "/api/videos/\(recording.id.uuidString.lowercased())/transcribe",
            method: "POST"
        )
        struct Payload: Decodable { let text: String; let vtt: String?; let transcriptUpdatedAt: Date? }
        let payload: Payload = try decode(Payload.self, from: data)
        return CueTranscriptResult(text: payload.text, vtt: payload.vtt, updatedAt: payload.transcriptUpdatedAt)
    }

    /// Generates a summary. The server transcribes first when necessary.
    func summarize(recording: Recording) async throws -> CueSummaryResult {
        let data = try await ownerRequest(
            path: "/api/videos/\(recording.id.uuidString.lowercased())/summarize",
            method: "POST"
        )
        struct Payload: Decodable { let title: String; let summary: String }
        let payload: Payload = try decode(Payload.self, from: data)
        return CueSummaryResult(title: payload.title, summary: payload.summary)
    }

    /// Fetches any insights already generated on the server, allowing the app
    /// to sync results created in either the native Library or web dashboard.
    func fetchInsights(recording: Recording) async throws -> CueRemoteRecording {
        let data = try await ownerRequest(
            path: "/api/videos/\(recording.id.uuidString.lowercased())",
            method: "GET"
        )
        return try decode(CueRemoteRecording.self, from: data)
    }

    /// Fetches the owner Library in one request so the native app can reconcile
    /// every cloud-backed recording without polling each item independently.
    func fetchLibrary() async throws -> [CueRemoteRecording] {
        let data = try await ownerRequest(path: "/api/videos", method: "GET")
        struct Payload: Decodable { let videos: [CueRemoteRecording] }
        return try decode(Payload.self, from: data).videos
    }

    /// Pushes only fields whose local timestamp is newer. The server repeats the
    /// timestamp comparison atomically, then returns the settled remote values.
    func syncMetadata(
        recording: Recording,
        fields: Set<CueMetadataField>
    ) async throws -> CueRemoteRecording {
        var payload: [String: Any] = [:]
        if fields.contains(.title), let updatedAt = recording.titleUpdatedAt {
            payload["title"] = recording.title
            payload["titleUpdatedAt"] = Self.isoString(updatedAt)
        }
        if fields.contains(.transcript), let updatedAt = recording.transcriptUpdatedAt {
            payload["transcript"] = recording.transcript ?? NSNull()
            payload["transcriptVtt"] = recording.transcriptVTT ?? NSNull()
            payload["transcriptUpdatedAt"] = Self.isoString(updatedAt)
        }
        if fields.contains(.summary), let updatedAt = recording.summaryUpdatedAt {
            payload["summary"] = recording.summary ?? NSNull()
            payload["summaryUpdatedAt"] = Self.isoString(updatedAt)
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await ownerRequest(
            path: "/api/videos/\(recording.id.uuidString.lowercased())/sync",
            method: "POST",
            body: body
        )
        return try decode(CueRemoteRecording.self, from: data)
    }

    @discardableResult
    private func ownerRequest(path: String, method: String, body: Data? = nil) async throws -> Data {
        let base = backendBaseURL.trimmingTrailingSlash()
        guard !base.isEmpty, let url = URL(string: base + path) else {
            throw UploadError.notConfigured("backend URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !ownerToken.isEmpty {
            request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UploadError.server(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.makeBackendDecoder().decode(type, from: data)
        } catch {
            throw UploadError.invalidResponse(error.localizedDescription)
        }
    }

    private static func makeBackendDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date")
        }
        return decoder
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }
}
