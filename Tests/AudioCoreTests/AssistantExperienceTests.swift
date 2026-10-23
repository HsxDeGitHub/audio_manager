import Foundation
import AppKit
import SwiftUI
import Testing
@testable import InterviewAudio

@Suite(.serialized) struct AssistantExperienceTests {
    @Test func outputDeduplicatesAndResetsAttempts() throws {
        var output = AssistantOutput()
        func event(_ id: Int, _ kind: String, _ json: String) -> BackendClient.Event { .init(id: id, kind: kind, data: Data(json.utf8)) }
        output.apply(event(1,"answer_reset",#"{"attempt_id":"a"}"#))
        output.apply(event(2,"answer_start",#"{"attempt_id":"a","block_id":"b"}"#))
        let delta=event(3,"answer_delta",#"{"attempt_id":"a","block_id":"b","text":"中文"}"#)
        output.apply(delta); output.apply(delta)
        #expect(output.text == "中文")
        output.apply(event(4,"answer_reset",#"{"attempt_id":"new"}"#))
        output.apply(event(5,"answer_delta",#"{"attempt_id":"a","block_id":"b","text":"迟到"}"#))
        #expect(output.text.isEmpty)
    }
    @Test func retryReplacesOnlyTheFailedModelBlock() {
        var output = AssistantOutput()
        func event(_ id: Int, _ kind: String, _ json: String) -> BackendClient.Event { .init(id: id, kind: kind, data: Data(json.utf8)) }
        output.apply(event(1,"answer_reset",#"{"attempt_id":"a"}"#))
        output.apply(event(2,"answer_delta",#"{"attempt_id":"a","block_id":"completed","text":"已完成批次"}"#))
        output.apply(event(3,"answer_delta",#"{"attempt_id":"a","block_id":"retry","text":"未通过校验的回答"}"#))
        output.apply(event(4,"answer_start",#"{"attempt_id":"a","block_id":"retry"}"#))
        output.apply(event(5,"answer_delta",#"{"attempt_id":"a","block_id":"retry","text":"重试后完整回答"}"#))
        #expect(output.text == "已完成批次\n\n重试后完整回答")
    }
    @MainActor @Test func draftsAndErrorsAreIsolatedBySession() {
        let model=AssistantModel()
        model.activate("a"); model.input="未发送草稿"; model.allMaterials=true
        model.activate("b"); #expect(model.input.isEmpty); #expect(!model.allMaterials)
        model.input="另一份草稿"; model.activate("a")
        #expect(model.input=="未发送草稿"); #expect(model.allMaterials)
        model.disconnected(); #expect(model.input=="未发送草稿")
    }
    @Test func editorReturnPolicyProtectsComposition() {
        #expect(AssistantInputPolicy.shouldSend(keyCode:36, modifiers:[], marked:false))
        #expect(!AssistantInputPolicy.shouldSend(keyCode:36, modifiers:.shift, marked:false))
        #expect(!AssistantInputPolicy.shouldSend(keyCode:36, modifiers:[], marked:true))
        #expect(!AssistantInputPolicy.shouldSend(keyCode:0, modifiers:[], marked:false))
    }
    @Test func historyConnectsRunToUserAndKeepsOldResults() throws {
        let run=try JSONDecoder().decode(AssistantRun.self,from:Data(#"{"id":"r","state":"completed","message_id":"u","result":{"answer":"完成"},"output":{"attempt_id":"a","blocks":[{"block_id":"b","text":"部分"}],"last_event_id":4}}"#.utf8))
        #expect(run.messageID=="u"); #expect(run.output?.text=="部分")
        let old=try JSONDecoder().decode(AssistantRun.self,from:Data(#"{"id":"old","state":"failed"}"#.utf8))
        #expect(old.output==nil)
        let limited = try JSONDecoder().decode(AssistantRun.self, from: Data(#"{"id":"limited","state":"running","context":{"history_omitted":true}}"#.utf8))
        #expect(limited.context?.historyOmitted == true)
    }
}

private final class ExperienceProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.cancelled) }
            let data = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct AssistantSendingTests {
    @MainActor @Test func quoteRetryKeepsAttachmentsAndChangedSelectionGetsNewMessageIdentity() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceProtocol.self]
        let client = try BackendClient(baseURL: URL(string: "http://127.0.0.1:18888")!, token: "synthetic", configuration: config)
        let model = AssistantModel(client: client)
        defer { model.stop(); ExperienceProtocol.handler = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(dataDirectoryOverride: directory)
        let first = SelectedQuote(text: "第一处选区🙂", title: "合成材料", location: "第 2 行", sources: [.init(resourceType: "document", resourceID: "doc", revision: 1, line: 2)])
        let second = SelectedQuote(text: "第二处选区", title: "合成材料", location: "第 3 行", sources: [.init(resourceType: "document", resourceID: "doc", revision: 1, line: 3)])
        var bodies: [[String: Any]] = []
        ExperienceProtocol.handler = { request in
            if request.httpMethod == "POST" {
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
                }
                let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let context = try #require(body["context"] as? [String: Any])
                #expect(body["instruction"] as? String == "解释这里")
                #expect(context["document_ids"] as? [String] == ["doc"])
                #expect(context["recording_id"] is NSNull)
                bodies.append(body)
                if bodies.count < 3 { throw URLError(.timedOut) }
                #expect((context["quotes"] as? [[String: Any]])?.first?["text"] as? String == second.text)
                return Data(#"{"id":"run","state":"completed"}"#.utf8)
            }
            if request.url!.path.hasSuffix("/events") { return Data("id: 1\nevent: completed\ndata: {}\n\n".utf8) }
            if request.url!.path == "/api/v1/agent/runs/run" { return Data(#"{"id":"run","state":"completed"}"#.utf8) }
            if request.url!.path == "/api/v1/sessions/s" { return Data(#"{"items":[],"runs":[]}"#.utf8) }
            return Data(#"{"items":[]}"#.utf8)
        }
        model.activate("s"); model.input = "解释这里"; model.addQuote(first)
        await model.send(model: app); #expect(model.quotes == [first]); #expect(model.input == "解释这里")
        await model.send(model: app)
        #expect(bodies[0]["message_id"] as? String == bodies[1]["message_id"] as? String)
        model.removeQuote(first.id); model.addQuote(second)
        await model.send(model: app)
        #expect(bodies[2]["message_id"] as? String != bodies[0]["message_id"] as? String)
        #expect(model.quotes.isEmpty); #expect(model.input.isEmpty)
        await Task.yield()
    }
    @MainActor @Test func deletingSelectedThenLastSessionKeepsOtherDraftAndReturnsToNewConversation() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceProtocol.self]
        let client = try BackendClient(baseURL: URL(string: "http://127.0.0.1:18888")!, token: "synthetic", configuration: config)
        let model = AssistantModel(client: client)
        defer { model.stop(); ExperienceProtocol.handler = nil }
        model.sessions = [.init(id: "a", title: "甲"), .init(id: "b", title: "乙")]
        model.activate("b"); model.input = "保留的草稿"
        model.activate("a"); model.input = "将移除的草稿"
        model.runs = [.init(id: "old", state: "completed", result: nil)]
        ExperienceProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                let id = request.url!.lastPathComponent
                return Data("{\"id\":\"\(id)\",\"deleted\":true}".utf8)
            }
            #expect(request.url?.path == "/api/v1/sessions/b")
            return Data(#"{"items":[],"runs":[]}"#.utf8)
        }
        try await model.deleteSession("a")
        #expect(model.selectedSession == "b"); #expect(model.sessions.count == 1)
        #expect(model.input == "保留的草稿"); #expect(model.deletingSessionID == nil)
        model.activate("a"); #expect(model.input.isEmpty); #expect(model.runs.isEmpty)
        model.activate("b"); try await model.deleteSession("b")
        #expect(model.selectedSession == nil); #expect(model.sessions.isEmpty)
        #expect(model.input.isEmpty); #expect(!model.canDeleteSelectedSession)
    }
    @MainActor @Test func deletingAnotherSessionDoesNotChangeSelection() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceProtocol.self]
        let client = try BackendClient(baseURL: URL(string: "http://127.0.0.1:18888")!, token: "synthetic", configuration: config)
        let model = AssistantModel(client: client)
        defer { model.stop(); ExperienceProtocol.handler = nil }
        model.sessions = [.init(id: "a", title: "甲"), .init(id: "b", title: "乙")]
        model.activate("b"); model.input = "当前草稿"
        ExperienceProtocol.handler = { request in
            #expect(request.httpMethod == "DELETE"); #expect(request.url?.path == "/api/v1/sessions/a")
            return Data(#"{"id":"a","deleted":true}"#.utf8)
        }
        try await model.deleteSession("a")
        #expect(model.selectedSession == "b"); #expect(model.input == "当前草稿")
    }
    @MainActor @Test func failedDeletionKeepsHistoryAndSelection() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceProtocol.self]
        let client = try BackendClient(baseURL: URL(string: "http://127.0.0.1:18888")!, token: "synthetic", configuration: config)
        let model = AssistantModel(client: client)
        defer { model.stop(); ExperienceProtocol.handler = nil }
        model.sessions = [.init(id: "a", title: "甲")]; model.activate("a"); model.input = "未发送草稿"
        ExperienceProtocol.handler = { _ in throw URLError(.timedOut) }
        do { try await model.deleteSession("a"); Issue.record("删除失败不应清理会话") }
        catch { #expect(error as? BackendClientError == .timedOut) }
        #expect(model.sessions.count == 1); #expect(model.selectedSession == "a")
        #expect(model.input == "未发送草稿"); #expect(model.deletingSessionID == nil)
    }
    @MainActor @Test func renameUpdatesOnlyTargetAndKeepsConversationDrafts() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceProtocol.self]
        let client = try BackendClient(baseURL: URL(string: "http://127.0.0.1:18888")!, token: "synthetic", configuration: config)
        let model = AssistantModel(client: client)
        defer { model.stop(); ExperienceProtocol.handler = nil }
        model.sessions = [.init(id: "a", title: "原话题"), .init(id: "b", title: "另一个话题")]
        model.activate("a"); model.input = "甲的草稿"; model.allMaterials = true
        model.activate("b"); model.input = "乙的草稿"
        ExperienceProtocol.handler = { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/api/v1/sessions/a")
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(buffer, count: count)
                }
            }
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(body == ["title": "面试复盘 📚"])
            return Data(#"{"id":"a","title":"面试复盘 📚"}"#.utf8)
        }
        try await model.renameSession("a", title: "  面试复盘 📚\n")
        #expect(model.sessions.first?.title == "面试复盘 📚")
        #expect(model.sessions.last?.title == "另一个话题")
        #expect(model.selectedSession == "b"); #expect(model.input == "乙的草稿")
        #expect(model.renamingSessionID == nil)
        model.activate("a"); #expect(model.input == "甲的草稿"); #expect(model.allMaterials)
    }
    @MainActor @Test func renameFailureAndInvalidTitleKeepSavedName() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceProtocol.self]
        let client = try BackendClient(baseURL: URL(string: "http://127.0.0.1:18888")!, token: "synthetic", configuration: config)
        let model = AssistantModel(client: client)
        defer { model.stop(); ExperienceProtocol.handler = nil }
        model.sessions = [.init(id: "a", title: "原话题")]; model.activate("a")
        var requests = 0
        ExperienceProtocol.handler = { _ in requests += 1; throw URLError(.timedOut) }
        for title in [" \n ", String(repeating: "字", count: 121)] {
            do { try await model.renameSession("a", title: title); Issue.record("无效名称不应保存") }
            catch { #expect(error as? BackendClientError == .invalidRequest) }
        }
        #expect(requests == 0)
        do { try await model.renameSession("a", title: "新名称"); Issue.record("请求失败不应保存") }
        catch { #expect(error as? BackendClientError == .timedOut) }
        #expect(requests == 1); #expect(model.sessions.first?.title == "原话题")
        #expect(model.selectedSession == "a"); #expect(model.renamingSessionID == nil)
    }
    @MainActor @Test func retryPreservesRequestIdentityAndDraft() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExperienceProtocol.self]
        let client = try BackendClient(baseURL: URL(string: "http://127.0.0.1:18888")!, token: "synthetic", configuration: config)
        let model = AssistantModel(client: client)
        defer { model.stop(); ExperienceProtocol.handler = nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(dataDirectoryOverride: directory)
        var bodies: [Data] = []
        ExperienceProtocol.handler = { request in
            if request.httpMethod == "POST" {
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                }
                let requestBody = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let context = try #require(requestBody["context"] as? [String: Any])
                #expect(context["draft_id"] == nil)
                bodies.append(data)
                if bodies.count == 1 { throw URLError(.timedOut) }
                return Data(#"{"id":"run","state":"completed"}"#.utf8)
            }
            if request.url!.path.hasSuffix("/events") { return Data("id: 1\nevent: completed\ndata: {}\n\n".utf8) }
            if request.url!.path == "/api/v1/agent/runs/run" { return Data(#"{"id":"run","state":"completed"}"#.utf8) }
            if request.url!.path == "/api/v1/sessions/s" { return Data(#"{"items":[],"runs":[]}"#.utf8) }
            return Data(#"{"items":[]}"#.utf8)
        }
        model.activate("s"); model.input = "合成提问"; model.allMaterials = true
        await model.send(model: app)
        #expect(model.input == "合成提问"); #expect(!model.sending)
        await model.send(model: app)
        #expect(bodies.count == 2); #expect(bodies[0] == bodies[1]); #expect(model.input.isEmpty)
        await Task.yield()
    }
}

@Suite(.serialized) struct AssistantLayoutTests {
    @MainActor @Test func nativeSplitKeepsWidthAndReleasesCollapsedSpace() {
        let controller = AssistantSplitController(); controller.preferredWidth = 380
        controller.install(main: AnyView(Color.clear), assistant: AnyView(Color.clear), visible: true)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1360, height: 760)
        controller.view.layoutSubtreeIfNeeded()
        #expect(abs(controller.splitView.arrangedSubviews.last!.frame.width - 380) < 1)
        controller.splitView.setPosition(900, ofDividerAt: 0)
        controller.splitView(controller.splitView, resizeSubviewsWithOldSize: controller.splitView.bounds.size)
        #expect(abs(controller.splitView.arrangedSubviews.last!.frame.width - 459) < 1)
        controller.view.frame.size = NSSize(width: 1100, height: 580)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.splitView.arrangedSubviews.first!.frame.width >= 740)
        #expect(controller.splitView.arrangedSubviews.last!.frame.width >= 320)
        controller.update(main: AnyView(Color.clear), assistant: AnyView(Color.clear), visible: false)
        #expect(controller.splitView.arrangedSubviews.count == 1)
        #expect(abs(controller.splitView.arrangedSubviews.first!.frame.width - 1100) < 1)
    }
}
