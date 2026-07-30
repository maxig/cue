import Foundation

/// Minimal Cloudflare REST API (v4) client used by one-click setup — plain
/// URLSession + JSON, same "no SDK" rule as the S3 uploader.
struct CloudflareAPI {

    let token: String

    private static let base = URL(string: "https://api.cloudflare.com/client/v4")!

    // MARK: Models

    struct ErrorDetail: Decodable {
        let code: Int
        let message: String
    }

    struct RequestFailure: LocalizedError {
        let status: Int
        let errors: [ErrorDetail]

        var errorDescription: String? {
            guard !errors.isEmpty else { return "Cloudflare returned HTTP \(status)." }
            return errors.map(\.message).joined(separator: " ")
        }

        func contains(code: Int) -> Bool { errors.contains { $0.code == code } }

        func messageContains(_ needles: [String]) -> Bool {
            let text = errors.map(\.message).joined(separator: " ").lowercased()
            return needles.contains { text.contains($0) }
        }
    }

    struct TokenInfo: Decodable {
        let id: String
        let status: String
    }

    struct Account: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
    }

    struct D1Database: Decodable {
        let uuid: String
        let name: String
    }

    struct Zone: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let status: String?
    }

    // MARK: Endpoints

    func verifyToken() async throws -> TokenInfo {
        try await request(TokenInfo.self, method: "GET", path: "user/tokens/verify")
    }

    func accounts() async throws -> [Account] {
        try await request([Account].self, method: "GET", path: "accounts",
                          query: [URLQueryItem(name: "per_page", value: "50")])
    }

    func createR2Bucket(accountId: String, name: String) async throws {
        struct Bucket: Decodable { let name: String }
        _ = try await request(Bucket.self, method: "POST", path: "accounts/\(accountId)/r2/buckets",
                              jsonBody: ["name": name])
    }

    func createD1Database(accountId: String, name: String) async throws -> D1Database {
        try await request(D1Database.self, method: "POST", path: "accounts/\(accountId)/d1/database",
                          jsonBody: ["name": name])
    }

    func findD1Database(accountId: String, name: String) async throws -> D1Database? {
        let matches = try await request([D1Database].self, method: "GET",
                                        path: "accounts/\(accountId)/d1/database",
                                        query: [URLQueryItem(name: "name", value: name)])
        return matches.first { $0.name == name }
    }

    /// Executes SQL against D1. Multiple statements joined by semicolons run as
    /// a batch, which lets the whole schema apply in one call.
    func d1Query(accountId: String, databaseId: String, sql: String) async throws {
        struct QueryResult: Decodable { let success: Bool? }
        _ = try await request([QueryResult].self, method: "POST",
                              path: "accounts/\(accountId)/d1/database/\(databaseId)/query",
                              jsonBody: ["sql": sql])
    }

    /// Uploads a module Worker: multipart metadata (bindings, compat date,
    /// secrets) + the bundled script. Secrets ride along as `secret_text`
    /// bindings so deploy is a single call.
    func uploadWorkerScript(
        accountId: String,
        scriptName: String,
        metadata: [String: Any],
        moduleSource: Data
    ) async throws {
        struct Script: Decodable { let id: String? }
        let boundary = "cue-\(UUID().uuidString)"
        var body = Data()
        func appendPart(name: String, filename: String, contentType: String, content: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n".utf8))
        }
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        appendPart(name: "metadata", filename: "metadata.json",
                   contentType: "application/json", content: metadataData)
        appendPart(name: "index.js", filename: "index.js",
                   contentType: "application/javascript+module", content: moduleSource)
        body.append(Data("--\(boundary)--\r\n".utf8))

        _ = try await request(Script.self, method: "PUT",
                              path: "accounts/\(accountId)/workers/scripts/\(scriptName)",
                              rawBody: body,
                              contentType: "multipart/form-data; boundary=\(boundary)")
    }

    /// Domains (zones) on the account that can host a custom share address.
    func zones(accountId: String) async throws -> [Zone] {
        try await request([Zone].self, method: "GET", path: "zones",
                          query: [URLQueryItem(name: "account.id", value: accountId),
                                  URLQueryItem(name: "status", value: "active"),
                                  URLQueryItem(name: "per_page", value: "50")])
    }

    /// Attaches a Workers custom domain: Cloudflare creates the DNS record and
    /// certificate itself. Re-attaching the same hostname to the same Worker is
    /// idempotent; a conflicting existing DNS record fails with a clear error.
    func attachWorkerDomain(accountId: String, zoneId: String, hostname: String, scriptName: String) async throws {
        struct WorkerDomain: Decodable { let hostname: String? }
        _ = try await requestOptional(WorkerDomain.self, method: "PUT",
                                      path: "accounts/\(accountId)/workers/domains",
                                      jsonBody: ["zone_id": zoneId,
                                                 "hostname": hostname,
                                                 "service": scriptName,
                                                 "environment": "production"])
    }

    /// Whether a Worker script with this name is already deployed.
    func workerScriptExists(accountId: String, scriptName: String) async throws -> Bool {
        struct Settings: Decodable {}
        do {
            _ = try await requestOptional(Settings.self, method: "GET",
                                          path: "accounts/\(accountId)/workers/scripts/\(scriptName)/settings")
            return true
        } catch let failure as RequestFailure where failure.status == 404 {
            return false
        }
    }

    /// The account-wide `<name>.workers.dev` subdomain, or nil if the account
    /// has never registered one (fresh accounts answer 404 or a null result).
    func workersSubdomain(accountId: String) async throws -> String? {
        struct Subdomain: Decodable { let subdomain: String? }
        do {
            let result = try await requestOptional(Subdomain.self, method: "GET",
                                                   path: "accounts/\(accountId)/workers/subdomain")
            return (result?.subdomain?.isEmpty == false) ? result?.subdomain : nil
        } catch let failure as RequestFailure where failure.status == 404 {
            return nil
        }
    }

    func setWorkersSubdomain(accountId: String, name: String) async throws {
        struct Subdomain: Decodable { let subdomain: String? }
        _ = try await request(Subdomain.self, method: "PUT",
                              path: "accounts/\(accountId)/workers/subdomain",
                              jsonBody: ["subdomain": name])
    }

    func enableWorkersDev(accountId: String, scriptName: String) async throws {
        struct Result: Decodable { let enabled: Bool? }
        _ = try await requestOptional(Result.self, method: "POST",
                                      path: "accounts/\(accountId)/workers/scripts/\(scriptName)/subdomain",
                                      jsonBody: ["enabled": true, "previews_enabled": false])
    }

    // MARK: Transport

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let errors: [ErrorDetail]?
        let result: T?
    }

    private func request<T: Decodable>(
        _ type: T.Type,
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        jsonBody: [String: Any]? = nil,
        rawBody: Data? = nil,
        contentType: String? = nil
    ) async throws -> T {
        guard let result = try await requestOptional(type, method: method, path: path, query: query,
                                                     jsonBody: jsonBody, rawBody: rawBody,
                                                     contentType: contentType) else {
            throw RequestFailure(status: 200, errors: [
                ErrorDetail(code: 0, message: "Cloudflare returned an empty result.")
            ])
        }
        return result
    }

    /// Like `request`, but a successful call with a null `result` yields nil —
    /// some endpoints (workers.dev subdomain on fresh accounts) do exactly that.
    private func requestOptional<T: Decodable>(
        _ type: T.Type,
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        jsonBody: [String: Any]? = nil,
        rawBody: Data? = nil,
        contentType: String? = nil
    ) async throws -> T? {
        var components = URLComponents(
            url: Self.base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let rawBody {
            request.httpBody = rawBody
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await Self.dataWithRetry(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data)
        guard (200..<300).contains(status), let envelope, envelope.success else {
            throw RequestFailure(status: status, errors: envelope?.errors ?? [])
        }
        return envelope.result
    }

    /// Provisioning calls are idempotent (create-if-missing, PUT overwrite), so
    /// retrying transient failures is safe.
    private static func dataWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let result = try await URLSession.shared.data(for: request)
                let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
                if ![429, 500, 502, 503, 504].contains(status) { return result }
                lastError = RequestFailure(status: status, errors: [])
            } catch {
                lastError = error
            }
            guard attempt < 2 else { break }
            try await Task.sleep(for: .milliseconds(600 * (1 << attempt)))
        }
        throw lastError ?? RequestFailure(status: 0, errors: [])
    }
}
