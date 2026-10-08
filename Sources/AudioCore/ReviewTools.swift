import Foundation

public enum ReadingDensity: String, Codable, CaseIterable, Sendable {
    case compact, balanced, relaxed
    public var title: String { switch self { case .compact: return "紧凑 · 课程"; case .balanced: return "适中 · 访谈"; case .relaxed: return "舒展 · 会议" } }
    public var paragraphLimit: Int { switch self { case .compact: return 250; case .balanced: return 170; case .relaxed: return 110 } }
}
public enum ReviewFilter: String, CaseIterable {
    case all, pending, corrected
    public var title: String { switch self { case .all: return "全部发言"; case .pending: return "待核对"; case .corrected: return "已校对" } }
    public func includes(_ utterance: SpeechUtterance) -> Bool {
        switch self { case .all: return true; case .pending: return utterance.reviewCount > 0; case .corrected: return utterance.hasEdits }
    }
}
public enum LibrarySort: String, Codable, CaseIterable, Sendable {
    case newest, oldest, name, longest, shortest
    public var title: String { switch self { case .newest: return "最近导入"; case .oldest: return "最早导入"; case .name: return "音频名称"; case .longest: return "时长由长到短"; case .shortest: return "时长由短到长" } }
}
public enum LibraryFilter: String, Codable, CaseIterable, Sendable {
    case all, completed, pending, processing, attention
    public var title: String { switch self { case .all: return "全部状态"; case .completed: return "已完成"; case .pending: return "待转写"; case .processing: return "处理中"; case .attention: return "需要处理" } }
    public func includes(_ recording: Recording) -> Bool {
        switch self {
        case .all: return true
        case .completed: return recording.state == .completed
        case .pending: return recording.state == .idle
        case .processing: return recording.state.isRunning || recording.state == .queued
        case .attention: return [.failed,.cancelled,.interrupted].contains(recording.state)
        }
    }
}
public enum LibraryOrdering {
    public static func apply(_ recordings: [Recording], sort: LibrarySort, filter: LibraryFilter, title: String = "") -> [Recording] {
        recordings.filter { filter.includes($0) && (title.isEmpty || $0.title.localizedCaseInsensitiveContains(title)) }.sorted {
            if sort == .name { let order = $0.title.localizedStandardCompare($1.title); if order != .orderedSame { return order == .orderedAscending } }
            if sort == .longest || sort == .shortest, $0.duration != $1.duration { return sort == .longest ? $0.duration > $1.duration : $0.duration < $1.duration }
            if $0.createdAt != $1.createdAt { return sort == .oldest ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }
}
/// One bounded loop per sentence; seek and unload explicitly leave this mode.
public struct PlaybackLoop: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init?(start: Double, end: Double, duration: Double) {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0 else { return nil }
        self.start = max(0, start); self.end = min(duration, end)
        guard self.end - self.start >= 0.05 else { return nil }
    }
}
public enum SpeakerSamples {
    public static func select(_ segments: [TranscriptSegment], speaker: Int, limit: Int = 3) -> [TranscriptSegment] {
        let eligible = segments.filter { $0.speaker == speaker && $0.end > $0.start }.sorted { $0.start < $1.start }
        guard eligible.count > limit, limit > 1 else { return Array(eligible.prefix(max(0,limit))) }
        return (0..<limit).map { eligible[$0 * (eligible.count - 1) / (limit - 1)] }
    }
}
