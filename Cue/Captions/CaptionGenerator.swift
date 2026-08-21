import Foundation
import AVFoundation
import Accelerate

/// Produces a caption track for a recording and burns it into the video.
///
/// Transcription is tried on this Mac first; if that can't run — an
/// unsupported language, no permission, no speech engine — an existing Cue
/// server transcript is used instead, so captions still work for self-hosted
/// and offline setups either way.
@MainActor
final class CaptionGenerator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case transcribing(UUID)
        case rendering(UUID)

        var recordingID: UUID? {
            switch self {
            case .idle: return nil
            case let .transcribing(id), let .rendering(id): return id
            }
        }

        /// Shown while the user waits after a recording stops.
        var title: String? {
            switch self {
            case .idle: return nil
            case .transcribing: return "Writing captions…"
            case .rendering: return "Adding captions to the video…"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    func isWorking(on id: UUID) -> Bool { phase.recordingID == id }

    /// Transcribes, saves the caption track, then re-renders the video with the
    /// captions burned in. Returns the updated recording.
    func generate(for recording: Recording,
                  style: CaptionStyle,
                  locale: Locale,
                  store: RecordingStore,
                  render: (Recording, CompositionPlan) async -> Recording?) async throws -> Recording {
        guard phase == .idle else { throw Failure.busy }
        guard var plan = recording.plan else { throw Failure.notEditable }

        phase = .transcribing(recording.id)
        defer { phase = .idle }

        let track = try await transcribe(recording, locale: locale, store: store)
        let folder = store.folderURL(for: recording.id)
        let data = try JSONEncoder.cue.encode(track)
        try data.write(to: folder.appendingPathComponent(CaptionTrack.fileName), options: .atomic)

        plan.captionsEnabled = true
        plan.captionStyle = style
        plan.captionsFileName = CaptionTrack.fileName

        phase = .rendering(recording.id)
        guard var updated = await render(recording, plan) else { throw Failure.renderFailed }

        // Keep the words with the recording too, so the library can show the
        // transcript and the server copy stays in step.
        let text = track.cues.map(\.text).joined(separator: " ")
        if !text.isEmpty, updated.transcript == nil {
            updated.transcript = text
            updated.transcriptUpdatedAt = .now
            store.upsert(updated)
        }
        return updated
    }

    /// Reads a saved caption track, if there is one.
    static func loadTrack(for recording: Recording, store: RecordingStore) -> CaptionTrack? {
        let name = recording.plan?.captionsFileName ?? CaptionTrack.fileName
        let url = store.folderURL(for: recording.id).appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.cue.decode(CaptionTrack.self, from: data)
    }

    // MARK: Transcription

    /// Loudest sample in the audio, 0…1. Used to tell "nothing was said" apart
    /// from "the microphone recorded nothing", which are very different problems
    /// for whoever has to fix them.
    private static func peakLevel(of url: URL) -> Float? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384)
        else { return nil }
        var peak: Float = 0
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            guard let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(buffer.frameLength))
                peak = max(peak, channelPeak)
            }
        }
        return peak
    }

    private func transcribe(_ recording: Recording, locale: Locale,
                            store: RecordingStore) async throws -> CaptionTrack {
        var onDeviceFailure: TranscriptionService.Failure?
        if let audioURL = store.audioURL(for: recording),
           FileManager.default.fileExists(atPath: audioURL.path) {
            do {
                let result = try await TranscriptionService.transcribe(audioURL: audioURL, locale: locale)
                let cues = CaptionCueBuilder.cues(from: result.words)
                if !cues.isEmpty {
                    return CaptionTrack(cues: cues, source: .onDevice,
                                        localeIdentifier: result.locale.identifier,
                                        generatedAt: .now)
                }
            } catch {
                NSLog("Cue on-device transcription failed: \(error)")
                onDeviceFailure = error as? TranscriptionService.Failure
            }
        }

        // Fall back to a transcript the Cue server made earlier. Its timings are
        // per sentence rather than per word, so re-cut them into short cues.
        if let vtt = recording.transcriptVTT, !vtt.isEmpty {
            let cues = CaptionCueBuilder.resegment(WebVTTParser.parse(vtt))
            if !cues.isEmpty {
                return CaptionTrack(cues: cues, source: .serverVTT,
                                    localeIdentifier: nil, generatedAt: .now)
            }
        }

        // "No speech found" would be a lie when the real problem was permission
        // or an unsupported language — say what actually stopped it.
        if let onDeviceFailure {
            switch onDeviceFailure {
            case .notAuthorized, .unsupportedLanguage:
                throw Failure.cannotTranscribe(onDeviceFailure.errorDescription ?? "")
            case .noSpeechFound, .unavailable:
                break
            }
        }
        // About -26 dB. Real speech peaks far above this even from a quiet
        // talker; a microphone that never picked up the room sits well below.
        if let audioURL = store.audioURL(for: recording),
           let peak = Self.peakLevel(of: audioURL), peak < 0.05 {
            throw Failure.silentRecording
        }
        throw Failure.noTranscript(TranscriptionService.resolve(locale) ?? locale)
    }

    enum Failure: LocalizedError {
        case busy
        case notEditable
        case noTranscript(Locale)
        case silentRecording
        case cannotTranscribe(String)
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .busy: return "Cue is already making captions for another recording."
            case .notEditable: return "Cue can't add captions to this recording — it was made before captions existed. Record a new one to use them."
            case let .noTranscript(locale):
                // Naming the language turns the commonest cause — Cue listening
                // in one language while the speaker used another — from a dead
                // end into something the user can actually act on.
                let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                return "Cue listened for \(name) and couldn't make out any speech in this recording. If you were speaking another language, choose it under Settings ▸ Captions."
            case .silentRecording: return "Your microphone didn't pick up any sound during this recording, so there was nothing to caption. Check that the right microphone is selected — Cue shows its level next to the microphone before you record."
            case let .cannotTranscribe(reason): return reason
            case .renderFailed: return "The captions were written down, but the video couldn't be updated with them."
            }
        }
    }
}
