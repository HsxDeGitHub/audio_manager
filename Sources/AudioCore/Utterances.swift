import Foundation

/// Reading groups only: original segment IDs, text edits, and timing anchors remain intact.
public struct SpeechUtterance: Identifiable, Sendable {
    public var segments: [TranscriptSegment]
    public var id: String { segments[0].id }
    public var speaker: Int? { segments[0].speaker }
    public var start: Double { segments[0].start }
    public var end: Double { segments.map(\.end).max() ?? start }
    public var reviewCount: Int { segments.filter(\.needsReview).count }
    public var hasEdits: Bool { segments.contains(where: \.manuallyEdited) }
    public var text: String { JoinedTranscript(segments: segments).text }
}

public enum UtteranceGrouping {
    public static func make(_ segments: [TranscriptSegment], maximumPause: Double = 8) -> [SpeechUtterance] {
        let ordered = segments.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var groups: [SpeechUtterance] = []
        for segment in ordered {
            if let previous = groups.last?.segments.last,
               previous.speaker == segment.speaker, segment.start - previous.end <= maximumPause {
                groups[groups.count - 1].segments.append(segment)
            } else { groups.append(SpeechUtterance(segments: [segment])) }
        }
        return groups
    }
}

/// Text and UTF-16 ranges used both by the native clickable paragraph and boundary-aware search.
public struct JoinedTranscript: Sendable {
    public let text: String
    public let ranges: [String: NSRange]
    public init(segments: [TranscriptSegment]) {
        var value = "", offsets: [String: NSRange] = [:]
        for segment in segments {
            let next = segment.text
            if let last = value.last, let first = next.first,
               last.isASCIIWordCharacter, first.isASCIIWordCharacter { value += " " }
            let start = (value as NSString).length
            value += next
            offsets[segment.id] = NSRange(location: start, length: (next as NSString).length)
        }
        text = value; ranges = offsets
    }
}
private extension Character {
    var isASCIIWordCharacter: Bool { unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) } }
}

public enum TranscriptSearch {
    public static func find(_ term: String, utterances: [SpeechUtterance], recordingID: String,
                            recordingTitle: String, names: [Int: String]) -> [SearchHit] {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var hits: [SearchHit] = []
        for utterance in utterances {
            let joined = JoinedTranscript(segments: utterance.segments)
            let text = joined.text as NSString
            var remaining = NSRange(location: 0, length: text.length), seen: Set<String> = []
            while remaining.length > 0 {
                let match = text.range(of: term, options: [.caseInsensitive], range: remaining)
                if match.location == NSNotFound { break }
                if let segment = utterance.segments.first(where: {
                    joined.ranges[$0.id].map { NSIntersectionRange($0, match).length > 0 } ?? false
                }), seen.insert(segment.id).inserted {
                    let before = max(0, match.location - 35), after = min(text.length, NSMaxRange(match) + 70)
                    // Respect composed-character boundaries when clipping Chinese/emoji snippets.
                    let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: before, length: after - before))
                    let preview = (before > 0 ? "…" : "") + text.substring(with: range) + (after < text.length ? "…" : "")
                    hits.append(SearchHit(recordingID: recordingID, recordingTitle: recordingTitle, segment: segment,
                                          speakerName: segment.speaker.flatMap { names[$0] } ?? SpeakerMatcher.defaultName(segment.speaker),
                                          preview: preview))
                }
                let next = NSMaxRange(match)
                remaining = NSRange(location: next, length: text.length - next)
            }
        }
        return hits
    }
}

public struct AppPreferences: Codable, Sendable {
    public var modelsDirectory: String
    public var readerFontSize: Double?
    public var preRoll: Double?
    public var lastRecordingID: String?
    public init(modelsDirectory: String, readerFontSize: Double? = nil, preRoll: Double? = nil, lastRecordingID: String? = nil) {
        self.modelsDirectory = modelsDirectory; self.readerFontSize = readerFontSize
        self.preRoll = preRoll; self.lastRecordingID = lastRecordingID
    }
}
