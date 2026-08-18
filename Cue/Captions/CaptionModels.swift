import Foundation
import AppKit

/// One spoken word with its timing. Times are content-timeline seconds — the
/// same clock the compositor renders on (lead-in trimmed, pauses excised).
struct CaptionWord: Codable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

/// One on-screen caption. `words` is present when the transcriber gave
/// word-level timings, and drives the karaoke style.
struct CaptionCue: Codable, Hashable {
    var text: String
    var start: Double
    var end: Double
    var words: [CaptionWord]?

    func contains(_ time: Double) -> Bool { time >= start && time < end }
}

/// Where a caption track came from, so the UI can say so and a stale
/// server-derived track can be regenerated on device later.
enum CaptionSource: String, Codable {
    case onDevice
    case serverVTT

    var title: String {
        switch self {
        case .onDevice: return "Transcribed on this Mac"
        case .serverVTT: return "From the Cue server transcript"
        }
    }
}

/// The full caption track for a recording, stored as a `captions.json` sidecar
/// in the recording's folder (like `activity.json`) so the library index stays
/// small.
struct CaptionTrack: Codable, Hashable {
    var cues: [CaptionCue]
    var source: CaptionSource
    var localeIdentifier: String?
    var generatedAt: Date

    static let fileName = "captions.json"
}

/// Visual presets for burned-in captions.
enum CaptionStyle: String, CaseIterable, Identifiable, Codable {
    case boldOutline
    case highlightBox
    case minimal
    case popWord

    var id: String { rawValue }

    var title: String {
        switch self {
        case .boldOutline: return "Bold"
        case .highlightBox: return "Highlight"
        case .minimal: return "Minimal"
        case .popWord: return "Pop"
        }
    }

    var detail: String {
        switch self {
        case .boldOutline: return "Heavy white text with a dark outline."
        case .highlightBox: return "Dark text on a yellow block."
        case .minimal: return "Small white text on a soft dark pill."
        case .popWord: return "Each word lights up as it's spoken."
        }
    }

    /// Whether this style highlights the word currently being spoken, which
    /// needs per-word timings (interpolated when the source has none).
    var highlightsSpokenWord: Bool { self == .popWord }

    var spec: CaptionStyleSpec {
        switch self {
        case .boldOutline:
            return CaptionStyleSpec(
                weight: .heavy, rounded: true, sizeFactor: 0.068, uppercase: false,
                textColor: .white,
                strokeColor: NSColor(white: 0.02, alpha: 1), strokeFraction: 0.045,
                shadow: true,
                boxColor: nil, boxCornerFraction: 0, boxPaddingFraction: .zero,
                highlightColor: nil, highlightScale: 1)
        case .highlightBox:
            return CaptionStyleSpec(
                weight: .bold, rounded: false, sizeFactor: 0.060, uppercase: false,
                textColor: NSColor(white: 0.06, alpha: 1),
                strokeColor: nil, strokeFraction: 0,
                shadow: false,
                boxColor: NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 1),
                boxCornerFraction: 0.22, boxPaddingFraction: CGSize(width: 0.34, height: 0.16),
                highlightColor: nil, highlightScale: 1)
        case .minimal:
            return CaptionStyleSpec(
                weight: .medium, rounded: false, sizeFactor: 0.048, uppercase: false,
                textColor: .white,
                strokeColor: nil, strokeFraction: 0,
                shadow: false,
                boxColor: NSColor(white: 0, alpha: 0.55),
                boxCornerFraction: 0.5, boxPaddingFraction: CGSize(width: 0.45, height: 0.22),
                highlightColor: nil, highlightScale: 1)
        case .popWord:
            return CaptionStyleSpec(
                weight: .heavy, rounded: true, sizeFactor: 0.072, uppercase: true,
                textColor: .white,
                strokeColor: NSColor(white: 0.02, alpha: 1), strokeFraction: 0.045,
                shadow: true,
                boxColor: nil, boxCornerFraction: 0, boxPaddingFraction: .zero,
                highlightColor: NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 1),
                highlightScale: 1.12)
        }
    }
}

