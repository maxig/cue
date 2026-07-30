import Foundation
import CryptoKit
import Security

/// One-click Cloudflare setup. The user pastes a single API token (created from
/// a pre-filled dashboard page); everything else — R2 bucket, D1 database and
/// schema, Worker deploy with bindings and secrets, workers.dev link, S3 upload
/// credentials — is provisioned from inside the app.
///
/// The S3 credentials come from the pasted token itself: Cloudflare defines the
/// R2 access key id as the token's id and the secret as the SHA-256 hash of the
/// token value, so no second credential ever needs to be typed.
@MainActor
final class CloudflareProvisioner: ObservableObject {

    enum Step: Int, CaseIterable, Comparable {
        case verifyToken
        case createBucket
        case createDatabase
        case deployWorker
        case enableLink
        case verify

        var title: String {
            switch self {
            case .verifyToken: return "Checking the token"
            case .createBucket: return "Creating video storage"
            case .createDatabase: return "Creating the database"
            case .deployWorker: return "Publishing your share server"
            case .enableLink: return "Turning on the share link"
            case .verify: return "Testing everything end to end"
            }
        }

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Extra recovery action offered next to a failure message.
    enum FailureHelp: Equatable {
        /// R2 needs a one-time (free) activation in the dashboard.
        case enableR2(accountId: String)
    }

