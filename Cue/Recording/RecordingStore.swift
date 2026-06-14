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

/// Persists the recording library to Application Support and resolves media
/// file URLs. Each recording owns a folder named by its UUID.
@MainActor
final class RecordingStore: ObservableObject {

    @Published private(set) var recordings: [Recording] = []

    let baseURL: URL

    init() {
        // Save to ~/Movies/Cue so recordings are easy to find in Finder.
        let movies = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask).first!
        baseURL = movies.appendingPathComponent("Cue", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        Self.migrateLegacyLibraryIfNeeded(to: baseURL)
        load()
    }

    /// One-time move from the old Application Support location to ~/Movies/Cue.
    private static func migrateLegacyLibraryIfNeeded(to newBase: URL) {
        let fm = FileManager.default
        let oldBase = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Cue/Recordings", isDirectory: true)
        let oldIndex = oldBase.appendingPathComponent("index.json")
        let newIndex = newBase.appendingPathComponent("index.json")
        guard fm.fileExists(atPath: oldIndex.path), !fm.fileExists(atPath: newIndex.path) else { return }
        guard let items = try? fm.contentsOfDirectory(at: oldBase, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let destination = newBase.appendingPathComponent(item.lastPathComponent)
            try? fm.moveItem(at: item, to: destination)
        }
    }

    private var indexURL: URL { baseURL.appendingPathComponent("index.json") }

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
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder.cue.decode([Recording].self, from: data) else {
            recordings = []
            return
        }
        recordings = items.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        if let data = try? JSONEncoder.cue.encode(recordings) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func upsert(_ recording: Recording) {
        if let idx = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[idx] = recording
        } else {
            recordings.append(recording)
        }
        recordings.sort { $0.createdAt > $1.createdAt }
        persist()
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: folderURL(for: recording.id))
        recordings.removeAll { $0.id == recording.id }
        persist()
    }
}