/// Drawing parameters for a `CaptionStyle`, shared by the video renderer and
/// the settings preview so a preset always looks the same in both.
struct CaptionStyleSpec {
    var weight: NSFont.Weight
    var rounded: Bool
    /// Font size as a fraction of the frame's shorter edge.
    var sizeFactor: CGFloat
    var uppercase: Bool
    var textColor: NSColor
    var strokeColor: NSColor?
    /// Outline width as a fraction of the font size.
    var strokeFraction: CGFloat
    var shadow: Bool
    var boxColor: NSColor?
    /// Box corner radius as a fraction of the font size.
    var boxCornerFraction: CGFloat
    /// Box padding as a fraction of the font size (width = horizontal).
    var boxPaddingFraction: CGSize
    var highlightColor: NSColor?
    var highlightScale: CGFloat

    func font(ofSize size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard rounded,
              let descriptor = base.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }
}

/// Turns a stream of timed words into short, readable caption cues.
enum CaptionCueBuilder {
    /// Short-form captions want 2–5 word phrases that land in step with speech,
    /// not the long reading lines a transcript view uses.
    private static let maxCharacters = 32
    private static let maxDuration = 3.5
    private static let gapBreak = 0.6
    private static let minDuration = 0.25

    static func cues(from words: [CaptionWord]) -> [CaptionCue] {
        let words = words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !words.isEmpty else { return [] }

        var cues: [CaptionCue] = []
        var group: [CaptionWord] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let text = group.map(\.text).joined(separator: " ")
            cues.append(CaptionCue(text: text,
                                   start: first.start,
                                   end: max(last.end, first.start + minDuration),
                                   words: group))
            group = []
        }

        for word in words {
            if let previous = group.last {
                let characters = group.reduce(0) { $0 + $1.text.count + 1 } + word.text.count
                let span = word.end - (group.first?.start ?? word.start)
                let gap = word.start - previous.end
                if characters > maxCharacters || span > maxDuration || gap > gapBreak
                    || endsSentence(previous.text) {
                    flush()
                }
            }
            group.append(word)
        }
        flush()

        return tidy(cues)
    }

    /// Splits long transcript segments (Whisper's VTT runs 5–15s) into
    /// short-form cues by interpolating word timings across the segment.
    static func resegment(_ cues: [CaptionCue]) -> [CaptionCue] {
        let words = cues.flatMap { $0.words ?? interpolatedWords(in: $0) }
        return self.cues(from: words)
    }

    /// Spreads a cue's words across its duration proportionally to their
    /// length. Used when the source only gave segment timings but a style
    /// needs to highlight individual words.
    static func interpolatedWords(in cue: CaptionCue) -> [CaptionWord] {
        let pieces = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !pieces.isEmpty else { return [] }
        let total = Double(pieces.reduce(0) { $0 + max(1, $1.count) })
        let span = max(cue.end - cue.start, minDuration)
        var cursor = cue.start
        return pieces.map { piece in
            let share = span * Double(max(1, piece.count)) / total
            let word = CaptionWord(text: piece, start: cursor, end: cursor + share)
            cursor += share
            return word
        }
    }

    // MARK: Helpers

    /// Merges away scraps and makes sure cues never overlap — the renderer
    /// binary-searches on the assumption that they're sorted and disjoint.
    private static func tidy(_ cues: [CaptionCue]) -> [CaptionCue] {
        var result: [CaptionCue] = []
        for cue in cues {
            if var previous = result.last,
               cue.end - cue.start < minDuration,
               previous.end - previous.start + (cue.end - cue.start) < maxDuration {
                previous.text += " " + cue.text
                previous.end = cue.end
                previous.words = (previous.words ?? []) + (cue.words ?? [])
                result[result.count - 1] = previous
                continue
            }
            result.append(cue)
        }
        for index in result.indices.dropLast() {
            result[index].end = min(result[index].end, result[index + 1].start)
        }
        return result.filter { $0.end > $0.start }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?…".contains(last)
    }
}
