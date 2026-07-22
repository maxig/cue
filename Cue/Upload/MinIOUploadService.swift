import Foundation
import CryptoKit

/// Uploads recordings to a self-hosted MinIO (or any S3-compatible) bucket via
/// a SigV4-signed `PUT`, using only Foundation + CryptoKit — no SDK, no other
/// dependencies. Uses path-style addressing (`endpoint/bucket/key`), which is
/// what MinIO defaults to.
final class MinIOUploadService: UploadService {

    struct Config {
        var endpoint: String        // e.g. http://localhost:9000
        var region: String          // e.g. us-east-1
        var bucket: String          // e.g. cue
        var accessKey: String
        var secretKey: String
        var publicBaseURL: String   // optional CDN/base for the share link
    }

    private let config: Config
    private let uploader = HTTPUploader()
    private let multipartThreshold: Int64 = 16 * 1_024 * 1_024
    private let multipartPartSize: Int64 = 16 * 1_024 * 1_024
    private let multipartConcurrency = 3

    private struct UploadCheckpoint: Codable {
        var objectKey: String
        var fileSize: Int64
        var modifiedAt: Date
        var uploadID: String?
        var parts: [String: String]
        var createdAt: Date
        var completed: Bool
    }

    private struct UploadedPart: Sendable {
        let number: Int
        let etag: String
    }

    init(config: Config) { self.config = config }

    var displayName: String { "MinIO · \(config.bucket)" }

    var isConfigured: Bool {
        !config.accessKey.isEmpty && !config.secretKey.isEmpty
            && !config.bucket.isEmpty && URL(string: config.endpoint) != nil
    }

    /// The S3 object key Cue uses for a recording's file.
    func objectKey(for recording: Recording, fileURL: URL) -> String {
        "\(recording.id.uuidString.lowercased())/\(fileURL.lastPathComponent)"
    }

    func upload(
        recording: Recording,
        fileURL: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let key = objectKey(for: recording, fileURL: fileURL)
        let objectURL = try await putObject(objectKey: key, fileURL: fileURL, progress: progress)
        if !config.publicBaseURL.isEmpty,
           let publicURL = URL(string: config.publicBaseURL.trimmingTrailingSlash() + "/" + key) {
            return publicURL
        }
        return objectURL
    }

    /// Uploads a file to `objectKey` and returns the canonical object URL.
    func putObject(
        objectKey: String,
        fileURL: URL,
        contentType: String = "video/mp4",
        retainCompletionCheckpoint: Bool = false,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadError.fileMissing
        }
        guard isConfigured, let base = URL(string: config.endpoint) else {
            throw UploadError.notConfigured("endpoint / bucket / credentials")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date) ?? .distantPast
        guard fileSize > 0 else { throw UploadError.fileMissing }

        let target = try objectTarget(base: base, objectKey: objectKey)
        let checkpointURL = uploadCheckpointURL(objectKey: objectKey, fileURL: fileURL)
        var checkpoint = loadCheckpoint(
            at: checkpointURL,
            objectKey: objectKey,
            fileSize: fileSize,
            modifiedAt: modifiedAt
        )
        if checkpoint?.completed == true {
            await progress(1)
            return target.url
        }

        if fileSize < multipartThreshold {
            try await putSingleObject(
                target: target,
                fileURL: fileURL,
                contentType: contentType,
                progress: progress
            )
            if retainCompletionCheckpoint {
                checkpoint = UploadCheckpoint(
                    objectKey: objectKey,
                    fileSize: fileSize,
                    modifiedAt: modifiedAt,
                    uploadID: nil,
                    parts: [:],
                    createdAt: .now,
                    completed: true
                )
                try saveCheckpoint(checkpoint!, to: checkpointURL)
            } else {
                try? FileManager.default.removeItem(at: checkpointURL)
            }
            return target.url
        }

