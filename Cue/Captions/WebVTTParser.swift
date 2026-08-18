import Foundation

/// Minimal WebVTT reader for the transcripts the Cue server produces.
///
/// The stored `transcriptVTT` is a concatenation of Whisper's per-segment VTT
/// strings, so it often has no `WEBVTT` header and repeats cue numbering — this
/// parser tolerates both, along with `hh:mm:ss.mmm` / `mm:ss.mmm` timestamps,
/// comma decimals, cue identifiers, `NOTE` blocks and trailing cue settings.
enum WebVTTParser {

    static func parse(_ vtt: String) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var pendingText: [String] = []
        var pendingRange: (start: Double, end: Double)?

        func flush() {
            guard let range = pendingRange else { pendingText = []; return }
            let text = pendingText
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                cues.append(CaptionCue(text: strippingTags(text),
                                       start: range.start,
                                       end: max(range.end, range.start),
                                       words: nil))
            }
            pendingRange = nil
            pendingText = []
        }

        for rawLine in vtt.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("WEBVTT") || line.hasPrefix("NOTE") || line.hasPrefix("STYLE") {
                flush()
                continue
            }
            if let range = timeRange(in: line) {
                // A new timing line starts a new cue even without a blank line
                // between blocks (concatenated segment VTTs often omit them).
                flush()
                pendingRange = range
                continue
            }
            // A bare number or identifier before a timing line is a cue id.
            if pendingRange == nil { continue }
            pendingText.append(line)
        }
        flush()

        return normalize(cues)
    }

    /// Seconds from `hh:mm:ss.mmm`, `mm:ss.mmm`, or either with a comma.
    static func seconds(from timestamp: String) -> Double? {
        let cleaned = timestamp
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    // MARK: Helpers

    private static func timeRange(in line: String) -> (start: Double, end: Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let lhs = String(line[line.startIndex..<arrow.lowerBound])
        // Anything after the end timestamp is cue settings (align, position…).
        let rhs = String(line[arrow.upperBound...])
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        guard let start = seconds(from: lhs), let end = seconds(from: rhs) else { return nil }
        return (start, end)
    }

    /// Drops inline WebVTT markup (`<v Speaker>`, `<c.classname>`, `<00:01.000>`).
    private static func strippingTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "<": depth += 1
            case ">": depth = max(0, depth - 1)
            default: if depth == 0 { result.append(character) }
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Sorts, de-overlaps, and fills in missing end times so downstream code can
    /// binary-search cues safely.
    private static func normalize(_ cues: [CaptionCue]) -> [CaptionCue] {
        var sorted = cues.sorted { $0.start < $1.start }
        for index in sorted.indices {
            let next = index + 1 < sorted.count ? sorted[index + 1].start : nil
            if sorted[index].end <= sorted[index].start {
                sorted[index].end = next ?? (sorted[index].start + 2)
            }
            if let next { sorted[index].end = min(sorted[index].end, next) }
        }
        return sorted.filter { $0.end > $0.start }
    }
}
