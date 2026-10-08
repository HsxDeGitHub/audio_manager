import Foundation
import Testing
import AudioCore

@Suite
struct ReadingTranscriptTests {
    private func part(_ text: String, _ start: Double = 0, _ end: Double = 1) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, original: text, speaker: 0)
    }
    @Test func chineseReadingGetsCommasAndSentenceEndWithoutEditingOriginals() {
        let source = [part("你好",0,1),part("我叫小明",1,3),part("欢迎来交流",3,5)]
        let reading = ReadingTranscript(segments: source)
        #expect(reading.text == "你好，我叫小明，欢迎来交流。")
        #expect(source.map(\.text) == ["你好","我叫小明","欢迎来交流"])
        #expect(source[1].start == 1 && source[1].end == 3)
    }
    @Test func existingPunctuationAndQuotesDoNotGetDuplicateMarks() {
        let reading = ReadingTranscript(segments: [part("你好，"),part("“欢迎。”"),part("你准备好了吗？")])
        #expect(reading.text == "你好，“欢迎。”你准备好了吗？")
        #expect(!reading.text.contains("，，") && !reading.text.contains("？。"))
    }
    @Test func continuationAndTechnicalCompoundsAreKeptTogether() {
        let source = [part("我们采用"),part("数据库"),part("事务保证一致性")]
        #expect(ReadingTranscript(segments: source).text == "我们采用数据库事务保证一致性。")
        #expect(ReadingTranscript(segments: [part("代码生成 代码"),part("自动验证和自动修复能"),part("全流程完成工作")]).text == "代码生成 代码自动验证和自动修复能全流程完成工作。")
    }
    @Test func pausesAndIntroducedListsChooseUsefulMarks() {
        #expect(ReadingTranscript(segments: [part("第一项结束",0,1),part("开始下一项",2.1,4)]).text == "第一项结束。开始下一项。")
        #expect(ReadingTranscript(segments: [part("最重要的三件事"),part("理解规则 重复编码 回归验证")]).text.contains("三件事："))
        #expect(ReadingTranscript(segments: [part("对"),part("接下来继续交流")]).text.hasPrefix("对，"))
    }
    @Test func longSpeechHasReadableInnerParagraphsWithStableIDs() {
        let source = (0..<24).map { i in part("这是第\(i)个说明内容和完整观点",Double(i),Double(i+1)) }
        let speech = UtteranceGrouping.make(source)
        let reading = ReadingTranscript(segments: source)
        #expect(speech.count == 1)
        #expect(reading.text.contains("\n"))
        #expect(reading.ranges.count == source.count)
        #expect(source.allSatisfy { reading.ranges[$0.id] != nil })
        #expect(!ReadingTranscript(segments: source, paragraphBreaks: false).text.contains("\n"))
    }
    @Test func originalModeIsExactlyTheExistingTranscript() {
        let source = [part("说明"),part("REST"),part("API"),part("🙂接口")]
        let original = JoinedTranscript(segments: source)
        let reading = ReadingTranscript(segments: source, punctuate: false, paragraphBreaks: false)
        #expect(reading.text == original.text)
        #expect(reading.ranges == original.ranges)
    }
    @Test func decoratedUTF16RangesStillIdentifyTheCorrectSentence() throws {
        let source = [part("你好",5,6),part("🙂欢迎",6,8)]
        let reading = ReadingTranscript(segments: source)
        let second = try #require(reading.ranges[source[1].id])
        #expect((reading.text as NSString).substring(with: second) == "🙂欢迎。")
        #expect(second.location == 3)
        let crossing = try #require(reading.searchRanges(for: "你好🙂").first)
        #expect((reading.text as NSString).substring(with: crossing) == "你好，🙂")
    }
    @Test func crossFragmentSearchSurvivesInsertedPunctuation() throws {
        let source = [part("第一部分",10,12),part("第二部分",12,14)]
        let hits = TranscriptSearch.find("部分第二", utterances: UtteranceGrouping.make(source), recordingID: "r", recordingTitle: "课程", names: [:])
        let hit = try #require(hits.first)
        #expect(hit.segment.id == source[0].id && hit.segment.start == 10)
        let highlight = try #require(hit.previewHighlightRange)
        #expect((hit.preview as NSString).substring(with: highlight) == "部分，第二")
        #expect(TranscriptSearch.find("部分，第二", utterances: UtteranceGrouping.make(source), recordingID: "r", recordingTitle: "r", names: [:]).count == 1)
    }
    @Test func formattedCopyAndTextExportHaveMarksButSubtitleAnchorsRemainOriginal() {
        let source = [part("你好",1.25,2.5),part("欢迎来交流",2.5,4)]
        let txt = TranscriptExport.render(title: "访谈", segments: source, names: [:], srt: false)
        #expect(txt.contains("你好，欢迎来交流。"))
        let raw = TranscriptExport.render(title: "访谈", segments: source, names: [:], srt: false, punctuate: false, paragraphBreaks: false)
        #expect(raw.contains("你好欢迎来交流"))
        let srt = TranscriptExport.render(title: "访谈", segments: source, names: [:], srt: true)
        #expect(srt.contains("00:00:01,250 --> 00:00:02,500"))
        #expect(srt.contains("说话人 A：你好\n"))
    }
    @Test func existingPreferencesDefaultToNewReadingOptions() throws {
        let old = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"modelsDirectory":"/local/models","readerFontSize":18}"#.utf8))
        #expect(old.readerFontSize == 18 && old.readingPunctuation == nil && old.readingParagraphBreaks == nil)
        let updated = AppPreferences(modelsDirectory: old.modelsDirectory, readerFontSize: 18, readingPunctuation: false, readingParagraphBreaks: true)
        let roundTrip = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(updated))
        #expect(roundTrip.readingPunctuation == false && roundTrip.readingParagraphBreaks == true)
    }
    @Test func clearSpokenQuestionsGetQuestionMarks() {
        #expect(ReadingTranscript(segments: [part("你准备好了吗")]).text == "你准备好了吗？")
        #expect(ReadingTranscript(segments: [part("有哪些方法呢")]).text == "有哪些方法呢？")
        #expect(ReadingTranscript(segments: [part("你准备好了吗"),part("我们继续")]).text == "你准备好了吗？我们继续。")
        #expect(ReadingTranscript(segments: [part("你现在在哪里")]).text == "你现在在哪里？")
        #expect(ReadingTranscript(segments: [part("到岗时间多长")]).text == "到岗时间多长？")
        #expect(ReadingTranscript(segments: [part("我不知道是什么")]).text == "我不知道是什么。")
        #expect(ReadingTranscript(segments: [part("对"),part("了解")]).text == "对，了解。")
    }
    @Test func spokenListsAndFromToClausesStayReadable() throws {
        let source = [part("最重要的三件事"),part("理解规则 重复编码 回归验证")]
        let reading = ReadingTranscript(segments: source)
        #expect(reading.text == "最重要的三件事：理解规则、重复编码、回归验证。")
        let found = try #require(reading.searchRanges(for: "规则 重复").first)
        #expect((reading.text as NSString).substring(with: found) == "规则、重复")
        #expect(ReadingTranscript(segments: [part("把职责从重复编码"),part("挪到关键设计上")]).text == "把职责从重复编码挪到关键设计上。")
        #expect(ReadingTranscript(segments: [part("交付周期能由"),part("两周缩短到三天")]).text == "交付周期能由两周缩短到三天。")
        #expect(ReadingTranscript(segments: [part("都是在这套底座上"),part("搭建的"),part("后面希望应用到更多场景")]).text == "都是在这套底座上搭建的。后面希望应用到更多场景。")
    }
    @Test func searchPreviewsRespectOriginalReadingMode() throws {
        let source = [part("第一部分"),part("第二部分")]
        let groups = UtteranceGrouping.make(source)
        let hits = TranscriptSearch.find("部分第二", utterances: groups, recordingID: "r", recordingTitle: "r", names: [:], punctuate: false, paragraphBreaks: false)
        let hit = try #require(hits.first)
        #expect(hit.preview == "第一部分第二部分")
        let range = try #require(hit.previewHighlightRange)
        #expect((hit.preview as NSString).substring(with: range) == "部分第二")
    }
}
