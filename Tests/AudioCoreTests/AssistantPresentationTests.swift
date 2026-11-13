import Foundation
import SwiftUI
import Testing
@testable import InterviewAudio

@Suite(.serialized) struct AssistantPresentationTests {
    private func record(before: [String: Any], after: [String: Any], type: String = "segment") throws -> AssistantChangeRecord {
        let data = try JSONSerialization.data(withJSONObject: ["resource_type": type, "resource_id": "synthetic", "after_revision": 7,
            "source_location": ["start": 83.5, "line": 3], "before": before, "after": after])
        return AssistantChangeRecord(index: 0, item: try JSONDecoder().decode(BackendJSONValue.self, from: data))
    }

    @Test func summaryClassifiesRealTextPunctuationAndSpeakerDifferences() throws {
        let word = try record(before: ["original": "旗牌", "speaker": 0], after: ["original": "旗牌", "edited": "棋牌", "speaker": 1])
        let punctuation = try record(before: ["original": "你好世界"], after: ["original": "你好世界", "edited": "你好，世界。"])
        #expect(word.matches(.text) && word.matches(.speaker) && !word.matches(.punctuation))
        #expect(punctuation.matches(.punctuation) && !punctuation.matches(.text))
        let change = AssistantChange(id: "synthetic", state: "committed", count: 2, items: [word.item, punctuation.item])
        let summary = AssistantChangeSummary(change)
        #expect(summary.description == "文字修正 1 处 · 标点/空格 1 处 · 说话人调整 1 处")
        #expect(summary.records.count == 2)
        #expect(word.reference?.resourceID == "synthetic" && word.reference?.revision == 7 && word.reference?.line == 3)
    }

    @Test func punctuationClassificationPreservesTechnicalOperatorsAndEmptyEdits() throws {
        let technical = try record(before: ["original": "C++ 服务"], after: ["original": "C++ 服务", "edited": "C 服务"])
        #expect(technical.matches(.text) && !technical.punctuationOnly)
        let cleared = try record(before: ["original": "原文"], after: ["original": "原文", "edited": ""])
        #expect(cleared.textChanged && cleared.preview.isEmpty)
        let restored = try record(before: ["original": "原文", "edited": "修订"], after: ["original": "原文", "edited": NSNull()])
        #expect(restored.textChanged && restored.preview == "原文")
        let untouched = try record(before: ["original": "原文"], after: ["original": "原文", "edited": NSNull()])
        #expect(!untouched.textChanged)
    }

    @Test func reviewFilterUsesCommittedSnapshotAndExplicitReviewedFlag() throws {
        let pending = try record(before: ["original": "合成"], after: ["original": "合成", "needs_review": 1, "reviewed": 0])
        let checked = try record(before: [:], after: ["needs_review": true, "reviewed": true])
        #expect(pending.needsReview && !checked.needsReview)
        let renamed = try record(before: ["name": "回答者"], after: ["name": "讲述者"], type: "speaker")
        #expect(renamed.speakerChanged && !renamed.textChanged)
        let document = try record(before: ["content": "旧材料"], after: ["content": "新材料"], type: "document")
        #expect(document.matches(.text) && document.preview == "新材料")
    }

    @Test func legacyAndMalformedChangeRowsStayReadable() throws {
        let old = try JSONDecoder().decode(AssistantChange.self, from: Data(#"{"id":"old","state":"committed","count":4}"#.utf8))
        #expect(AssistantChangeSummary(old).records.isEmpty && AssistantChangeSummary(old).pendingCount == 0)
        let unknown = AssistantChangeRecord(index: 0, item: .null)
        #expect(unknown.matches(.all) && !unknown.matches(.text) && unknown.reference == nil)
        #expect(unknown.preview == "查看具体差异")
    }

    @Test func searchUsesVisibleMarkdownTextAndKeepsCodeAndUnicode() {
        let document = AssistantMarkdownDocument("## **合成结果**\n\n- Café 和 café，🙂结果。\n\n```go\nfmt.Println(\"结果\")\n```\n\n###没有空格")
        #expect(document.matches("结果").count == 3)
        #expect(document.matches("CAFE").count == 2)
        #expect(document.matches("**").isEmpty && document.matches("  ").isEmpty)
        #expect(document.blocks.filter(\.code).count == 1)
        #expect(String(document.blocks.last!.lines[0].text.characters) == "###没有空格")
        let emoji = AssistantTextSearch.ranges(in: "👨‍👩‍👧结果🙂结果", query: "结果")
        #expect(emoji.count == 2 && emoji[0].location == ("👨‍👩‍👧" as NSString).length)
        let multiline = AssistantMarkdownDocument("```\n第一行\n第二行\n```")
        #expect(String(multiline.blocks[0].lines[0].text.characters) == "第一行\n第二行")
    }

    @MainActor @Test func searchHighlightPreservesVisibleText() {
        let original = AttributedString("🙂结果和结果")
        let range = AssistantTextSearch.ranges(in: String(original.characters), query: "结果")[1]
        let highlighted = AssistantTextSearch.highlight(original, query: "结果", selected: range)
        #expect(highlighted.characters.elementsEqual(original.characters))
        #expect(highlighted.runs.filter { $0.backgroundColor != nil }.count == 2)
    }

    @Test func archivedOutputKeepsOnlyEarlierBlocksAndResetsCurrentRetry() throws {
        var output = AssistantOutput()
        func event(_ id: Int, _ kind: String, _ payload: [String: Any]) throws -> BackendClient.Event {
            .init(id: id, kind: kind, data: try JSONSerialization.data(withJSONObject: payload))
        }
        output.apply(try event(1, "answer_reset", ["attempt_id": "a"]))
        output.apply(try event(2, "answer_delta", ["attempt_id": "a", "block_id": "first", "text": "第一批已保留"]))
        output.apply(try event(3, "answer_start", ["attempt_id": "a", "block_id": "second"]))
        #expect(output.completedBlocks.map(\.text) == ["第一批已保留"] && output.currentText.isEmpty)
        output.apply(try event(4, "answer_delta", ["attempt_id": "a", "block_id": "second", "text": "本步未校验输出"]))
        output.apply(try event(5, "answer_start", ["attempt_id": "a", "block_id": "second"]))
        #expect(output.completedBlocks.count == 1 && output.currentText.isEmpty)
        output.apply(try event(6, "answer_reset", ["attempt_id": "new"]))
        #expect(output.completedBlocks.isEmpty && output.currentText.isEmpty)
    }

    @MainActor @Test func latestFailureRemainsExpandedAndOlderInterruptionIsHistorical() {
        let model = AssistantModel()
        model.activate("synthetic")
        let old = AssistantRun(id: "old", state: "cancelled", result: nil)
        let current = AssistantRun(id: "current", state: "failed", result: nil)
        model.runs = [old, current]
        #expect(model.isHistoricalInterruption(old) && !model.isHistoricalInterruption(current))
        let snapshot = AssistantOutput(attemptID: "saved", blocks: [.init(blockID: "b", text: "历史输出")], lastEventID: 8)
        model.runs = [AssistantRun(id: "legacy", state: "interrupted", result: nil, output: snapshot)]
        #expect(model.output("legacy") == "历史输出")
    }
}
