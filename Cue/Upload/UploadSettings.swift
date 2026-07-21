import Foundation
import Combine

/// User-configurable storage settings. Non-secret fields live in UserDefaults;
/// the secret key lives in the Keychain.
@MainActor
final class UploadSettings: ObservableObject {

    private let defaults = UserDefaults.standard
    private enum Key {
        static let backend = "cue.upload.backend"
        static let endpoint = "cue.minio.endpoint"
        static let region = "cue.minio.region"
        static let bucket = "cue.minio.bucket"
        static let accessKey = "cue.minio.accessKey"
        static let publicBaseURL = "cue.minio.publicBaseURL"
        static let backendBaseURL = "cue.backend.baseURL"
        static let secretAccount = "minio.secretKey"
        static let ownerTokenAccount = "cue.owner.token"
    }

    @Published var backend: UploadBackend {
        didSet { defaults.set(backend.rawValue, forKey: Key.backend) }
    }
    @Published var endpoint: String { didSet { defaults.set(endpoint, forKey: Key.endpoint) } }
    @Published var region: String { didSet { defaults.set(region, forKey: Key.region) } }
    @Published var bucket: String { didSet { defaults.set(bucket, forKey: Key.bucket) } }
    @Published var accessKey: String { didSet { defaults.set(accessKey, forKey: Key.accessKey) } }
    @Published var publicBaseURL: String { didSet { defaults.set(publicBaseURL, forKey: Key.publicBaseURL) } }
    @Published var backendBaseURL: String { didSet { defaults.set(backendBaseURL, forKey: Key.backendBaseURL) } }
    @Published var secretKey: String { didSet { Keychain.set(secretKey, for: Key.secretAccount) } }
    /// Owner token for privileged backend actions, including native Library AI.
    @Published var ownerToken: String { didSet { Keychain.set(ownerToken, for: Key.ownerTokenAccount) } }

    init() {
        backend = UploadBackend(rawValue: defaults.string(forKey: Key.backend) ?? "") ?? .localStub
        endpoint = defaults.string(forKey: Key.endpoint) ?? "http://localhost:9000"
        region = defaults.string(forKey: Key.region) ?? "us-east-1"
        bucket = defaults.string(forKey: Key.bucket) ?? "cue"
        accessKey = defaults.string(forKey: Key.accessKey) ?? ""
        publicBaseURL = defaults.string(forKey: Key.publicBaseURL) ?? ""
        backendBaseURL = defaults.string(forKey: Key.backendBaseURL) ?? "http://localhost:8787"
        secretKey = Keychain.get(Key.secretAccount) ?? ""
        ownerToken = Keychain.get(Key.ownerTokenAccount) ?? ""
    }

    var minioConfig: MinIOUploadService.Config {
        MinIOUploadService.Config(
            endpoint: endpoint,
            region: region.isEmpty ? "us-east-1" : region,
            bucket: bucket,
            accessKey: accessKey,
            secretKey: secretKey,
            publicBaseURL: publicBaseURL
        )
    }

    /// Builds the upload service matching the current backend selection.
    func makeService() -> UploadService {
        switch backend {
        case .localStub:
            return LocalStubUploadService()
        case .minio:
            return MinIOUploadService(config: minioConfig)
        case .cueServer:
            return CueBackendUploadService(minioConfig: minioConfig,
                                           backendBaseURL: backendBaseURL,
                                           ownerToken: ownerToken)
        }
    }

    /// The Cue-server service for owner actions (delete / disable a share link),
    /// available only when that backend is selected and configured.
    func cueBackendService() -> CueBackendUploadService? {
        guard backend == .cueServer, !backendBaseURL.isEmpty else { return nil }
        return CueBackendUploadService(minioConfig: minioConfig,
                                       backendBaseURL: backendBaseURL,
                                       ownerToken: ownerToken)
    }
}
