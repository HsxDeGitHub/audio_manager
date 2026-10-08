import Foundation
import CryptoKit

public enum TaskState: String, Codable, CaseIterable, Sendable {
    case idle, queued, preprocessing, transcribing, diarizing, completed, failed, cancelled, interrupted
    public var title: String {
        switch self {
        case .idle: return "待转写"
        case .queued: return "排队中"
        case .preprocessing: return "预处理"
        case .transcribing: return "转写中"
        case .diarizing: return "区分说话人"
        case .completed: return "已完成"
        case .failed: return "处理失败"
        case .cancelled: return "已取消"
        case .interrupted: return "任务中断，可重试"
        }
    }
    public var isRunning: Bool { [.preprocessing, .transcribing, .diarizing].contains(self) }
}

public struct Recording: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var path: String
    public var bookmark: Data?
    public var fingerprint: String
    public var duration: Double
    public var createdAt: Double
    public var state: TaskState
    public var error: String?
    public var speakerCount: Int?
    public var playPosition: Double
    public var activeRun: String?
    public init(id: String = UUID().uuidString, title: String, path: String, bookmark: Data? = nil,
                fingerprint: String, duration: Double = 0, createdAt: Double = Date().timeIntervalSince1970,
                state: TaskState = .idle, error: String? = nil, speakerCount: Int? = nil,
                playPosition: Double = 0, activeRun: String? = nil) {
        self.id = id; self.title = title; self.path = path; self.bookmark = bookmark
        self.fingerprint = fingerprint; self.duration = duration; self.createdAt = createdAt
        self.state = state; self.error = error; self.speakerCount = speakerCount
        self.playPosition = playPosition; self.activeRun = activeRun
    }
}

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var original: String
    public var edited: String?
    public var speaker: Int?
    public var speakerEdited: Bool
    public var needsReview: Bool
    public var text: String { edited ?? original }
    public var manuallyEdited: Bool { edited != nil || speakerEdited }
    public init(id: String = UUID().uuidString, start: Double, end: Double, original: String,
                edited: String? = nil, speaker: Int? = nil, speakerEdited: Bool = false, needsReview: Bool = false) {
        self.id = id; self.start = start; self.end = end; self.original = original
        self.edited = edited; self.speaker = speaker; self.speakerEdited = speakerEdited; self.needsReview = needsReview
    }
}

public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: Int
    public init(start: Double, end: Double, speaker: Int) { self.start = start; self.end = end; self.speaker = speaker }
}
public struct TranscriptRun: Identifiable, Sendable {
    public var id: String
    public var createdAt: Double
    public var hasEdits: Bool
}
public struct SearchHit: Identifiable, Sendable {
    public var id: String { segment.id }
    public var recordingID: String
    public var recordingTitle: String
    public var segment: TranscriptSegment
    public var speakerName: String
}

public struct WorkerRequest: Codable, Sendable {
    public var jobID: String
    public var recordingID: String
    public var runID: String
    public var source: String
    public var fingerprint: String
    public var toolsDirectory: String
    public var modelsDirectory: String
    public var temporaryDirectory: String
    public var speakerCount: Int?
    public var speakersOnly: Bool
    // Test-only excerpts preserve their original audio offset. The application always submits full files.
    public var excerptStart: Double?
    public var excerptDuration: Double?
    public init(jobID: String = UUID().uuidString, recordingID: String, runID: String = UUID().uuidString,
                source: String, fingerprint: String, toolsDirectory: String, modelsDirectory: String,
                temporaryDirectory: String, speakerCount: Int? = nil, speakersOnly: Bool = false,
                excerptStart: Double? = nil, excerptDuration: Double? = nil) {
        self.jobID = jobID; self.recordingID = recordingID; self.runID = runID
        self.source = source; self.fingerprint = fingerprint; self.toolsDirectory = toolsDirectory
        self.modelsDirectory = modelsDirectory; self.temporaryDirectory = temporaryDirectory
        self.speakerCount = speakerCount; self.speakersOnly = speakersOnly
        self.excerptStart = excerptStart; self.excerptDuration = excerptDuration
    }
}
public struct WorkerEvent: Codable, Sendable {
    public var jobID: String
    public var kind: String
    public var state: TaskState?
    public var progress: Double?
    public var message: String?
    public var segments: [TranscriptSegment]?
    public var turns: [SpeakerTurn]?
    public var duration: Double?
    public init(jobID: String, kind: String, state: TaskState? = nil, progress: Double? = nil,
                message: String? = nil, segments: [TranscriptSegment]? = nil, turns: [SpeakerTurn]? = nil,
                duration: Double? = nil) {
        self.jobID = jobID; self.kind = kind; self.state = state; self.progress = progress
        self.message = message; self.segments = segments; self.turns = turns; self.duration = duration
    }
}