    enum Phase: Equatable {
        case idle
        case enteringToken
        case selectingAccount([CloudflareAPI.Account])
        case running(Step)
        case failed(Step, message: String, help: FailureHelp?)
        case connected(workerURL: String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Optional follow-up to a connected setup: put the share link on one of
    /// the account's own domains instead of workers.dev.
    enum DomainPhase: Equatable {
        case idle
        case loadingZones
        case choosing([CloudflareAPI.Zone])
        case attaching(String)
        case failed(String)
    }

    @Published private(set) var domainPhase: DomainPhase = .idle

    static let bucketName = "cue"
    static let databaseName = "cue"
    static let scriptName = "cue"
    private static let compatibilityDate = "2026-07-21"

    private var settings: UploadSettings?
    private var pendingToken = ""

    /// The dashboard's token-creation page, pre-filled with exactly the
    /// permissions setup needs. The user only clicks through and copies the
    /// resulting token.
    static var tokenCreationURL: URL {
        let permissions: [[String: String]] = [
            ["key": "workers_scripts", "type": "edit"],   // deploy the share server
            ["key": "d1", "type": "edit"],                // create the database, apply schema
            ["key": "workers_r2", "type": "edit"],        // create the bucket + S3 upload keys
            ["key": "account_settings", "type": "read"],  // find the account id
            ["key": "zone", "type": "read"],              // list domains for a custom address
            ["key": "workers_routes", "type": "edit"],    // attach the Worker to a domain
            ["key": "dns", "type": "edit"],               // let Cloudflare create the DNS record
        ]
        let json = String(
            data: try! JSONSerialization.data(withJSONObject: permissions),
            encoding: .utf8
        )!
        var components = URLComponents(string: "https://dash.cloudflare.com/profile/api-tokens")!
        components.queryItems = [
            URLQueryItem(name: "permissionGroupKeys", value: json),
            URLQueryItem(name: "accountId", value: "*"),
            URLQueryItem(name: "zoneId", value: "all"),
            URLQueryItem(name: "name", value: "Cue"),
        ]
        return components.url!
    }

    static let signupURL = URL(string: "https://dash.cloudflare.com/sign-up")!

    static func r2PlanURL(accountId: String) -> URL {
        URL(string: "https://dash.cloudflare.com/\(accountId)/r2/plans")!
    }

    // MARK: Entry points

    /// Restores the "connected" card state for a previously completed setup.
    func bootstrap(settings: UploadSettings) {
        self.settings = settings
        guard case .idle = phase else { return }
        if !settings.cloudflareAPIToken.isEmpty, !settings.backendBaseURL.isEmpty {
            phase = .connected(workerURL: settings.backendBaseURL)
        }
    }

    func beginTokenEntry() {
        phase = .enteringToken
    }

    func cancel() {
        pendingToken = ""
        if let settings, !settings.cloudflareAPIToken.isEmpty, !settings.backendBaseURL.isEmpty {
            phase = .connected(workerURL: settings.backendBaseURL)
        } else {
            phase = .idle
        }
    }

    func connect(token rawToken: String) {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        pendingToken = token
        Task { await run(token: token, accountId: nil) }
    }

    func continueWith(account: CloudflareAPI.Account) {
        let token = pendingToken
        Task { await run(token: token, accountId: account.id) }
    }

    func retry() {
        guard case .failed = phase, !pendingToken.isEmpty else { return }
        let token = pendingToken
        let accountId = settings?.cloudflareAccountId
        Task { await run(token: token, accountId: accountId?.isEmpty == false ? accountId : nil) }
    }

    /// Re-runs the whole (idempotent) pipeline with the stored token — also how
    /// an updated app ships a newer share server to an already-connected account.
    func reprovision() {
        guard let settings, !settings.cloudflareAPIToken.isEmpty else {
            beginTokenEntry()
            return
        }
        pendingToken = settings.cloudflareAPIToken
        let accountId = settings.cloudflareAccountId
        let token = pendingToken
        Task { await run(token: token, accountId: accountId.isEmpty ? nil : accountId) }
    }

    /// Forgets the stored API token and account. Working upload settings stay
    /// untouched so already-configured sharing keeps working.
    func forgetToken() {
        settings?.cloudflareAPIToken = ""
        settings?.cloudflareAccountId = ""
        pendingToken = ""
        phase = .idle
        domainPhase = .idle
    }

    // MARK: Custom domain

    func beginDomainSelection() {
        guard let settings, !settings.cloudflareAPIToken.isEmpty, !settings.cloudflareAccountId.isEmpty else {
            domainPhase = .failed("Connect a Cloudflare account first.")
            return
        }
        let api = CloudflareAPI(token: settings.cloudflareAPIToken)
        let accountId = settings.cloudflareAccountId
        domainPhase = .loadingZones
        Task {
            do {
                let zones = try await api.zones(accountId: accountId)
                if zones.isEmpty {
                    domainPhase = .failed("There are no domains on this Cloudflare account yet. Add one in Cloudflare first, or keep the free workers.dev address.")
                } else {
                    domainPhase = .choosing(zones)
                }
            } catch {
                domainPhase = .failed(domainMessage(for: error))
            }
        }
    }

    func attachDomain(zone: CloudflareAPI.Zone, subdomain rawSubdomain: String) {
        guard let settings else { return }
        let subdomain = rawSubdomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidSubdomain(subdomain) else {
            domainPhase = .failed("Use only letters, numbers, and hyphens for the subdomain — for example “cue”.")
            return
        }
        let hostname = "\(subdomain).\(zone.name)"
        let api = CloudflareAPI(token: settings.cloudflareAPIToken)
        let accountId = settings.cloudflareAccountId
        let ownerToken = settings.ownerToken
        domainPhase = .attaching(hostname)
        Task {
            do {
                try await api.attachWorkerDomain(accountId: accountId, zoneId: zone.id,
                                                 hostname: hostname, scriptName: Self.scriptName)
                // Certificates for a fresh hostname can take a little while.
                try await Self.waitForWorker(url: "https://\(hostname)", ownerToken: ownerToken, attempts: 20)
                settings.backendBaseURL = "https://\(hostname)"
                domainPhase = .idle
                phase = .connected(workerURL: settings.backendBaseURL)
            } catch {
                domainPhase = .failed(domainMessage(for: error))
            }
        }
    }

    func cancelDomainSelection() {
        domainPhase = .idle
    }

    private func domainMessage(for error: Error) -> String {
        if let failure = error as? CloudflareAPI.RequestFailure {
            if failure.status == 401 || failure.status == 403 {
                return "The saved token can't manage domains — it was created before this feature. Choose “Run setup again” with a fresh token from the pre-filled page, then retry."
            }
            if failure.messageContains(["record", "conflict", "already"]) {
                return "That address is already in use (an existing DNS record is in the way). Pick a different subdomain, or remove the record in Cloudflare first."
            }
        }
        return friendlyMessage(for: error)
    }

    private static func isValidSubdomain(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 63,
              !value.hasPrefix("-"), !value.hasSuffix("-") else { return false }
        return value.allSatisfy { $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // MARK: Pipeline

    private func run(token: String, accountId knownAccountId: String?) async {
        guard let settings else { return }
        let api = CloudflareAPI(token: token)
        var step = Step.verifyToken
        do {
            // 1. Token → S3 access key id + account list.
            phase = .running(.verifyToken)
            let info = try await api.verifyToken()
            guard info.status == "active" else {
                throw SetupError("The token is \(info.status). Create a fresh one and try again.")
            }

            let accountId: String
            if let knownAccountId {
                accountId = knownAccountId
            } else {
                let accounts = try await api.accounts()
                guard let first = accounts.first else {
                    throw SetupError("The token can't see any Cloudflare account. Create it from the pre-filled page so it includes account access.")
                }
                if accounts.count > 1 {
                    phase = .selectingAccount(accounts)
                    return
                }
                accountId = first.id
            }
            settings.cloudflareAccountId = accountId

            // 2. R2 bucket (the only piece that may need a dashboard visit:
            // Cloudflare requires a one-time free R2 activation with a card on
            // file).
            step = .createBucket
            phase = .running(step)
            do {
                try await api.createR2Bucket(accountId: accountId, name: Self.bucketName)
            } catch let failure as CloudflareAPI.RequestFailure {
                if failure.messageContains(["already exists", "already owned"]) {
                    // Re-running setup — reuse the bucket.
                } else if failure.messageContains(["enable", "payment", "billing", "subscription", "entitle", "purchase"]) {
                    throw SetupFailure(
                        message: "Cloudflare needs you to switch on R2 storage once — it's free, but they ask for a card. Enable it, then try again.",
                        help: .enableR2(accountId: accountId)
                    )
                } else {
                    throw failure
                }
            }

            // 3. D1 database + schema (idempotent CREATE IF NOT EXISTS).
            step = .createDatabase
            phase = .running(step)
            let databaseId: String
            do {
                databaseId = try await api.createD1Database(
                    accountId: accountId, name: Self.databaseName
                ).uuid
            } catch let failure as CloudflareAPI.RequestFailure where failure.messageContains(["already exists"]) {
                guard let existing = try await api.findD1Database(
                    accountId: accountId, name: Self.databaseName
                ) else { throw failure }
                databaseId = existing.uuid
            }
            try await api.d1Query(accountId: accountId, databaseId: databaseId,
                                  sql: try bundledResource("CueSchema", extension: "sql"))

            // 4. Worker deploy. Secrets ship in the same call; the derived S3
            // keys also go to the Worker so share links serve media through
            // short-lived presigned URLs (revocable when a link is disabled).
            step = .deployWorker
            phase = .running(step)
            let ownerToken = settings.ownerToken.isEmpty ? Self.randomToken() : settings.ownerToken
            let s3AccessKey = info.id
            let s3SecretKey = Self.sha256Hex(token)
            var metadata: [String: Any] = [
                "main_module": "index.js",
                "compatibility_date": Self.compatibilityDate,
                "compatibility_flags": ["nodejs_compat"],
                "observability": ["enabled": true, "head_sampling_rate": 1],
                "bindings": [
                    ["type": "r2_bucket", "name": "MEDIA", "bucket_name": Self.bucketName],
                    ["type": "d1", "name": "DB", "id": databaseId],
                    ["type": "ai", "name": "AI"],
                    ["type": "plain_text", "name": "MAX_BYTES", "text": "9000000000"],
                    ["type": "plain_text", "name": "SUMMARY_MODEL", "text": "@cf/meta/llama-3.3-70b-instruct-fp8-fast"],
                    ["type": "plain_text", "name": "R2_ACCOUNT_ID", "text": accountId],
                    ["type": "plain_text", "name": "R2_BUCKET", "text": Self.bucketName],
                    ["type": "secret_text", "name": "OWNER_TOKEN", "text": ownerToken],
                    ["type": "secret_text", "name": "R2_ACCESS_KEY_ID", "text": s3AccessKey],
                    ["type": "secret_text", "name": "R2_SECRET_ACCESS_KEY", "text": s3SecretKey],
                ],
            ]
            // Updating an existing deployment (wrangler-managed or an earlier
            // setup run): inherit vars and secrets this metadata doesn't set —
            // explicit bindings above still win by name — so custom
            // configuration like Cloudflare Access survives the redeploy.
            if try await api.workerScriptExists(accountId: accountId, scriptName: Self.scriptName) {
                metadata["keep_bindings"] = ["plain_text", "json", "secret_text", "secret_key"]
            }
            let script = try bundledResource("CueWorker", extension: "js")
            try await api.uploadWorkerScript(accountId: accountId,
                                             scriptName: Self.scriptName,
                                             metadata: metadata,
                                             moduleSource: Data(script.utf8))

            // 5. Public workers.dev link.
            step = .enableLink
            phase = .running(step)
            var subdomain = try await api.workersSubdomain(accountId: accountId)
            if subdomain == nil {
                let generated = "cue-" + Self.randomToken(bytes: 3)
                try await api.setWorkersSubdomain(accountId: accountId, name: generated)
                subdomain = generated
            }
            guard let subdomain else {
                throw SetupError("Could not register a workers.dev address for the account.")
            }
            try await api.enableWorkersDev(accountId: accountId, scriptName: Self.scriptName)
            let workerURL = "https://\(Self.scriptName).\(subdomain).workers.dev"

            // 6. Prove the whole path before saving anything: S3 write with the
            // derived keys, then the deployed API with the owner token.
            step = .verify
            phase = .running(step)
            let s3Config = MinIOUploadService.Config(
                endpoint: "https://\(accountId).r2.cloudflarestorage.com",
                region: "auto",
                bucket: Self.bucketName,
                accessKey: s3AccessKey,
                secretKey: s3SecretKey,
                publicBaseURL: ""
            )
            try await MinIOUploadService(config: s3Config).verifyAccess()
            try await Self.waitForWorker(url: workerURL, ownerToken: ownerToken)

            // 7. Persist the complete configuration in one go.
            settings.backend = .cueServer
            settings.endpoint = s3Config.endpoint
            settings.region = s3Config.region
            settings.bucket = s3Config.bucket
            settings.accessKey = s3AccessKey
            settings.secretKey = s3SecretKey
            settings.backendBaseURL = workerURL
            settings.ownerToken = ownerToken
            settings.cloudflareAPIToken = token
            phase = .connected(workerURL: workerURL)
        } catch let failure as SetupFailure {
            phase = .failed(step, message: failure.message, help: failure.help)
        } catch {
            phase = .failed(step, message: friendlyMessage(for: error), help: nil)
        }
    }

    /// Fresh workers.dev hostnames can take a little while to resolve; retry
    /// DNS/edge errors, fail fast on real HTTP errors.
    private static func waitForWorker(url: String, ownerToken: String, attempts: Int = 10) async throws {
        guard let endpoint = URL(string: url + "/api/videos") else {
            throw SetupError("The share server address is invalid.")
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
        var lastMessage = "The share server did not come online."
        for attempt in 0..<attempts {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return }
                // 52x/530: edge not ready; 525/526: certificate still provisioning.
                guard [404, 522, 523, 525, 526, 530].contains(status) else {
                    throw SetupError("The deployed server answered HTTP \(status). Try running setup again.")
                }
                lastMessage = "The new share link isn't reachable yet (HTTP \(status))."
            } catch let error as URLError {
                lastMessage = error.localizedDescription
            }
            guard attempt < attempts - 1 else { break }
            try await Task.sleep(for: .seconds(3))
        }
        throw SetupError(lastMessage + " New addresses can take a few minutes to go live — try again shortly.")
    }

    // MARK: Helpers

    private struct SetupError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct SetupFailure: Error {
        let message: String
        let help: FailureHelp?
    }

    private func friendlyMessage(for error: Error) -> String {
        if let failure = error as? CloudflareAPI.RequestFailure {
            if failure.status == 401 || failure.status == 403 {
                return "Cloudflare rejected the token: \(failure.localizedDescription) Create a fresh token from the pre-filled page and try again."
            }
            return failure.localizedDescription
        }
        return error.localizedDescription
    }

    private func bundledResource(_ name: String, extension ext: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw SetupError("This build of Cue is missing its \(name).\(ext) setup resource.")
        }
        return content
    }

    private static func randomToken(bytes count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
