import Foundation
import AppKit
import SwiftUI
import Testing
@testable import AudioCore
@testable import InterviewAudio

@Suite(.serialized) struct WorkspaceExperienceTests {
    @Test func oldPreferencesAndWorkspaceRoundTrip() throws {
        let old = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"modelsDirectory":"/synthetic/models"}"#.utf8))
        #expect(old.workspaceMode == nil && old.welcomeDismissed == nil)
        let new = AppPreferences(modelsDirectory: "/synthetic/models", workspaceMode: "proofreading", welcomeDismissed: true)
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(new))
        #expect(restored.workspaceMode == "proofreading" && restored.welcomeDismissed == true)
    }

    @Test func editedAndReviewedStatusesAreIndependent() {
        var sentence = TranscriptSegment(id: "s", start: 1, end: 3, original: "合成文字", edited: "人工修改", needsReview: true)
        var group = SpeechUtterance(segments: [sentence])
        #expect(group.hasContentEdits && ReviewPresentation.title(for: group) == "待核对 1 句")
        sentence.edited = nil; sentence.reviewed = true
        group = SpeechUtterance(segments: [sentence])
        #expect(!group.hasContentEdits && ReviewPresentation.title(for: group) == "已核对")
        sentence.reviewed = nil; sentence.needsReview = false
        #expect(ReviewPresentation.title(for: .init(segments: [sentence])) == nil)
    }

    @Test func scopeAndElapsedLabelsDescribeActualInputs() throws {
        #expect(AssistantScopePresentation.title(allMaterials: true, quotes: 2, material: "录音甲") == "全部资料")
        #expect(AssistantScopePresentation.title(allMaterials: true, quotes: 2, material: "录音甲", materialCount: 7) == "全部资料 · 7 份")
        #expect(AssistantScopePresentation.title(allMaterials: false, quotes: 2, material: "录音甲") == "引用片段 · 2 条")
        #expect(AssistantScopePresentation.title(allMaterials: false, quotes: 0, material: nil) == "未选择资料")
        #expect(AssistantScopePresentation.elapsed(61) == "已等待 1 分 1 秒")
        #expect(AssistantScopePresentation.elapsed(-1) == "已等待 0 秒")
        let context = try JSONDecoder().decode(AssistantRunContext.self, from: Data(#"{"task_intent":{"reading":"none"},"scope_title":"旧资料名称"}"#.utf8))
        #expect(context.taskIntent?.title == "直接对话")
        let legacy = try JSONDecoder().decode(AssistantRunContext.self, from: Data(#"{"scope_title":"录音甲"}"#.utf8))
        #expect(legacy.taskIntent == nil)
    }

    @Test func navigationHistoryDescribesUserActions() throws {
        let creation = try JSONDecoder().decode(BackendJSONValue.self, from: Data(#"{"resource_type":"navigation","before_revision":1,"before":{"removed":1,"kind":"bookmark","title":"重点"},"after":{"removed":0,"kind":"bookmark","title":"重点"}}"#.utf8))
        #expect(ChangeDifference.describe(creation) == "添加书签「重点」")
        let removal = try JSONDecoder().decode(BackendJSONValue.self, from: Data(#"{"resource_type":"navigation","before_revision":2,"before":{"removed":0,"kind":"later","title":"待回听"},"after":{"removed":1,"kind":"later","title":"待回听"}}"#.utf8))
        #expect(ChangeDifference.describe(removal) == "移除稍后复听「待回听」")
    }

    @MainActor @Test func reviewNavigationWrapsWithoutEditingAndPresetClearsBulkSelection() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppModel(dataDirectoryOverride: directory)
        app.segments = [
            .init(id: "a", start: 1, end: 2, original: "第一句", needsReview: true),
            .init(id: "b", start: 3, end: 4, original: "已核对", needsReview: true, reviewed: true),
            .init(id: "c", start: 5, end: 6, original: "第三句", needsReview: true)]
        let original = app.segments
        app.reviewFilter = .pending
        app.focusSegmentID = "a"; app.navigateReview(1)
        #expect(app.focusSegmentID == "c")
        #expect(app.reviewFilter == .pending)
        app.navigateReview(1); #expect(app.focusSegmentID == "a")
        app.navigateReview(-1); #expect(app.focusSegmentID == "c")
        #expect(app.segments == original)
        app.selectionMode = true; app.bulkSelection = ["a"]; app.reviewFilter = .pending
        app.setWorkspaceMode(.reading)
        #expect(!app.selectionMode && app.bulkSelection.isEmpty && app.reviewFilter == .all)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor @Test func navigationRetriesReuseOperationAndKeepUserInputOnFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NavigationTestProtocol.self]
        let client = try BackendClient(baseURL: URL(string: "http://127.0.0.1:18888")!, token: "synthetic", configuration: configuration)
        let model = NavigationModel(); model.client = client
        let history = ChangeHistoryModel()
        var bodies: [Data] = []
        NavigationTestProtocol.handler = { request in
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
            }
            bodies.append(body)
            if bodies.count == 1 { throw URLError(.timedOut) }
            return Data(#"{"id":"saved","state":"committed","count":1,"items":[]}"#.utf8)
        }
        defer { NavigationTestProtocol.handler = nil }
        let marks: [[String: Any]] = [["segment_id": "s", "expected_revision": 1, "kind": "bookmark", "title": "合成书签 📚"]]
        #expect(!(await model.create(marks, recordingID: "r", history: history)))
        #expect(model.error != nil && history.items.isEmpty)
        #expect(await model.create(marks, recordingID: "r", history: history))
        #expect(bodies.count == 2 && bodies[0] == bodies[1] && history.items.count == 1)
        let row = try JSONDecoder().decode(NavigationMark.self, from: Data(#"{"id":"n","run_id":"run","segment_id":"s","kind":"bookmark","title":"合成","start":1,"end":2,"revision":2}"#.utf8))
        bodies = []
        #expect(!(await model.update(row, fields: ["title": "改名"], history: history)))
        #expect(await model.update(row, fields: ["title": "改名"], history: history))
        #expect(bodies[0] == bodies[1])
    }

    @MainActor @Test func snapshotsAtSupportedWidthsAndAppearances() throws {
        guard let destination = ProcessInfo.processInfo.environment["INTERVIEW_UI_SNAPSHOT_DIR"] else { return }
        let folder = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suiteName = "tingyue.synthetic." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: "assistant.visible")
        let app = AppModel(dataDirectoryOverride: folder.appendingPathComponent("unused-data"))
        app.recordings = [.init(id: "r", title: "合成访谈 · 项目讨论", path: "/synthetic/audio.wav", fingerprint: "synthetic", duration: 3600, state: .completed, activeRun: "run")]
        app.selectedID = "r"
        app.segments = [
            .init(id: "a", start: 2, end: 12, original: "请介绍一下你最近做的项目，以及其中最有挑战的部分。", speaker: 0, needsReview: true),
            .init(id: "b", start: 13, end: 60, original: "我最近在做一个本地音频阅读工具。它可以把录音转换成文字，让用户点击句子回听，再选中一段话向助手提问。我们希望阅读过程自然流畅，同时能方便地核对识别结果。", edited: "我们希望阅读过程自然流畅，也能方便地核对识别结果。", speaker: 1, needsReview: true),
            .init(id: "c", start: 65, end: 80, original: "这些修改如何让用户确认和恢复？", speaker: 0, reviewed: true)]
        app.utterances = UtteranceGrouping.make(app.segments); app.names = [0: "提问者", 1: "讲述者"]
        app.assistant.runs = [try JSONDecoder().decode(AssistantRun.self, from: Data(#"{"id":"synthetic-result","state":"completed","context":{"scope_title":"合成访谈 · 项目讨论","task_intent":{"reading":"selection"}},"result":{"answer":"已更新发言归属 1 处，可整次撤销。","coverage":{"total":2,"covered":2},"partial_results":[{"answer":"本批的处理过程保存在详情中。"}],"changeset":{"id":"synthetic-change","state":"committed","count":1,"items":[{"resource_type":"segment","resource_id":"a","after_revision":2,"before":{"original":"请介绍一下最近做的项目。","edited":null,"speaker":1},"after":{"original":"请介绍一下最近做的项目。","edited":null,"speaker":0},"speaker_names":{"before":"讲述者","after":"提问者"},"source_location":{"start":2}}]}}}"#.utf8))]
        for width in [1100, 1360, 1600] {
            for dark in [false, true] {
                for mode in ReaderWorkspaceMode.allCases {
                    app.workspaceMode = mode
                    let host = NSHostingView(rootView: LibraryView(model: app)
                        .defaultAppStorage(preferences).environment(\.colorScheme, dark ? .dark : .light)
                        .frame(width: CGFloat(width), height: 860))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 860)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: folder.appendingPathComponent("workspace-\(width)-\(dark ? "dark" : "light")-\(mode.rawValue).png"))
                    #expect(host.bounds.width == CGFloat(width))
                }
            }
        }
    }

    @Test func selectionActionsUseOriginalUTF16Segments() {
        let segments: [TranscriptSegment] = [
            .init(id: "a", start: 1, end: 2, original: "你好🙂。"),
            .init(id: "b", start: 3, end: 4, original: "第二句话。"),
            .init(id: "c", start: 5, end: 6, original: "第三句话。")]
        let reading = ReadingTranscript(segments: segments)
        let range = (reading.text as NSString).range(of: "🙂。第二")
        #expect(SelectedQuote.selectedSegments(in: range, ranges: reading.ranges, segments: segments).map(\.id) == ["a", "b"])
        #expect(SelectedQuote.selectedSegments(in: .init(location: 0, length: 0), ranges: reading.ranges, segments: segments).isEmpty)
    }

    @MainActor @Test func currentDocumentDoesNotReusePreviousRecordingScope() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CurrentDocumentProtocol.self]
        let client = try BackendClient(baseURL: URL(string: "http://127.0.0.1:18888")!, token: "synthetic", configuration: configuration)
        let assistant = AssistantModel(client: client)
        defer { assistant.stop() }
        let app = AppModel(dataDirectoryOverride: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        app.selectedID = "previous-recording"
        app.librarySection = .documents; app.currentDocumentID = "document-a"
        assistant.activate("s"); assistant.input = "总结当前材料"
        CurrentDocumentProtocol.body = nil
        await assistant.send(model: app)
        let body = try #require(CurrentDocumentProtocol.body)
        let context = try #require(body["context"] as? [String: Any])
        #expect(context["recording_id"] is NSNull)
        #expect(context["run_id"] is NSNull)
        #expect(context["document_ids"] as? [String] == ["document-a"])
        await Task.yield()
    }
}

private final class CurrentDocumentProtocol: URLProtocol, @unchecked Sendable {
    static var body: [String: Any]?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var response = Data(#"{"items":[],"runs":[]}"#.utf8)
        if request.httpMethod == "POST" {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            }
            Self.body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            response = Data(#"{"id":"document-run","state":"completed"}"#.utf8)
        } else if request.url!.path.hasSuffix("/events") {
            response = Data("id: 1\nevent: completed\ndata: {}\n\n".utf8)
        } else if request.url!.path.hasPrefix("/api/v1/agent/runs/") {
            response = Data(#"{"id":"document-run","state":"completed"}"#.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class NavigationTestProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
