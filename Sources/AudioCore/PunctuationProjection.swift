import Foundation
import CryptoKit

/// Accept only punctuation insertions. A backend changing a word is rejected wholesale.
public enum PunctuationProjection {
    public static let marks = Set("，。？！、：；,.?!:;")
    public static func key(_ segments: [TranscriptSegment]) -> String {
        let value = segments.map { "\($0.id)\u{0}\($0.speaker ?? -1)\u{0}\($0.text)" }.joined(separator: "\u{1}")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func eligible(_ segments: [TranscriptSegment]) -> Bool {
        let input = JoinedTranscript(segments: segments).text
        return !segments.isEmpty && !segments.contains { $0.edited != nil }
            && input.count <= 4000 && !input.contains { marks.contains($0) }
            && input.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
    }
    public static func project(_ output: String, onto segments: [TranscriptSegment]) -> [String: String]? {
        guard eligible(segments) else { return nil }
        let input = JoinedTranscript(segments: segments).text
        let source = input.filter { !$0.isWhitespace }
        guard output.filter({ !$0.isWhitespace && !marks.contains($0) }) == source else { return nil }
        var additions: [Int: String] = [:], consumed = 0
        for character in output {
            if marks.contains(character) { additions[consumed, default: ""].append(character) }
            else if !character.isWhitespace { consumed += 1 }
        }
        consumed = 0
        var result: [String: String] = [:]
        for segment in segments {
            var value = ""
            for character in segment.text {
                value.append(character)
                if !character.isWhitespace {
                    consumed += 1
                    if let marks = additions[consumed] { value += marks }
                }
            }
            result[segment.id] = value
        }
        return result
    }
    /// Source UTF-16 code units map to matching display code units, including emoji surrogate pairs.
    static func positions(source: String, display: String) -> [Int] {
        let raw = Array(source.utf16), rendered = Array(display.utf16)
        let punctuation = Set("，。？！、：；,.?!:;".utf16)
        var positions: [Int] = [], i = 0, j = 0
        while i < raw.count {
            while j < rendered.count, raw[i] != rendered[j], punctuation.contains(rendered[j]) { j += 1 }
            positions.append(min(j, rendered.count))
            i += 1; j += 1
        }
        return positions
    }
}
