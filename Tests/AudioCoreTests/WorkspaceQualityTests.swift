import Foundation
import AppKit
import SwiftUI
import Testing
import AudioCore
@testable import InterviewAudio

@Suite(.serialized) struct WorkspaceQualityTests {
    @MainActor @Test func taskStatusCountsOnlyRealReceiptsAndKeepsRunsSeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(dataDirectoryOverride: directory)
        let model = AssistantModel()
        defer { model.stop() }
        model.activate("s"); model.follow("first", session: "s", model: app)
        #expect(model.activeSavedChanges.isEmpty)
        model.consume(.init(id: 1, kind: "task_stage", data: Data(#"{"message":"正在分析第 2/5 批资料，完成后统一保存…"}"#.utf8)), run: "first", session: "s")
        #expect(model.progress.contains("2/5") && model.activeSavedChanges.isEmpty)
        for id in [2, 3] {
            model.consume(.init(id: id, kind: "changeset", data: Data(#"{"id":"saved","state":"committed","count":4}"#.utf8)), run: "first", session: "s")
        }
        #expect(model.activeSavedChanges.count == 1 && model.activeSavedChanges.first?.count == 4)
        model.follow("second", session: "s", model: app)
        #expect(model.activeSavedChanges.isEmpty)
    }
    @MainActor @Test func saveFailureStaysRecoverableAndRetryCommits() async {
        let state = EditorSaveState()
        let failed = await state.commit { throw BackendClientError.conflict }
        #expect(!failed && state.error != nil && !state.saving)
        var committed = false
        #expect(await state.commit { committed = true })
        #expect(committed && state.error == nil && !state.saving)
    }
    @MainActor @Test func libraryOperationsRunOffTheUIThread() async throws {
        let store = BackendLibraryStore(connection: BackendConnection(baseURL: URL(string: "http://127.0.0.1:18888")!, token: "synthetic"))
        let mainThread = try await store.perform { _ in Thread.isMainThread }
        #expect(!mainThread)
        let task = Task { try await store.perform { _ in 42 } }
        task.cancel()
        do { _ = try await task.value; Issue.record("已取消的请求不应交付结果") }
        catch is CancellationError { }
    }
    @MainActor @Test func draftRestartKeepsSeparateSessionsAndPrivateFilePermissions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("listen-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("drafts.json")
        let model = AssistantModel()
        await model.restoreDrafts(from: url)
        model.activate("a"); model.input = "会话甲的草稿🙂"
        model.activate("b"); model.input = "会话乙的草稿"; model.allMaterials = true
        await model.flushDrafts()
        let restored = AssistantModel(); await restored.restoreDrafts(from: url)
        #expect(restored.selectedSession == "b" && restored.input == "会话乙的草稿" && restored.allMaterials)
        restored.activate("a"); #expect(restored.input == "会话甲的草稿🙂")
        restored.input = ""; await restored.flushDrafts()
        let snapshot = try #require(try await AssistantDraftStore(url: url).load())
        #expect(snapshot.items["a"] == nil && snapshot.items["b"]?.input == "会话乙的草稿")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func differenceKeepsComposedCharactersAndEmptyRestoration() {
        let span = TextChangeSpan(before: "开头👨‍👩‍👧旧词结束", after: "开头👨‍👩‍👧新词结束")
        #expect(span.prefix == "开头👨‍👩‍👧" && span.removed == "旧" && span.inserted == "新" && span.suffix == "词结束")
        #expect(TextChangeSpan(before: "原文", after: "").removed == "原文")
        #expect(TextChangeSpan(before: "", after: "新文").inserted == "新文")
    }
    @Test func combinedTextAndSpeakerDifferenceKeepsAttributionVisible() throws {
        let data = Data(#"{"resource_type":"segment","before":{"original":"原始自我介绍","edited":null,"speaker":0,"speaker_edited":0,"needs_review":1,"reviewed":0},"after":{"original":"原始自我介绍","edited":"修订自我介绍","speaker":1,"speaker_edited":1,"needs_review":0,"reviewed":1},"speaker_names":{"before":"面试官","after":"我"}}"#.utf8)
        let item = try JSONDecoder().decode(BackendJSONValue.self, from: data)
        let metadata = ChangeDifference.describe(item, excluding: ["edited"])
        #expect(metadata.contains("发言归属\n修改前：面试官\n修改后：我"))
        #expect(metadata.contains("已核对\n修改前：否\n修改后：是"))
        #expect(!metadata.contains("speaker_edited") && !metadata.contains("修订自我介绍"))
        let renamed = try JSONDecoder().decode(BackendJSONValue.self, from: Data(#"{"before":{"name":"回答者"},"after":{"name":"我"}}"#.utf8))
        #expect(ChangeDifference.describe(renamed).contains("说话人名称\n修改前：回答者\n修改后：我"))
    }
    @Test func attributionCorrectionRegroupsReadingAndExportWithoutChangingAudioAnchors() {
        var source = [TranscriptSegment(id: "question", start: 43, end: 48, original: "请介绍一下自己", speaker: 0),
                      TranscriptSegment(id: "introduction", start: 48, end: 70, original: "面试官你好，我是合成候选人", speaker: 0),
                      TranscriptSegment(id: "work", start: 70, end: 100, original: "我负责合成服务开发", speaker: 0)]
        #expect(UtteranceGrouping.make(source).count == 1)
        let before = source
        for index in [1, 2] { source[index].speaker = 1; source[index].speakerEdited = true }
        let groups = UtteranceGrouping.make(source)
        #expect(groups.count == 2 && groups[0].segments.map(\.id) == ["question"])
        #expect(groups[1].speaker == 1 && groups[1].segments.map(\.id) == ["introduction", "work"])
        #expect(zip(before, source).allSatisfy { $0.id == $1.id && $0.original == $1.original && $0.start == $1.start && $0.end == $1.end })
        let output = TranscriptExport.render(title: "合成", segments: source, names: [0: "面试官", 1: "我"], srt: false, plainDialogue: true)
        #expect(output.contains("面试官：\n") && output.contains("我：\n"))
    }
    @MainActor @Test func expandedAssistantKeepsReaderUsableAtMinimumWidth() {
        let controller = AssistantSplitController()
        controller.install(main: AnyView(Color.clear), assistant: AnyView(Color.clear), visible: true)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 680)
        controller.expanded = true; controller.view.layoutSubtreeIfNeeded()
        #expect(controller.splitView.arrangedSubviews.first!.frame.width >= 520)
        #expect(controller.splitView.arrangedSubviews.last!.frame.width > 560)
        controller.expanded = false; controller.view.layoutSubtreeIfNeeded()
        #expect(controller.splitView.arrangedSubviews.first!.frame.width >= 740)
    }
}
