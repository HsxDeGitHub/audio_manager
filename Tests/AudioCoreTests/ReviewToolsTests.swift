import Foundation
import Testing
import AudioCore
import CSQLite

@Suite final class ReviewToolsTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    deinit { try? FileManager.default.removeItem(at: folder) }
    private var url: URL { folder.appendingPathComponent("library.sqlite") }
    private func seeded() throws -> (LibraryStore, [TranscriptSegment]) {
        let store = try LibraryStore(url: url)
        let recording = Recording(id: "r", title: "会议", path: "/audio", fingerprint: "hash", duration: 100)
        try store.save(recording)
        let segments = [
            TranscriptSegment(id: "a", start: 2, end: 7, original: "数据库事务", speaker: 0, needsReview: true),
            TranscriptSegment(id: "b", start: 8, end: 12, original: "继续讨论", speaker: 1),
            TranscriptSegment(id: "c", start: 14, end: 19, original: "回答问题", speaker: 2, needsReview: true)
        ]
        try store.addTranscript(recordingID: "r", runID: "run", segments: segments, duration: nil)
        try store.renameSpeaker(runID: "run", speaker: 0, name: "小李")
        try store.renameSpeaker(runID: "run", speaker: 1, name: "小王")
        try store.renameSpeaker(runID: "run", speaker: 2, name: "重复标签")
        return (store,segments)
    }
    @Test func mergeUndoRedoSurviveRestartAndPreserveTiming() throws {
        var (db,source) = try seeded()
        try db.mergeSpeakers(runID: "run", sources: [0,1,2], target: 0)
        #expect(try db.segments(runID: "run").allSatisfy { $0.speaker == 0 })
        #expect(try db.speakerNames(runID: "run") == [0: "小李"])
        #expect(try db.historyLabel(runID: "run") == "合并说话人")
        db = try LibraryStore(url: url)
        #expect(try db.restoreEdit(runID: "run"))
        #expect(try db.segments(runID: "run").map(\.speaker) == source.map(\.speaker))
        #expect(try db.speakerNames(runID: "run")[2] == "重复标签")
        #expect(try db.restoreEdit(runID: "run", redo: true))
        let result = try db.segments(runID: "run")
        #expect(result.map(\.id) == source.map(\.id))
        #expect(result.map(\.start) == source.map(\.start))
        #expect(result.map(\.end) == source.map(\.end))
        #expect(result.map(\.original) == source.map(\.original))
    }
    @Test func correctionsUndoAndNewBranchClearRedo() throws {
        let (db,_) = try seeded()
        try db.editTexts(["a": "缓存优化", "b": "技术方案"])
        #expect(try db.search("缓存").count == 1)
        #expect(try db.restoreEdit(runID: "run"))
        #expect(try db.search("缓存").isEmpty)
        #expect(try db.search("事务").count == 1)
        try db.editSpeaker(segmentID: "c", speaker: 1)
        #expect(try db.historyLabel(runID: "run", redo: true) == nil)
        #expect(try db.restoreEdit(runID: "run"))
        #expect(try db.segments(runID: "run")[2].speaker == 2)
    }
    @Test func reviewedStatePersistsAndCanBeReopened() throws {
        let (db,_) = try seeded()
        try db.markReviewed(segmentIDs: ["a","c"], reviewed: true)
        #expect(try db.segments(runID: "run").filter(\.pendingReview).isEmpty)
        #expect(try LibraryStore(url: url).segments(runID: "run")[0].reviewed == true)
        try db.markReviewed(segmentIDs: ["b"], reviewed: false)
        #expect(try db.segments(runID: "run")[1].pendingReview)
        #expect(try db.restoreEdit(runID: "run"))
        #expect(try db.segments(runID: "run")[1].pendingReview == false)
    }
    @Test func sentenceCorrectionAndReviewedStatusUndoAsOneAction() throws {
        let (db,_) = try seeded()
        try db.saveCorrection(segmentID: "a",text: "人工修正",markReviewed: true)
        #expect(try db.segments(runID: "run")[0].reviewed == true)
        #expect(try db.restoreEdit(runID: "run"))
        let original = try db.segments(runID: "run")[0]
        #expect(original.edited == nil)
        #expect(original.pendingReview)
    }
    @Test func verifiedSpeakerAssignmentSurvivesAutomaticRetry() throws {
        let (db,_) = try seeded()
        try db.markReviewed(segmentIDs: ["c"],reviewed: true)
        try db.applySpeakers(runID: "run",turns: [SpeakerTurn(start: 0,end: 100,speaker: 5)])
        let verified = try db.segments(runID: "run")[2]
        #expect(verified.speaker == 2)
        #expect(verified.reviewed == true)
    }
    @Test func densityAndPunctuationPreferencesRemainCompatible() throws {
        let old = try JSONDecoder().decode(AppPreferences.self,from: Data(#"{"modelsDirectory":"/Models"}"#.utf8))
        #expect(old.readingDensity == nil); #expect(old.smartPunctuation == nil)
        let preferences = AppPreferences(modelsDirectory: "/Models",readingDensity: .relaxed,librarySort: .longest,libraryFilter: .attention,smartPunctuation: false)
        let restored = try JSONDecoder().decode(AppPreferences.self,from: JSONEncoder().encode(preferences))
        #expect(restored.readingDensity == .relaxed); #expect(restored.smartPunctuation == false)
        #expect(restored.librarySort == .longest); #expect(restored.libraryFilter == .attention)
        let segments = (0..<24).map { TranscriptSegment(start: Double($0),end: Double($0+1),original: "这是一个用于验证阅读密度的完整句子。",speaker: 0) }
        let compact = ReadingTranscript(segments: segments,density: .compact).text.filter { $0 == "\n" }.count
        let relaxed = ReadingTranscript(segments: segments,density: .relaxed).text.filter { $0 == "\n" }.count
        #expect(relaxed > compact)
    }
    @Test func invalidBatchRollsBackAndHistoryIsScoped() throws {
        let (db,_) = try seeded()
        let before = try db.segments(runID: "run")
        #expect(throws: (any Error).self) { try db.editTexts(["a": "不应该保存", "missing": "错误"]) }
        #expect(try db.segments(runID: "run") == before)
        #expect(try db.restoreEdit(runID: "other") == false)
    }
    @Test func automaticSpeakerRetryInvalidatesStaleUndo() throws {
        let (db,_) = try seeded()
        try db.editText(segmentID: "a", text: "校对文字")
        try db.applySpeakers(runID: "run", turns: [SpeakerTurn(start: 0, end: 100, speaker: 3)])
        #expect(try db.historyLabel(runID: "run") == nil)
        #expect(try db.segments(runID: "run")[0].text == "校对文字")
    }
    @Test func legacySchemaMigrationKeepsTranscript() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var legacy: OpaquePointer?
        #expect(sqlite3_open(url.path, &legacy) == SQLITE_OK)
        defer { sqlite3_close(legacy) }
        let sql = """
        CREATE TABLE segments(id TEXT PRIMARY KEY,run_id TEXT,start REAL,end REAL,original TEXT,edited TEXT,speaker INTEGER,speaker_edited INTEGER DEFAULT 0,needs_review INTEGER DEFAULT 0);
        INSERT INTO segments VALUES('old','run',1,2,'旧版文字',NULL,0,0,1);
        PRAGMA user_version=1;
        """
        #expect(sqlite3_exec(legacy,sql,nil,nil,nil) == SQLITE_OK)
        let db = try LibraryStore(url: url)
        let segment = try #require(db.segments(runID: "run").first)
        #expect(segment.original == "旧版文字")
        #expect(segment.pendingReview)
        #expect(segment.reviewed == false)
    }
    @Test func libraryOrderingAndFilters() {
        let old = Recording(id: "a",title: "音频2",path: "a",fingerprint: "a",duration: 100,createdAt: 1,state: .completed)
        let new = Recording(id: "b",title: "音频10",path: "b",fingerprint: "b",duration: 50,createdAt: 2,state: .failed)
        #expect(LibraryOrdering.apply([old,new],sort: .newest,filter: .all).map(\.id) == ["b","a"])
        #expect(LibraryOrdering.apply([old,new],sort: .name,filter: .all).map(\.id) == ["a","b"])
        #expect(LibraryOrdering.apply([old,new],sort: .shortest,filter: .completed).map(\.id) == ["a"])
        #expect(LibraryOrdering.apply([old,new],sort: .longest,filter: .attention,title: "10").map(\.id) == ["b"])
    }
    @Test func playbackLoopBoundsAndSpeakerSampling() {
        #expect(PlaybackLoop(start: -1,end: 12,duration: 10) == PlaybackLoop(start: 0,end: 10,duration: 10))
        #expect(PlaybackLoop(start: 9,end: 8,duration: 10) == nil)
        #expect(PlaybackLoop(start: .nan,end: 8,duration: 10) == nil)
        let samples = (0..<10).map { TranscriptSegment(id: "\($0)",start: Double($0)*5,end: Double($0)*5+4,original: "语音",speaker: 0) }
        #expect(SpeakerSamples.select(samples,speaker: 0).map(\.id) == ["0","4","9"])
    }
    @Test func smartPunctuationLosslessProjectionAndSearch() throws {
        let segments = [TranscriptSegment(id: "a",start: 0,end: 3,original: "我们使用 AI coding 平台"),TranscriptSegment(id: "b",start: 3,end: 6,original: "实现多 agent 工作流🙂")]
        let output = "我们使用AI coding平台，实现多agent工作流🙂。"
        let projected = try #require(PunctuationProjection.project(output,onto: segments))
        #expect(projected["a"] == "我们使用 AI coding 平台，")
        let reading = ReadingTranscript(segments: segments,overrides: projected)
        let matches = reading.searchRanges(for: "平台实现")
        #expect(matches.count == 1)
        #expect((reading.text as NSString).substring(with: matches[0]) == "平台，实现")
        #expect((reading.text as NSString).substring(with: reading.searchRanges(for: "🙂")[0]) == "🙂")
        #expect(PunctuationProjection.project("我们使用别的平台。",onto: segments) == nil)
        let raw = ReadingTranscript(segments: segments,punctuate: false,overrides: projected)
        #expect(raw.text == JoinedTranscript(segments: segments).text)
    }
    @Test func localModelEvaluationPreservesWordsAndFindsInternalQuestionBoundary() throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment["INTERVIEW_PUNCTUATION_MODEL_DIR"] else { return }
        let root = URL(fileURLWithPath: modelDirectory).deletingLastPathComponent()
        let examples = [
            "你为什么选择这个方案因为它可以在本地运行不需要上传录音",
            "我们使用 AI coding 代码生成平台实现多 agent 工作流",
            "这是完整的口语回答🙂中间可能夹杂 English words"
        ]
        for (index,text) in examples.enumerated() {
            let child = Process(), output = Pipe()
            child.executableURL = root.appendingPathComponent(".runtime/tools/sherpa/bin/sherpa-onnx-offline-punctuation")
            child.arguments = ["--print-args=false", "--ct-transformer=" + URL(fileURLWithPath: modelDirectory).appendingPathComponent("punctuation.int8.onnx").path,text]
            child.standardOutput = output; child.standardError = FileHandle.nullDevice
            try child.run()
            let decorated = String(decoding: output.fileHandleForReading.readDataToEndOfFile(),as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            child.waitUntilExit(); #expect(child.terminationStatus == 0)
            let segment = TranscriptSegment(start: 10,end: 20,original: text)
            let projection = try #require(PunctuationProjection.project(decorated,onto: [segment]))
            #expect(projection[segment.id]?.filter { !PunctuationProjection.marks.contains($0) } == text)
            if index == 0 {
                #expect(projection[segment.id]?.contains("方案？因为") == true)
                #expect(!ReadingTranscript(segments: [segment]).text.contains("方案？因为"))
            }
        }
    }
    @Test func punctuationCacheInvalidatesWhenSourceOrGroupingChanges() throws {
        let (db,_) = try seeded()
        let group = try db.segments(runID: "run")[0]
        let key = PunctuationProjection.key([group])
        try db.saveReadingCache(runID: "run",key: key,rendered: [group.id:"数据库，事务。"])
        #expect(try db.search("数据库，事务",smartPunctuation: true).count == 1)
        try db.editText(segmentID: group.id,text: "新的文字")
        #expect(try db.search("数据库，事务",smartPunctuation: true).isEmpty)
        #expect(PunctuationProjection.key(try db.segments(runID: "run")) != key)
    }
}
