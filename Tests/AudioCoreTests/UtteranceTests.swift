import Foundation
import Testing
import AudioCore

@Suite
struct UtteranceTests {
    private func sentence(_ text: String, _ start: Double, _ end: Double, _ speaker: Int? = 0) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, original: text, speaker: speaker)
    }
    @Test func shortFragmentsBecomeOneSpeechWithoutChangingAnchors() throws {
        let segments = [sentence("我们采用",0,2),sentence("数据库事务",2.1,4),sentence("保证一致性。",4,7)]
        let groups = UtteranceGrouping.make(segments)
        #expect(groups.count == 1)
        let speech = try #require(groups.first)
        #expect(speech.text == "我们采用数据库事务保证一致性。")
        #expect(speech.segments == segments)
        #expect(speech.id == segments[0].id)
        #expect(speech.start == 0 && speech.end == 7)
        #expect(speech.segments[1].start == 2.1)
    }
    @Test func speakerChangeAndLongPauseStartNewSpeech() {
        let groups = UtteranceGrouping.make([sentence("甲",0,2,0),sentence("乙",2,3,1),sentence("乙继续",3,5,1),sentence("乙再次",15,17,1)])
        #expect(groups.count == 3)
        #expect(groups[1].segments.count == 2)
        #expect(groups[2].start == 15)
    }
    @Test func unassignedFragmentsRemainReadableAndReviewFlagsSurvive() {
        var review = sentence("待确认",2,4,nil); review.needsReview = true
        let groups = UtteranceGrouping.make([sentence("开头",0,2,nil),review])
        #expect(groups.count == 1)
        #expect(groups[0].speaker == nil)
        #expect(groups[0].reviewCount == 1)
    }
    @Test func joinedTextPreservesEnglishWordSpacingAndUTF16Ranges() throws {
        let segments = [sentence("使用",0,1),sentence("REST",1,2),sentence("API",2,3),sentence("🙂接口。",3,5)]
        let joined = JoinedTranscript(segments: segments)
        #expect(joined.text == "使用REST API🙂接口。")
        let range = try #require(joined.ranges[segments[3].id])
        #expect((joined.text as NSString).substring(with: range) == "🙂接口。")
    }
    @Test func searchAcrossFragmentBoundaryReturnsOriginalStartAndContext() throws {
        let segments = [sentence("数据库",10,12),sentence("事务的原子性",12,16)]
        let hits = TranscriptSearch.find("数据库事务", utterances: UtteranceGrouping.make(segments), recordingID: "r", recordingTitle: "课程", names: [0:"讲者"])
        let hit = try #require(hits.first)
        #expect(hits.count == 1)
        #expect(hit.segment.id == segments[0].id)
        #expect(hit.segment.start == 10)
        #expect(hit.preview.contains("数据库事务"))
        #expect(hit.speakerName == "讲者")
        #expect(TranscriptSearch.find("数据库事务", utterances: UtteranceGrouping.make([sentence("数据库",0,1,0),sentence("事务",1,2,1)]), recordingID: "r", recordingTitle: "r", names: [:]).isEmpty)
    }
    @Test func multipleMatchesInOneSentenceDoNotDuplicateSearchHit() {
        let segments = [sentence("事务保障事务一致性。",0,5)]
        let hits = TranscriptSearch.find("事务", utterances: UtteranceGrouping.make(segments), recordingID: "r", recordingTitle: "r", names: [:])
        #expect(hits.count == 1)
    }
    @Test func textExportUsesSpeechParagraphsButSRTKeepsSentenceTimings() {
        let segments = [sentence("数据库",0,2),sentence("事务。",2,4),sentence("明白。",4,6,1)]
        let text = TranscriptExport.render(title: "课程", segments: segments, names: [0:"讲者",1:"听众"], srt: false)
        #expect(text.contains("[00:00 – 00:04] 讲者\n数据库事务。"))
        #expect(text.contains("[00:04 – 00:06] 听众\n明白。"))
        let srt = TranscriptExport.render(title: "课程", segments: segments, names: [:], srt: true)
        #expect(srt.contains("00:00:02,000 --> 00:00:04,000"))
        #expect(srt.contains("3\n00:00:04,000 --> 00:00:06,000"))
    }
    @Test func plainDialogueExportKeepsOrderedSpeakersAndCorrectionsWithoutMetadata() {
        var corrected = sentence("原始识别",2,4); corrected.edited = "事务。"
        let segments = [sentence("明白。",4,6,1),corrected,sentence("数据库",0,2)]
        let text = TranscriptExport.render(title: "课程标题", segments: segments, names: [0:"讲者",1:"听众"], srt: false, plainDialogue: true)
        #expect(text == "讲者：\n数据库事务。\n\n听众：\n明白。\n")
        #expect(corrected.original == "原始识别" && corrected.start == 2 && corrected.end == 4)
    }
    @Test func plainDialogueExportRespectsReadingOptionsAndSpeakerFallbacks() {
        let segments = [sentence("你好",0,1,nil),sentence("欢迎交流",1,3,nil),sentence("REST",3,4,2),sentence("API",4,5,2)]
        let plain = TranscriptExport.render(title: "访谈", segments: segments, names: [:], srt: false, punctuate: false, paragraphBreaks: false, plainDialogue: true)
        #expect(plain == "未识别：\n你好欢迎交流\n\n说话人 C：\nREST API\n")
        let decorated = TranscriptExport.render(title: "访谈", segments: segments, names: [:], srt: false, overrides: [segments[0].id:"你好！"], plainDialogue: true)
        #expect(decorated == "未识别：\n你好！欢迎交流。\n\n说话人 C：\nREST API\n")
        #expect(TranscriptExport.render(title: "访谈", segments: [], names: [:], srt: false, plainDialogue: true).isEmpty)
        #expect(TranscriptExport.render(title: "访谈", segments: segments, names: [:], srt: true, plainDialogue: true)
                == TranscriptExport.render(title: "访谈", segments: segments, names: [:], srt: true))
    }
    @Test func wholeSpeechCorrectionPreservesOriginalTextAndTimestamps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try LibraryStore(url: dir.appendingPathComponent("library.sqlite"))
        let r = Recording(title: "访谈", path: "/tmp/test.wav", fingerprint: "fixture")
        let segments = [sentence("问题",0,2),sentence("补充",2,5)]
        try db.save(r); try db.addTranscript(recordingID: r.id, runID: "run", segments: segments, duration: nil)
        try db.editTexts([segments[1].id:"补充内容"])
        try db.editSpeakers(segmentIDs: segments.map(\.id), speaker: 3)
        let saved = try db.segments(runID: "run")
        #expect(saved.allSatisfy { $0.speaker == 3 && $0.speakerEdited })
        #expect(saved[1].original == "补充" && saved[1].edited == "补充内容")
        #expect(saved[1].id == segments[1].id && saved[1].start == 2 && saved[1].end == 5)
    }
    @Test func oldPreferencesDecodeWithoutLosingModelLocation() throws {
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"modelsDirectory":"/local/models"}"#.utf8))
        #expect(preferences.modelsDirectory == "/local/models")
        #expect(preferences.readerFontSize == nil && preferences.preRoll == nil && preferences.lastRecordingID == nil)
        let updated = AppPreferences(modelsDirectory: preferences.modelsDirectory, readerFontSize: 18, preRoll: 0, lastRecordingID: "existing-recording")
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(updated))
        #expect(restored.lastRecordingID == "existing-recording" && restored.preRoll == 0 && restored.readerFontSize == 18)
    }
}
