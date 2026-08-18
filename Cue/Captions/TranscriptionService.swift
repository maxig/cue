import Foundation
import AVFoundation
import Speech

/// Turns a recording's audio sidecar into timed words, entirely on this Mac.
///
/// Captions have to work for everyone — people running Cue against MinIO or no
/// backend at all, and anyone offline — so this never talks to a server. When
/// it can't produce anything, `CaptionGenerator` falls back to a transcript the
/// Cue server made earlier.
enum TranscriptionService {

    struct Result {
        var words: [CaptionWord]
        var locale: Locale
    }

    enum Failure: LocalizedError {
        case unsupportedLanguage(Locale)
        case notAuthorized
        case noSpeechFound
        case unavailable

        var errorDescription: String? {
            switch self {
            case let .unsupportedLanguage(locale):
                let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                return "This Mac can't transcribe \(name) offline yet."
            case .notAuthorized:
                return "Cue isn't allowed to listen to your recordings, so it can't write captions. You can turn this on in System Settings, under Privacy & Security ▸ Speech Recognition."
            case .noSpeechFound:
                return "No speech was found in this recording."
            case .unavailable:
                return "Transcribing on this Mac isn't available right now."
            }
        }
    }

    /// Transcribes `audioURL`, preferring the newer speech engine when this Mac
    /// has it and falling back to the older on-device recognizer.
    static func transcribe(audioURL: URL, locale: Locale) async throws -> Result {
        if #available(macOS 26.0, *) {
            if let words = try? await analyzerTranscribe(audioURL: audioURL, locale: locale),
               !words.isEmpty {
                return Result(words: words, locale: locale)
            }
        }
        let words = try await recognizerTranscribe(audioURL: audioURL, locale: locale)
        return Result(words: words, locale: locale)
    }

    // MARK: macOS 26 — SpeechAnalyzer

    @available(macOS 26.0, *)
    private static func analyzerTranscribe(audioURL: URL, locale: Locale) async throws -> [CaptionWord] {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupportedLanguage(locale)
        }

        let transcriber = SpeechTranscriber(locale: supported,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        // The language model may not be downloaded yet. Ask for it, but don't
        // block a caption job on a download — the older recognizer can carry
        // this recording while the assets arrive.
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                throw Failure.unsupportedLanguage(locale)
            }
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: audioURL)

        let collected = Task {
            var words: [CaptionWord] = []
            for try await result in transcriber.results {
                words.append(contentsOf: self.words(in: result.text))
            }
            return words
        }
        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collected.cancel()
            throw error
        }
        let words = try await collected.value
        guard !words.isEmpty else { throw Failure.noSpeechFound }
        return words
    }

    /// Pulls timed words out of a transcription result. A run can cover more
    /// than one word, so multi-word runs are split across their own span.
    @available(macOS 26.0, *)
    private static func words(in text: AttributedString) -> [CaptionWord] {
        var result: [CaptionWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let start = range.start.seconds
            let end = max(start, range.end.seconds)
            guard start.isFinite, end.isFinite else { continue }

            let pieces = piece.split(whereSeparator: \.isWhitespace).map(String.init)
            if pieces.count <= 1 {
                result.append(CaptionWord(text: piece, start: start, end: end))
                continue
            }
            let cue = CaptionCue(text: piece, start: start, end: end, words: nil)
            result.append(contentsOf: CaptionCueBuilder.interpolatedWords(in: cue))
        }
        return result
    }

    // MARK: macOS 15 — SFSpeechRecognizer

    private static func recognizerTranscribe(audioURL: URL, locale: Locale) async throws -> [CaptionWord] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw Failure.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw Failure.unsupportedLanguage(locale)
        }
        guard recognizer.supportsOnDeviceRecognition else { throw Failure.unsupportedLanguage(locale) }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        if #available(macOS 13.0, *) { request.addsPunctuation = true }

        let duration = (try? await AVURLAsset(url: audioURL).load(.duration).seconds) ?? 0
        let timeout = max(60, duration * 2)

        let words = try await withThrowingTaskGroup(of: [CaptionWord].self) { group in
            group.addTask { try await recognize(request: request, using: recognizer) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failure.unavailable
            }
            guard let first = try await group.next() else { throw Failure.unavailable }
            group.cancelAll()
            return first
        }
        guard !words.isEmpty else { throw Failure.noSpeechFound }
        return words
    }

    private static func recognize(request: SFSpeechURLRecognitionRequest,
                                  using recognizer: SFSpeechRecognizer) async throws -> [CaptionWord] {
        try await withCheckedThrowingContinuation { continuation in
            let box = ResumeOnce()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    box.resume { continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                let words = result.bestTranscription.segments.compactMap { segment -> CaptionWord? in
                    let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return CaptionWord(text: text,
                                       start: segment.timestamp,
                                       end: segment.timestamp + max(segment.duration, 0.08))
                }
                box.resume { continuation.resume(returning: words) }
            }
        }
    }

    /// The recognition callback can fire more than once; a continuation may
    /// only be resumed once.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func resume(_ body: () -> Void) {
            lock.lock()
            let shouldRun = !done
            done = true
            lock.unlock()
            if shouldRun { body() }
        }
    }
}
