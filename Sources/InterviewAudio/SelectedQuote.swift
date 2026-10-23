import Foundation
import AudioCore

struct QuoteSource: Codable, Equatable {
    let resourceType: String
    let resourceID: String
    let revision: Int
    var line: Int? = nil
    enum CodingKeys: String, CodingKey { case resourceType = "resource_type", resourceID = "resource_id", revision, line }
    var reference: AssistantReference { .init(resourceType: resourceType, resourceID: resourceID, revision: revision, line: line, historical: nil, blockID: nil) }
}

struct SelectedQuote: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    let text: String
    let title: String
    let location: String
    let sources: [QuoteSource]
    var recordingID: String? = nil
    var runID: String? = nil
    enum CodingKeys: String, CodingKey { case id, text, title, location, sources, recordingID = "recording_id", runID = "run_id" }

    static func document(_ item: BackendDocument, range: NSRange) -> SelectedQuote? {
        let content = item.content as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= content.length else { return nil }
        let start = content.substring(to: range.location).filter { $0 == "\n" }.count + 1
        let end = start + content.substring(with: range).filter { $0 == "\n" }.count
        return .init(text: content.substring(with: range), title: item.title, location: start == end ? "第 \(start) 行" : "第 \(start)–\(end) 行",
                     sources: [.init(resourceType: "document", resourceID: item.id, revision: item.revision, line: start)])
    }

    static func transcript(text: String, range: NSRange, ranges: [String: NSRange], segments: [TranscriptSegment],
                           title: String, recordingID: String, runID: String, revision: (String) -> Int) -> SelectedQuote? {
        let content = text as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= content.length else { return nil }
        let selected = segments.filter { segment in ranges[segment.id].map { NSIntersectionRange($0, range).length > 0 } ?? false }
        guard let first = selected.first, let last = selected.last else { return nil }
        return .init(text: content.substring(with: range), title: title, location: "\(TimeFormat.clock(first.start))–\(TimeFormat.clock(last.end))",
                     sources: selected.map { .init(resourceType: "segment", resourceID: $0.id, revision: revision($0.id)) }, recordingID: recordingID, runID: runID)
    }
}
