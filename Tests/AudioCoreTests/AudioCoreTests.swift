import Foundation
import Testing
import AudioCore

@Suite
final class AudioCoreTests {
    private let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    private func store() throws -> LibraryStore { try LibraryStore(url: directory.appendingPathComponent("library.sqlite")) }
    private func recording(_ title: String = "中文面试") -> Recording {
        Recording(title: title, path: directory.appendingPathComponent("original.mp3").path, fingerprint: "test", duration: 4000)
    }
    @Test func testWhisperMillisecondsAndExcerptOffset() throws {
        let json = #"{"transcription":[{"offsets":{"from":3600120,"to":3602540},"text":"  介绍一下项目。 "}]}"#
        let segment = try #require(BackendParser.whisperJSON(Data(json.utf8), offset: 90).first)
        #expect(abs((segment.start) - (3690.12)) <= 0.0001)
        #expect(abs((segment.end) - (3692.54)) <= 0.0001)
        #expect((segment.original) == ("介绍一下项目。"))
        #expect(abs((TimeFormat.seekStart(segment.start)) - (3689.12)) <= 0.0001)
    }
    @Test func testInvalidBackendTimestampsAreRejected() throws {
        let json = #"{"transcription":[{"offsets":{"from":3000,"to":2000},"text":"错误"}]}"#
        #expect(throws: (any Error).self) { try BackendParser.whisperJSON(Data(json.utf8)) }
    }
    @Test func testSpeakerParserWithDiagnosticsAndOffsets() throws {
        let output = "Started\n  0.318 -- 6.865 speaker_02\n7.017 -- 10.747 speaker_01\nDuration : 11.0 s\n"
        let turns = try BackendParser.speakerOutput(output, offset: 3600)
        #expect((turns.count) == (2))
        #expect(abs((turns[0].start) - (3600.318)) <= 0.0001)
        #expect((turns[0].speaker) == (2))
        #expect(throws: (any Error).self) { try BackendParser.speakerOutput("no speakers") }
    }
    @Test func testSpeakerBoundaryIsFlaggedWithoutSplittingText() {
        let original = TranscriptSegment(start: 0, end: 10, original: "一个完整片段")
        let result = SpeakerMatcher.assign([original], turns: [
            SpeakerTurn(start: 0, end: 6, speaker: 8), SpeakerTurn(start: 6, end: 10, speaker: 3)
        ])
        #expect((result.count) == (1))
        #expect((result[0].original) == (original.original))
        #expect((result[0].speaker) == (0))
        #expect(result[0].needsReview)
        #expect((result[0].end) == (10))
    }
    @Test func testManualSpeakerCorrectionSurvivesRetry() {
        let original = TranscriptSegment(start: 0, end: 10, original: "手动归属", speaker: 5, speakerEdited: true)
        let result = SpeakerMatcher.assign([original], turns: [SpeakerTurn(start: 0, end: 10, speaker: 0)])
        #expect((result[0].speaker) == (5))
    }
    @Test func testNoSpeechOverlapMarkedForReview() {
        let result = SpeakerMatcher.assign([TranscriptSegment(start: 10, end: 15, original: "间隙")], turns: [SpeakerTurn(start: 0, end: 5, speaker: 0)])
        #expect((result[0].speaker) == nil); #expect(result[0].needsReview)
    }
    @Test func testSRTFormattingRoundingAndEditedParagraphs() {
        #expect((TimeFormat.srt(3599.9996)) == ("01:00:00,000"))
        #expect((TimeFormat.clock(3700)) == ("01:01:40"))
        #expect((TimeFormat.seekStart(0.2)) == (0))
        let segment = TranscriptSegment(start: 3600.12, end: 3602.54, original: "原稿", edited: "修正\n\n第二行", speaker: 0)
        let output = TranscriptExport.render(title: "面试", segments: [segment], names: [0: "候选人"], srt: true)
        #expect(output.contains("01:00:00,120 --> 01:00:02,540"))
        #expect(output.contains("候选人：修正\n第二行"))
        #expect(!(output.contains("原稿")))
    }
    @Test func testUnicodeSearchLiteralCharactersAndCorrection() throws {
        let db = try store(), r = recording()
        try db.save(r)
        let segment = TranscriptSegment(start: 10, end: 20, original: "缓存命中率为 95%_，使用 Swift")
        try db.addTranscript(recordingID: r.id, runID: "run", segments: [segment], duration: nil)
        #expect((try db.search("缓").count) == (1))
        #expect((try db.search("%_").count) == (1))
        #expect((try db.search("SWIFT").count) == (1))
        #expect((try db.search("' OR 1=1 --").count) == (0))
        try db.editText(segmentID: segment.id, text: "数据库事务")
        #expect((try db.search("缓存").count) == (0))
        #expect((try db.search("事务").count) == (1))
        #expect((try db.segments(runID: "run")[0].original) == (segment.original))
    }
    @Test func testSearchAcrossRecordingsAndCurrentScope() throws {
        let db = try store(), a = recording("甲面试"), b = recording("乙面试")
        try db.save(a); try db.save(b)
        try db.addTranscript(recordingID: a.id, runID: "a", segments: [TranscriptSegment(start: 2, end: 3, original: "数据库")], duration: nil)
        try db.addTranscript(recordingID: b.id, runID: "b", segments: [TranscriptSegment(start: 80, end: 90, original: "数据库")], duration: nil)
        #expect((try db.search("数据库").count) == (2))
        let local = try db.search("数据库", recordingID: b.id)
        #expect((local.count) == (1)); #expect((local[0].segment.start) == (80))
    }
    @Test func testRerunKeepsEditedActiveRevision() throws {
        let db = try store(), r = recording()
        try db.save(r)
        let old = TranscriptSegment(start: 2, end: 3, original: "原始")
        #expect(try db.addTranscript(recordingID: r.id, runID: "old", segments: [old], duration: nil))
        try db.editText(segmentID: old.id, text: "人工修正")
        #expect(!(try db.addTranscript(recordingID: r.id, runID: "new", segments: [TranscriptSegment(start: 2, end: 3, original: "新识别")], duration: nil)))
        #expect((try db.recordings()[0].activeRun) == ("old"))
        #expect((try db.search("人工修正").count) == (1))
        #expect((try db.search("新识别").count) == (0))
        #expect((try db.runs(recordingID: r.id).count) == (2))
    }
    @Test func testDiarizationRetryKeepsNamesAndManualAssignment() throws {
        let db = try store(), r = recording()
        try db.save(r)
        let a = TranscriptSegment(start: 0, end: 5, original: "第一句")
        let b = TranscriptSegment(start: 5, end: 10, original: "第二句")
        try db.addTranscript(recordingID: r.id, runID: "run", segments: [a,b], duration: nil)
        try db.applySpeakers(runID: "run", turns: [SpeakerTurn(start: 0, end: 10, speaker: 7)])
        try db.renameSpeaker(runID: "run", speaker: 0, name: "面试官")
        try db.editSpeaker(segmentID: b.id, speaker: 3)
        try db.applySpeakers(runID: "run", turns: [SpeakerTurn(start: 0, end: 10, speaker: 1)])
        #expect((try db.speakerNames(runID: "run")[0]) == ("面试官"))
        #expect((try db.segments(runID: "run")[1].speaker) == (3))
    }
    @Test func testSpeakerRenameProtectsActiveRevision() throws {
        let db = try store(), r = recording()
        try db.save(r)
        let segment = TranscriptSegment(start: 0, end: 5, original: "内容")
        try db.addTranscript(recordingID: r.id, runID: "old", segments: [segment], duration: nil)
        try db.applySpeakers(runID: "old", turns: [SpeakerTurn(start: 0, end: 5, speaker: 0)])
        try db.renameSpeaker(runID: "old", speaker: 0, name: "候选人")
        #expect(!(try db.addTranscript(recordingID: r.id, runID: "new", segments: [TranscriptSegment(start: 0, end: 5, original: "新内容")], duration: nil)))
        #expect((try db.recordings()[0].activeRun) == "old")
        #expect(try db.runs(recordingID: r.id).first(where: { $0.id == "old" })?.hasEdits == true)
    }
    @Test func testInterruptedStateRecoversAndTranscriptPersists() throws {
        var db: LibraryStore? = try store()
        var r = recording(); r.state = .diarizing
        try db!.save(r)
        try db!.addTranscript(recordingID: r.id, runID: "run", segments: [TranscriptSegment(start: 2, end: 3, original: "已经转写")], duration: nil)
        db = nil
        let reopened = try store()
        #expect((try reopened.recordings()[0].state) == (.interrupted))
        #expect((try reopened.search("已经转写").count) == (1))
    }
    @Test func testDeleteOnlyRemovesLibraryRecords() throws {
        let db = try store(), r = recording()
        let audio = URL(fileURLWithPath: r.path); try Data("original".utf8).write(to: audio)
        try db.save(r)
        try db.addTranscript(recordingID: r.id, runID: "run", segments: [TranscriptSegment(start: 0, end: 1, original: "内容")], duration: nil)
        try db.remove(r.id)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(try db.recordings().isEmpty)
        #expect(try db.segments(runID: "run").isEmpty)
    }
    @Test func testFileRelocationRequiresIdenticalContents() throws {
        let original = directory.appendingPathComponent("original"), moved = directory.appendingPathComponent("moved")
        try Data("面试音频".utf8).write(to: original)
        let hash = try FileFingerprint.sha256(original)
        try FileManager.default.moveItem(at: original, to: moved)
        #expect(throws: Never.self) { try FileFingerprint.verify(moved, expected: hash) }
        try Data("不同的内容".utf8).write(to: moved)
        #expect(throws: (any Error).self) { try FileFingerprint.verify(moved, expected: hash) }
    }
}
