import Foundation
import CryptoKit

// 仅用于读取、迁移和导出旧版本整理稿；新整理直接修订正文。
public enum AIOrganizationMode: String, Codable, CaseIterable, Sendable {
    case dialogue, topics, summary
    public var title: String {
        switch self { case .dialogue: return "完整对话整理"; case .topics: return "按主题整理"; case .summary: return "摘要提炼" }
    }
}

public struct AISource: Codable, Equatable, Sendable {
    public var id: String
    public var reference: String
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public static func snapshot(segments: [TranscriptSegment], names: [Int: String]) -> [AISource] {
        segments.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }.enumerated().map { i, segment in
            AISource(id: segment.id, reference: "S\(i + 1)", start: segment.start, end: segment.end,
                     speaker: segment.speaker.flatMap { names[$0] } ?? SpeakerMatcher.defaultName(segment.speaker), text: segment.text)
        }
    }
    public static func fingerprint(_ sources: [AISource]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(sources)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AIBlock: Codable, Identifiable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var title: String
    public var text: String
    public var sourceIDs: [String]
    public init(title: String, text: String, sourceIDs: [String]) { self.title = title; self.text = text; self.sourceIDs = sourceIDs }
}

public struct AIChunk: Codable, Sendable {
    public var sources: [AISource]
    public var context: [AISource]
    public var blocks: [AIBlock]?
}

public enum AIDraftState: String, Codable, Sendable {
    case running, interrupted, failed, cancelled, completed
    public var title: String {
        switch self {
        case .running: return "整理中"
        case .interrupted: return "已中断，可继续"
        case .failed: return "失败，可重试"
        case .cancelled: return "已取消，可继续"
        case .completed: return "已完成"
        }
    }
}

public struct AIDraft: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var runID: String
    public var recordingID: String
    public var recordingTitle: String
    public var createdAt = Date().timeIntervalSince1970
    public var endpoint: String
    public var model: String
    public var mode: AIOrganizationMode
    public var instructions: String
    public var sources: [AISource]
    public var sourceHash: String
    public var chunks: [AIChunk]
    public var state: AIDraftState = .running
    public var error: String?
    public var completedChunks: Int { chunks.filter { $0.blocks != nil }.count }
    public var blocks: [AIBlock] { chunks.flatMap { $0.blocks ?? [] } }
    public init(runID: String, recordingID: String, title: String, settings: AISettings, mode: AIOrganizationMode,
                instructions: String, sources: [AISource]) throws {
        try settings.validate()
        guard (500...12000).contains(settings.chunkCharacters) else { throw AudioError.message("旧稿分块字数超出兼容范围。") }
        guard !sources.isEmpty else { throw AudioError.message("当前没有可整理的转写文字。") }
        self.runID = runID; self.recordingID = recordingID; recordingTitle = title
        endpoint = try settings.endpoint().absoluteString; model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mode = mode; self.instructions = instructions; self.sources = sources
        sourceHash = AISource.fingerprint(sources)
        chunks = Self.partition(sources, limit: settings.chunkCharacters)
    }
    private static func partition(_ sources: [AISource], limit: Int) -> [AIChunk] {
        // An unusually long ASR segment is split without losing any text or its audio anchor.
        var pieces: [AISource] = []
        for source in sources {
            var remainder = source.text[...]
            repeat {
                let boundary = remainder.index(remainder.startIndex, offsetBy: min(limit, remainder.count))
                var piece = source; piece.text = String(remainder[..<boundary]); pieces.append(piece)
                remainder = remainder[boundary...]
            } while !remainder.isEmpty
        }
        var chunks: [AIChunk] = [], current: [AISource] = [], size = 0
        for piece in pieces {
            // Bound metadata overhead too, since ASR can produce hundreds of tiny segments.
            if !current.isEmpty && (size + piece.text.count > limit || current.count >= 60) {
                chunks.append(AIChunk(sources: current, context: [], blocks: nil)); current = []; size = 0
            }
            current.append(piece); size += piece.text.count
        }
        if !current.isEmpty { chunks.append(AIChunk(sources: current, context: [], blocks: nil)) }
        for i in chunks.indices where i > 0 {
            var previous = Array(chunks[i - 1].sources.suffix(2))
            for j in previous.indices { previous[j].text = String(previous[j].text.suffix(600)) }
            chunks[i].context = previous
        }
        return chunks
    }
    public func export(markdown: Bool) -> String {
        let heading = markdown ? "# " : ""
        let status = state == .completed ? "" : "（未完成，\(completedChunks)/\(chunks.count) 块）"
        let body = blocks.map { block in
            (block.title.isEmpty ? "" : (markdown ? "## " : "") + block.title + "\n\n") + block.text
        }.joined(separator: "\n\n")
        return "\(heading)\(recordingTitle) · \(mode.title)\(status)\n\n\(body)\n"
    }
}

