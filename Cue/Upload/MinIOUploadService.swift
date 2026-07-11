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
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadError.fileMissing
        }
        // Normalize away any trailing slash on the endpoint: otherwise
        // `endpoint/ + /bucket/key` yields a doubled slash in the request path
        // while SigV4 signs the single-slash canonical path → a 403 signature
        // mismatch that's painful to diagnose.
        let endpoint = config.endpoint.trimmingTrailingSlash()
        guard isConfigured, let base = URL(string: endpoint) else {
            throw UploadError.notConfigured("endpoint / bucket / credentials")
        }

        let encodedKey = objectKey
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.uriEncode(String($0)) }
            .joined(separator: "/")
        let path = "/\(Self.uriEncode(config.bucket))/\(encodedKey)"

        guard let url = URL(string: base.absoluteString + path) else {
            throw UploadError.notConfigured("object URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        signV4(&request, method: "PUT", path: path)

        // A fresh uploader per call: its progress handler is instance state, so a
        // shared instance would cross-wire concurrent uploads (e.g. video + sidecar).
        let (data, response) = try await HTTPUploader().upload(request: request, fromFile: fileURL, progress: progress)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UploadError.server(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return url
    }

    /// Best-effort delete of an object (used to clean up orphaned uploads). Never
    /// throws — a failed cleanup is logged, not surfaced.
    func deleteObject(objectKey: String) async {
        let endpoint = config.endpoint.trimmingTrailingSlash()
        guard isConfigured, let base = URL(string: endpoint) else { return }
        let encodedKey = objectKey
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.uriEncode(String($0)) }
            .joined(separator: "/")
        let path = "/\(Self.uriEncode(config.bucket))/\(encodedKey)"
        guard let url = URL(string: base.absoluteString + path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        signV4(&request, method: "DELETE", path: path)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: AWS Signature Version 4

    private func signV4(_ request: inout URLRequest, method: String, path: String) {
        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)

        var host = request.url?.host ?? ""
        if let port = request.url?.port { host += ":\(port)" }

        let payloadHash = "UNSIGNED-PAYLOAD"

        let canonicalHeaders =
            "host:\(host)\n" +
            "x-amz-content-sha256:\(payloadHash)\n" +
            "x-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"

        let canonicalRequest = [
            method,
            path,
            "",                      // canonical query string (none)
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
