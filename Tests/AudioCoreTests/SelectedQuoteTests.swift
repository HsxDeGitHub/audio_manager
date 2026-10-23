import Foundation
import AppKit
import Testing
import AudioCore
@testable import InterviewAudio

@Suite(.serialized) struct SelectedQuoteTests {
    @Test func crossSegmentSelectionPreservesDisplayedWordsAndOrderedSources() throws {
        let segments = [TranscriptSegment(id: "a", start: 1, end: 2, original: "你好🙂"),
                        TranscriptSegment(id: "b", start: 2, end: 3, original: "欢迎交流")]
        let reading = ReadingTranscript(segments: segments)
        let range = (reading.text as NSString).range(of: "🙂，欢迎")
        let quote = try #require(SelectedQuote.transcript(text: reading.text, range: range, ranges: reading.ranges, segments: segments,
            title: "合成访谈", recordingID: "r", runID: "run", revision: { $0 == "a" ? 2 : 3 }))
        #expect(quote.text == "🙂，欢迎")
        #expect(quote.sources.map(\.resourceID) == ["a", "b"])
        #expect(quote.sources.map(\.revision) == [2, 3])
        #expect(quote.location == "00:01–00:03")
        #expect(segments[0].original == "你好🙂")
    }

    @Test func documentSelectionTracksActualLinesAndUTF16() throws {
        let item = BackendDocument(id: "doc", title: "合成资料", format: "md", content: "第一行\n🙂第二行\n第三行", revision: 4, duplicate: nil)
        let range = (item.content as NSString).range(of: "第二行\n第三")
        let quote = try #require(SelectedQuote.document(item, range: range))
        #expect(quote.text == "第二行\n第三")
        #expect(quote.location == "第 2–3 行")
        #expect(quote.sources[0].line == 2 && quote.sources[0].revision == 4)
        #expect(SelectedQuote.document(item, range: NSRange(location: 0, length: 0)) == nil)
        #expect(SelectedQuote.document(item, range: NSRange(location: NSNotFound, length: 1)) == nil)
        #expect(SelectedQuote.document(item, range: NSRange(location: 100, length: 1)) == nil)
    }

    @MainActor @Test func referenceDraftsDeduplicateAndRemainIsolatedByConversation() {
        let quote = SelectedQuote(text: "所选文字", title: "材料", location: "第 2 行", sources: [.init(resourceType: "document", resourceID: "d", revision: 1, line: 2)])
        let model = AssistantModel(); model.activate("a"); model.input = "草稿"
        #expect(model.addQuote(quote)); #expect(model.isVisible)
        #expect(model.addQuote(quote)); #expect(model.quotes.count == 1)
        model.activate("b"); #expect(model.quotes.isEmpty)
        model.activate("a"); #expect(model.quotes == [quote]); #expect(model.input == "草稿")
        let oversized = SelectedQuote(text: String(repeating: "字", count: 12001), title: "材料", location: "", sources: quote.sources)
        #expect(!model.addQuote(oversized)); #expect(model.quotes.count == 1)
        model.removeQuote(quote.id); #expect(model.quotes.isEmpty); #expect(model.input == "草稿")
    }

    @MainActor @Test func nativeSelectionActionUsesExactRangeWithoutChangingText() throws {
        let view = QuoteSelectionTextView(); view.string = "原文🙂选中这里，保留其余。"
        let range = (view.string as NSString).range(of: "🙂选中这里")
        view.setSelectedRange(range)
        var captured: NSRange?
        view.onQuote = { captured = $0 }
        let menu = NSMenu(); view.addQuoteItem(to: menu)
        #expect(menu.items.first?.title == "添加到对话")
        menu.performActionForItem(at: 0)
        #expect(captured == range); #expect(view.string == "原文🙂选中这里，保留其余。")
    }

    @Test func quoteHistoryDecodesAlongsideLegacyMessages() throws {
        let message = try JSONDecoder().decode(AssistantMessage.self, from: Data(#"{"id":"u","role":"user","content":"解释这段","context":{"quotes":[{"id":"q","text":"选中文字","title":"合成材料","location":"第 1 行","sources":[{"resource_type":"document","resource_id":"doc","revision":2,"line":1}]}]}}"#.utf8))
        #expect(message.context?.quotes?.first?.text == "选中文字")
        let old = try JSONDecoder().decode(AssistantMessage.self, from: Data(#"{"id":"old","role":"user","content":"旧消息","context":{}}"#.utf8))
        #expect(old.context?.quotes == nil)
    }
}
