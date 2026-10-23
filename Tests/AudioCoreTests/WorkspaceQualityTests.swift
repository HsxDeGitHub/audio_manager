import Foundation
import AppKit
import SwiftUI
import Testing
@testable import InterviewAudio

@Suite(.serialized) struct WorkspaceQualityTests {
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