        do {
            try await putMultipartObject(
                target: target,
                objectKey: objectKey,
                fileURL: fileURL,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
                contentType: contentType,
                checkpointURL: checkpointURL,
                checkpoint: checkpoint,
                retainCompletionCheckpoint: retainCompletionCheckpoint,
                progress: progress
            )
            return target.url
        } catch UploadError.server(let status, _) where checkpoint != nil && (status == 400 || status == 404) {
            // Multipart uploads expire server-side (R2 currently cleans them up
            // after seven days). Discard only that stale server session and retry
            // once from a fresh upload; local media remains untouched.
            try? FileManager.default.removeItem(at: checkpointURL)
            try await putMultipartObject(
                target: target,
                objectKey: objectKey,
                fileURL: fileURL,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
                contentType: contentType,
                checkpointURL: checkpointURL,
                checkpoint: nil,
                retainCompletionCheckpoint: retainCompletionCheckpoint,
                progress: progress
            )
            return target.url
        }
    }

    /// Removes the local "object completed" marker after the Cue metadata record
    /// has also been finalized. Until then, a registration retry skips re-sending
    /// an already uploaded multi-gigabyte movie.
    func clearUploadCheckpoint(objectKey: String, fileURL: URL) {
        try? FileManager.default.removeItem(at: uploadCheckpointURL(objectKey: objectKey, fileURL: fileURL))
    }

    private typealias ObjectTarget = (url: URL, path: String)

    private func objectTarget(base: URL, objectKey: String) throws -> ObjectTarget {
        let encodedKey = objectKey
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.uriEncode(String($0)) }
            .joined(separator: "/")
        let path = "/\(Self.uriEncode(config.bucket))/\(encodedKey)"
        let root = base.absoluteString.trimmingTrailingSlash()
        guard let url = URL(string: root + path) else {
            throw UploadError.notConfigured("object URL")
        }
        return (url, path)
    }

    private func requestURL(target: ObjectTarget, query: [String: String]) throws -> (URL, String) {
        let canonical = query.keys.sorted().map {
            "\(Self.uriEncode($0))=\(Self.uriEncode(query[$0] ?? ""))"
        }.joined(separator: "&")
        guard var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false) else {
            throw UploadError.notConfigured("object URL")
        }
        components.percentEncodedQuery = canonical.isEmpty ? nil : canonical
        guard let url = components.url else { throw UploadError.notConfigured("object URL") }
        return (url, canonical)
    }

    private func putSingleObject(
        target: ObjectTarget,
        fileURL: URL,
        contentType: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        var lastError: Error?
        for attempt in 0..<4 {
            var request = URLRequest(url: target.url)
            request.httpMethod = "PUT"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            signV4(&request, path: target.path, canonicalQuery: "", payloadHash: "UNSIGNED-PAYLOAD")
            do {
                let (data, response) = try await uploader.upload(request: request, fromFile: fileURL, progress: progress)
                try Self.requireSuccess(data: data, response: response)
                await progress(1)
                return
            } catch {
                lastError = error
                guard attempt < 3, Self.isRetryable(error) else { throw error }
                try await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
            }
        }
        throw lastError ?? UploadError.invalidUploadState("No upload attempt completed.")
    }

    private func putMultipartObject(
        target: ObjectTarget,
        objectKey: String,
        fileURL: URL,
        fileSize: Int64,
        modifiedAt: Date,
        contentType: String,
        checkpointURL: URL,
        checkpoint existing: UploadCheckpoint?,
        retainCompletionCheckpoint: Bool,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        var checkpoint = existing ?? UploadCheckpoint(
            objectKey: objectKey,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            uploadID: nil,
            parts: [:],
            createdAt: .now,
            completed: false
        )
        if checkpoint.uploadID == nil {
            checkpoint.uploadID = try await initiateMultipart(target: target, contentType: contentType)
            try saveCheckpoint(checkpoint, to: checkpointURL)
        }
        guard let uploadID = checkpoint.uploadID else {
            throw UploadError.invalidUploadState("The storage service returned no multipart upload id.")
        }

        let partCount = Int((fileSize + multipartPartSize - 1) / multipartPartSize)
        var pending = (1...partCount).filter { checkpoint.parts[String($0)] == nil }
        var completedCount = checkpoint.parts.count
        await progress(Double(completedCount) / Double(partCount))

        try await withThrowingTaskGroup(of: UploadedPart.self) { group in
            func enqueue(_ number: Int) {
                group.addTask { [self] in
                    try await uploadPart(
                        target: target,
                        uploadID: uploadID,
                        partNumber: number,
                        fileURL: fileURL,
                        fileSize: fileSize,
                        contentType: contentType
                    )
                }
            }

            for _ in 0..<min(multipartConcurrency, pending.count) {
                enqueue(pending.removeFirst())
            }
            while let part = try await group.next() {
                checkpoint.parts[String(part.number)] = part.etag
                try saveCheckpoint(checkpoint, to: checkpointURL)
                completedCount += 1
                await progress(Double(completedCount) / Double(partCount))
                if !pending.isEmpty { enqueue(pending.removeFirst()) }
            }
        }

        let parts = (1...partCount).compactMap { number -> UploadedPart? in
            checkpoint.parts[String(number)].map { UploadedPart(number: number, etag: $0) }
        }
        guard parts.count == partCount else {
            throw UploadError.invalidUploadState("Some uploaded parts were not checkpointed.")
        }
        try await completeMultipart(target: target, uploadID: uploadID, parts: parts)
        checkpoint.completed = true
        checkpoint.uploadID = nil
        if retainCompletionCheckpoint {
            try saveCheckpoint(checkpoint, to: checkpointURL)
        } else {
            try? FileManager.default.removeItem(at: checkpointURL)
        }
        await progress(1)
    }

    private func initiateMultipart(target: ObjectTarget, contentType: String) async throws -> String {
        let (url, query) = try requestURL(target: target, query: ["uploads": ""])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        signV4(&request, path: target.path, canonicalQuery: query, payloadHash: Self.sha256Hex(Data()))
        let (data, response) = try await Self.dataWithRetry(request)
        try Self.requireSuccess(data: data, response: response)
        guard let xml = String(data: data, encoding: .utf8),
              let uploadID = Self.xmlValue("UploadId", in: xml), !uploadID.isEmpty else {
            throw UploadError.invalidResponse("Multipart initiation returned no upload id.")
        }
        return uploadID
    }

    private func uploadPart(
        target: ObjectTarget,
        uploadID: String,
        partNumber: Int,
        fileURL: URL,
        fileSize: Int64,
        contentType: String
    ) async throws -> UploadedPart {
        let offset = Int64(partNumber - 1) * multipartPartSize
        let count = Int(min(multipartPartSize, fileSize - offset))
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
            throw UploadError.invalidUploadState("Could not read upload part \(partNumber).")
        }

        let (url, query) = try requestURL(target: target, query: [
            "partNumber": String(partNumber),
            "uploadId": uploadID,
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        signV4(&request, path: target.path, canonicalQuery: query, payloadHash: "UNSIGNED-PAYLOAD")
        let (data, response) = try await Self.uploadWithRetry(request, data: chunk)
        try Self.requireSuccess(data: data, response: response)
        guard let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
            throw UploadError.invalidResponse("Storage returned no ETag for part \(partNumber).")
        }
        return UploadedPart(number: partNumber, etag: etag)
    }

    private func completeMultipart(target: ObjectTarget, uploadID: String, parts: [UploadedPart]) async throws {
        let body = "<CompleteMultipartUpload>" + parts.sorted(by: { $0.number < $1.number }).map {
            "<Part><PartNumber>\($0.number)</PartNumber><ETag>\(Self.xmlEscape($0.etag))</ETag></Part>"
        }.joined() + "</CompleteMultipartUpload>"
        let data = Data(body.utf8)
        let (url, query) = try requestURL(target: target, query: ["uploadId": uploadID])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        signV4(&request, path: target.path, canonicalQuery: query, payloadHash: Self.sha256Hex(data))
        let (responseData, response) = try await Self.dataWithRetry(request)
        try Self.requireSuccess(data: responseData, response: response)
    }

    private func uploadCheckpointURL(objectKey: String, fileURL: URL) -> URL {
        let digest = Self.sha256Hex(Data(objectKey.utf8)).prefix(16)
        return fileURL.deletingLastPathComponent().appendingPathComponent(".upload-\(digest).json")
    }

    private func loadCheckpoint(
        at url: URL,
        objectKey: String,
        fileSize: Int64,
        modifiedAt: Date
    ) -> UploadCheckpoint? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder.cue.decode(UploadCheckpoint.self, from: data),
              value.objectKey == objectKey,
              value.fileSize == fileSize,
              abs(value.modifiedAt.timeIntervalSince(modifiedAt)) < 1 else { return nil }
        return value
    }

    private func saveCheckpoint(_ checkpoint: UploadCheckpoint, to url: URL) throws {
        try JSONEncoder.cue.encode(checkpoint).write(to: url, options: [.atomic, .completeFileProtection])
    }

    // MARK: AWS Signature Version 4

    private func signV4(
        _ request: inout URLRequest,
        path: String,
        canonicalQuery: String,
        payloadHash: String
    ) {
        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)

        var host = request.url?.host ?? ""
        if let port = request.url?.port { host += ":\(port)" }

        let canonicalHeaders =
            "host:\(host)\n" +
            "x-amz-content-sha256:\(payloadHash)\n" +
            "x-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            path,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(config.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(
            secret: config.secretKey, dateStamp: dateStamp, region: config.region, service: "s3"
        )
        let signature = Self.hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        let authorization =
            "AWS4-HMAC-SHA256 " +
            "Credential=\(config.accessKey)/\(scope), " +
            "SignedHeaders=\(signedHeaders), " +
            "Signature=\(signature)"

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: Crypto helpers

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func hmacHex(key: Data, data: Data) -> String {
        hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    /// RFC 3986 encoding for a single path segment (slashes handled by caller).
    private static func uriEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func dataWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                let result = try await URLSession.shared.data(for: request)
                let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) || ![408, 429, 500, 502, 503, 504].contains(status) {
                    return result
                }
                lastError = UploadError.server(status: status, body: String(data: result.0, encoding: .utf8) ?? "")
            } catch {
                lastError = error
            }
            guard attempt < 3 else { break }
            try await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
        }
        throw lastError ?? UploadError.invalidUploadState("The storage request did not complete.")
    }

    private static func uploadWithRetry(_ request: URLRequest, data: Data) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                let result = try await URLSession.shared.upload(for: request, from: data)
                let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) || ![408, 429, 500, 502, 503, 504].contains(status) {
                    return result
                }
                lastError = UploadError.server(status: status, body: String(data: result.0, encoding: .utf8) ?? "")
            } catch {
                lastError = error
            }
            guard attempt < 3 else { break }
            try await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
        }
        throw lastError ?? UploadError.invalidUploadState("An upload part did not complete.")
    }

    private static func requireSuccess(data: Data, response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UploadError.server(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case UploadError.server(let status, _) = error {
            return [408, 429, 500, 502, 503, 504].contains(status)
        }
        return error is URLError
    }

    private static func xmlValue(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>")?.upperBound,
              let end = xml.range(of: "</\(name)>", range: start..<xml.endIndex)?.lowerBound else { return nil }
        return String(xml[start..<end])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}

/// `URLSession` file upload with progress reporting via the task delegate.
private final class HTTPUploader: NSObject, URLSessionTaskDelegate {
    private var progressHandler: (@MainActor (Double) -> Void)?

    func upload(
        request: URLRequest,
        fromFile fileURL: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> (Data, URLResponse) {
        self.progressHandler = progress
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, fromFile: fileURL)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let value = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let handler = progressHandler
        Task { @MainActor in handler?(value) }
    }
}

extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
