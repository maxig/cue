import Foundation

extension JSONEncoder {
    static var cue: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var cue: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Small, atomically-written journal created before capture starts. AVFoundation
/// movie fragments make the media itself recoverable; this manifest makes an
/// interrupted folder discoverable and gives the Library enough metadata to
/// surface it on the next launch.
struct RecordingRecoveryManifest: Codable {
    let id: UUID
    let title: String
    let createdAt: Date
    let captureMode: CaptureMode
    let expectsScreen: Bool
    let expectsCamera: Bool
}

/// Persists the recording library to Application Support and resolves media
/// file URLs. Each recording owns a folder named by its UUID.
@MainActor
final class RecordingStore: ObservableObject {

    @Published private(set) var recordings: [Recording] = []

    let baseURL: URL

    init() {
        // Save to ~/Movies/Cue so recordings are easy to find in Finder.
        let movies = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        baseURL = movies.appendingPathComponent("Cue", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        Self.migrateLegacyLibraryIfNeeded(to: baseURL)
        load()
        recoverInterruptedRecordings()
    }

    /// One-time move from the old Application Support location to ~/Movies/Cue.
    private static func migrateLegacyLibraryIfNeeded(to newBase: URL) {
        let fm = FileManager.default
        guard let applicationSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldBase = applicationSupport.appendingPathComponent("Cue/Recordings", isDirectory: true)
        let oldIndex = oldBase.appendingPathComponent("index.json")
        let newIndex = newBase.appendingPathComponent("index.json")
        guard fm.fileExists(atPath: oldIndex.path), !fm.fileExists(atPath: newIndex.path) else { return }
        guard let items = try? fm.contentsOfDirectory(at: oldBase, includingPropertiesForKeys: nil) else { return }
        // Move the index last. If migration is interrupted, its continued
        // presence at the old location makes the next launch retry the move.
        for item in items.sorted(by: { ($0.lastPathComponent == "index.json" ? 1 : 0) < ($1.lastPathComponent == "index.json" ? 1 : 0) }) {
            let destination = newBase.appendingPathComponent(item.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.moveItem(at: item, to: destination)
            } catch {
                NSLog("Cue: library migration could not move \(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private var indexURL: URL { baseURL.appendingPathComponent("index.json") }
    private var backupIndexURL: URL { baseURL.appendingPathComponent("index.backup.json") }
    private static let recoveryManifestName = "recovery.json"

    func folderURL(for id: UUID) -> URL {
        let url = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func fileURL(for recording: Recording, fileName: String?) -> URL? {
        guard let fileName else { return nil }
        return folderURL(for: recording.id).appendingPathComponent(fileName)
    }

    func screenURL(for r: Recording) -> URL? { fileURL(for: r, fileName: r.screenFileName) }
    func cameraURL(for r: Recording) -> URL? { fileURL(for: r, fileName: r.cameraFileName) }
    func finalURL(for r: Recording) -> URL? { fileURL(for: r, fileName: r.finalFileName) }
    func audioURL(for r: Recording) -> URL? { fileURL(for: r, fileName: r.audioFileName) }
    func thumbnailURL(for r: Recording) -> URL? { fileURL(for: r, fileName: r.thumbnailFileName) }

    /// The primary playable/shareable file: composited output if present,
    /// otherwise the raw screen or camera track.
    func primaryMediaURL(for r: Recording) -> URL? {
        finalURL(for: r) ?? screenURL(for: r) ?? cameraURL(for: r)
    }

    func load() {
        for candidate in [indexURL, backupIndexURL] {
            guard let data = try? Data(contentsOf: candidate),
                  let items = try? JSONDecoder.cue.decode([Recording].self, from: data) else { continue }
            recordings = items.sorted { $0.createdAt > $1.createdAt }
            if candidate == backupIndexURL {
                NSLog("Cue: restored the recording index from its backup")
                // Do not rotate the corrupt primary over the known-good backup.
                try? FileManager.default.removeItem(at: indexURL)
                persist()
            }
            return
        }
        recordings = []
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            let data = try JSONEncoder.cue.encode(recordings)
            let fm = FileManager.default
            if fm.fileExists(atPath: indexURL.path) {
                try? fm.removeItem(at: backupIndexURL)
                try fm.copyItem(at: indexURL, to: backupIndexURL)
            }
            try data.write(to: indexURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            NSLog("Cue: could not persist the recording library: \(error.localizedDescription)")
            return false
        }
    }

    func beginRecoveryJournal(_ manifest: RecordingRecoveryManifest) throws {
        let data = try JSONEncoder.cue.encode(manifest)
        let url = folderURL(for: manifest.id).appendingPathComponent(Self.recoveryManifestName)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func finishRecoveryJournal(for id: UUID) {
        let url = baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(Self.recoveryManifestName)
        try? FileManager.default.removeItem(at: url)
    }

    /// Imports fragmented raw tracks left behind by an unexpected termination.
    /// The last unflushed fragment may be lost, but earlier fragments remain
    /// playable and the recording is no longer an invisible orphan on disk.
    private func recoverInterruptedRecordings() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let originalRecordings = recordings
        var recoveredManifests: [URL] = []
        for folder in folders {
            let manifestURL = folder.appendingPathComponent(Self.recoveryManifestName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder.cue.decode(RecordingRecoveryManifest.self, from: data) else { continue }
            guard folder.lastPathComponent.caseInsensitiveCompare(manifest.id.uuidString) == .orderedSame else { continue }

            if recordings.contains(where: { $0.id == manifest.id }) {
                try? fm.removeItem(at: manifestURL)
                continue
            }

            func usable(_ name: String) -> Bool {
                let url = folder.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
                return values.isRegularFile == true && (values.fileSize ?? 0) > 1_024
            }

            let screenName = manifest.expectsScreen && usable("screen.mov") ? "screen.mov" : nil
            let cameraName = manifest.expectsCamera && usable("camera.mov") ? "camera.mov" : nil
            guard screenName != nil || cameraName != nil else { continue }

            let mediaDates = [screenName, cameraName].compactMap { name -> Date? in
                guard let name else { return nil }
                return try? folder.appendingPathComponent(name)
                    .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            let approximateDuration = max(0, (mediaDates.max() ?? manifest.createdAt).timeIntervalSince(manifest.createdAt))
            recordings.append(Recording(
                id: manifest.id,
                title: "Recovered · \(manifest.title)",
                createdAt: manifest.createdAt,
                duration: approximateDuration,
                screenFileName: screenName,
                cameraFileName: cameraName,
                captureMode: manifest.captureMode,
                share: .local
            ))
            recoveredManifests.append(manifestURL)
            NSLog("Cue: recovered interrupted recording \(manifest.id.uuidString)")
        }

        if !recoveredManifests.isEmpty {
            recordings.sort { $0.createdAt > $1.createdAt }
            if persist() {
                // Keep each journal until the Library index that references its
                // files is safely on disk. A failed index write is retried next
                // launch instead of turning the recording into an orphan.
                for manifestURL in recoveredManifests {
                    try? fm.removeItem(at: manifestURL)
                }
            } else {
                recordings = originalRecordings
            }
        }
    }

    @discardableResult
    func upsert(_ recording: Recording) -> Bool {
        let originalRecordings = recordings
        if let idx = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[idx] = recording
        } else {
            recordings.append(recording)
        }
        recordings.sort { $0.createdAt > $1.createdAt }
        guard persist() else {
            recordings = originalRecordings
            return false
        }
        return true
    }

    func delete(_ recording: Recording) throws {
        let originalRecordings = recordings
        let folder = baseURL.appendingPathComponent(recording.id.uuidString, isDirectory: true)
        var trashedURL: NSURL?
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.trashItem(at: folder, resultingItemURL: &trashedURL)
        }
        recordings.removeAll { $0.id == recording.id }
        guard persist() else {
            recordings = originalRecordings
            // Roll the media move back when possible so the index and folder do
            // not diverge. If Finder cannot restore it, the file remains in Trash.
            if let trashedURL = trashedURL as URL?,
               !FileManager.default.fileExists(atPath: folder.path) {
                try? FileManager.default.moveItem(at: trashedURL, to: folder)
            }
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