public enum AudioError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public enum FileFingerprint {
    public static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func verify(_ url: URL, expected: String) throws {
        guard try sha256(url) == expected else { throw AudioError.message("音频内容与导入时不一致。请重新定位到原始录音，或将新文件作为新录音导入。") }
    }
}

public enum TimeFormat {
    public static func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return value >= 3600 ? String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
    public static func srt(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
    public static func seekStart(_ start: Double) -> Double { max(0, start - 1) }
}

public enum SpeakerMatcher {
    public static func assign(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        let ordered = turns.sorted { $0.start < $1.start }
        // Convert backend cluster IDs to A/B/C in order of their first appearance.
        var mapping: [Int: Int] = [:]
        for turn in ordered where mapping[turn.speaker] == nil { mapping[turn.speaker] = mapping.count }
        var cursor = 0
        return segments.sorted { $0.start < $1.start }.map { source in
            var segment = source
            guard !segment.speakerEdited else { return segment }
            while cursor < ordered.count && ordered[cursor].end <= segment.start { cursor += 1 }
            var weights: [Int: Double] = [:]
            var index = cursor
            while index < ordered.count && ordered[index].start < segment.end {
                let turn = ordered[index]
                let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
                if overlap > 0 { weights[mapping[turn.speaker]!, default: 0] += overlap }
                index += 1
            }
            let ranked = weights.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            segment.speaker = ranked.first?.key
            segment.needsReview = ranked.isEmpty || ranked.count > 1
            return segment
        }
    }
    public static func defaultName(_ speaker: Int?) -> String {
        guard let speaker else { return "未识别" }
        return speaker < 26 ? "说话人 " + String(UnicodeScalar(65 + speaker)!) : "说话人 \(speaker + 1)"
    }
}

public enum TranscriptExport {
    public static func render(title: String, segments: [TranscriptSegment], names: [Int: String], srt: Bool) -> String {
        let ordered = segments.sorted { $0.start < $1.start }
        let lines = ordered.enumerated().map { index, segment -> String in
            let name = segment.speaker.flatMap { names[$0] } ?? SpeakerMatcher.defaultName(segment.speaker)
            let text = segment.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if srt {
                // Empty lines terminate an SRT cue, so keep edited paragraphs inside one cue.
                let cue = text.split(separator: "\n", omittingEmptySubsequences: true).joined(separator: "\n")
                return "\(index + 1)\n\(TimeFormat.srt(segment.start)) --> \(TimeFormat.srt(segment.end))\n\(name)：\(cue)\n"
            }
            return "[\(TimeFormat.clock(segment.start)) – \(TimeFormat.clock(segment.end))] \(name)\n\(text)\n"
        }
        return (srt ? "" : title + "\n\n") + lines.joined(separator: "\n") + "\n"
    }
}

public enum BackendParser {
    public static func whisperJSON(_ data: Data, offset: Double = 0) throws -> [TranscriptSegment] {
        struct Offsets: Decodable { var from: Double; var to: Double }
        struct Item: Decodable { var offsets: Offsets; var text: String }
        struct Result: Decodable { var transcription: [Item] }
        let result = try JSONDecoder().decode(Result.self, from: data)
        return try result.transcription.compactMap { item in
            let start = item.offsets.from / 1000 + offset, end = item.offsets.to / 1000 + offset
            guard start.isFinite, end.isFinite, start >= 0, end >= start else { throw AudioError.message("转写返回了无效的时间戳") }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TranscriptSegment(start: start, end: end, original: text)
        }
    }
    public static func speakerOutput(_ text: String, offset: Double = 0) throws -> [SpeakerTurn] {
        let pattern = #"(?m)^\s*(\d+(?:\.\d+)?)\s*--\s*(\d+(?:\.\d+)?)\s+speaker_(\d+)\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let string = text as NSString
        let turns = regex.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match -> SpeakerTurn? in
            guard let start = Double(string.substring(with: match.range(at: 1))),
                  let end = Double(string.substring(with: match.range(at: 2))),
                  let speaker = Int(string.substring(with: match.range(at: 3))), end >= start else { return nil }
            return SpeakerTurn(start: start + offset, end: end + offset, speaker: speaker)
        }
        guard !turns.isEmpty else { throw AudioError.message("未检测到说话人。文字已保留，可调整人数后单独重试。") }
        return turns
    }
}
