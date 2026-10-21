import Foundation
import Darwin
import Testing
import AudioCore
@testable import InterviewAudio

private final class BackendStubProtocol: URLProtocol, @unchecked Sendable {
    // 此套件串行执行，每项测试结束后清空处理器。
    static var respond: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try #require(Self.respond)
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func bodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

@Suite(.serialized) final class BackendContractTests {
    private let token = "synthetic-backend-token"
    deinit { BackendStubProtocol.respond = nil }

    private func client(timeout: TimeInterval = 2) throws -> BackendClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackendStubProtocol.self]
        return try BackendClient(baseURL: URL(string: "http://127.0.0.1:18765")!, token: token,
                                 timeout: timeout, configuration: config)
    }

    private var recording: String {
        #"{"id":"r1","title":"合成面试","path":"/synthetic/a.wav","bookmark":"Ym9va21hcmstZGF0YQ==","fingerprint":"hash-a","duration":60.5,"created_at":100,"state":"interrupted","error":null,"speaker_count":2,"play_position":8.5,"active_run":"run1","kind":"unknown","interview_date":null,"company":null,"role":null,"revision":1}"#
    }

    private func page(_ items: String, total: Int = 1, offset: Int = 0, limit: Int = 50) -> Data {
        Data("{\"items\":[\(items)],\"total\":\(total),\"offset\":\(offset),\"limit\":\(limit)}".utf8)
    }

    @Test func configurationRejectsNonLocalAddressesAndUnsafeTokens() throws {
        for url in ["https://example.test", "http://localhost:8765", "http://127.0.0.1.evil.test:8765",
                    "http://127.0.0.2:8765", "https://127.0.0.1:8765", "http://127.0.0.1",
                    "http://user@127.0.0.1:8765", "http://127.0.0.1:8765/api",
                    "http://127.0.0.1:8765/?token=x", "http://127.0.0.1:8765/#part",
                    "http://127.0.0.1:0", "http://127.0.0.1:65536"] {
            #expect(throws: BackendClientError.invalidConfiguration) {
                try BackendClient(baseURL: URL(string: url)!, token: token)
            }
        }
        for bad in ["", "two words", "secret\r\nX-Key: injected", "中文", "\u{7f}"] {
            #expect(throws: BackendClientError.invalidConfiguration) {
                try BackendClient(baseURL: URL(string: "http://127.0.0.1:8765")!, token: bad)
            }
        }
        for timeout in [0.0, -1.0, .infinity, .nan] {
            #expect(throws: BackendClientError.invalidConfiguration) { try client(timeout: timeout) }
        }
        let c = try client()
        #expect(!String(describing: c).contains(token))
        #expect(!String(reflecting: c).contains(token))
    }

    @Test func healthAndStatusKeepAuthenticationAndCapabilitiesSeparate() async throws {
        let expectedToken = token
        BackendStubProtocol.respond = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil && request.url?.query == nil)
            #expect(request.timeoutInterval == 2)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            if request.url?.path == "/health" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return (200, Data(#"{"status":"ok","service":"interview-audio-backend","version":"0.1.0"}"#.utf8))
            }
            #expect(request.url?.path == "/api/v1/system/status")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + expectedToken)
            return (200, Data(#"{"schema_revision":"0001_backend_baseline","legacy_imported":false,"counts":{"recordings":0},"capabilities":{"library_read":true,"agent":false}}"#.utf8))
        }
        let c = try client()
        #expect(try await c.health().version == "0.1.0")
        let status = try await c.status()
        #expect(status.schemaRevision == "0001_backend_baseline" && !status.legacyImported)
        #expect(status.counts["recordings"] == 0)
        #expect(status.supports("library_read"))
        #expect(!status.supports("agent") && !status.supports("business_write"))
    }

    @Test func recordingDecodesAllFieldsWithoutInventingBusinessFacts() async throws {
        let data = Data(recording.utf8), expectedToken = token
        BackendStubProtocol.respond = { request in
            #expect(request.url?.path == "/api/v1/recordings/r1")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + expectedToken)
            return (200, data)
        }
        let r = try await client().recording(id: "r1")
        #expect(r.id == "r1" && r.title == "合成面试" && r.path == "/synthetic/a.wav")
        #expect(r.bookmark == Data("bookmark-data".utf8))
        #expect(r.fingerprint == "hash-a" && r.duration == 60.5 && r.createdAt == 100)
        #expect(r.state == "interrupted" && r.error == nil && r.speakerCount == 2)
        #expect(r.playPosition == 8.5 && r.activeRun == "run1" && r.revision == 1)
        #expect(r.kind == "unknown" && r.interviewDate == nil && r.company == nil && r.role == nil)
        let unknown = recording.replacingOccurrences(of: "interrupted", with: "future_state")
            .replacingOccurrences(of: "\"bookmark\":\"Ym9va21hcmstZGF0YQ==\"", with: "\"bookmark\":null")
        BackendStubProtocol.respond = { _ in (200, Data(unknown.utf8)) }
        let future = try await client().recording(id: "r1")
        #expect(future.state == "future_state" && future.bookmark == nil)
    }

    @Test func eachReadEndpointUsesExplicitPaginationAndKeepsSourceFields() async throws {
        let recordPage = page(recording, total: 3, offset: 1, limit: 1)
        let runPage = page(#"{"id":"run1","recording_id":"r1","created_at":101}"#)
        let segmentPage = page(#"{"id":"s1","run_id":"run1","start":1.25,"end":3.5,"original":"原始回答","edited":"","text":"","speaker":null,"speaker_edited":false,"needs_review":true,"reviewed":false}"#)
        let speakerPage = page(#"{"speaker":1,"name":"回答者"}"#)
        let draftPage = page(#"{"id":"draft1","run_id":"run1","created_at":102,"payload":{"sourceIDs":["s1"],"source_ids":["原始键"],"nested":{"runID":"run1"},"flag":true,"empty":null,"count":9007199254740993}}"#)
        let dataByPath = ["/api/v1/recordings": recordPage, "/api/v1/recordings/r1/runs": runPage,
                          "/api/v1/transcripts/run1/segments": segmentPage,
                          "/api/v1/transcripts/run1/speakers": speakerPage,
                          "/api/v1/transcripts/run1/drafts": draftPage]
        BackendStubProtocol.respond = { request in
            let path = try #require(request.url?.path)
            let parts = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value) })
            #expect(query["offset"] == (path == "/api/v1/recordings" ? "1" : "0"))
            #expect(query["limit"] == (path == "/api/v1/recordings" ? "1" : "50"))
            return (200, try #require(dataByPath[path]))
        }
        let c = try client()
        let recordings = try await c.recordings(offset: 1, limit: 1)
        #expect(recordings.items.count == 1 && recordings.total == 3)
        #expect(recordings.offset == 1 && recordings.limit == 1)
        let run = try #require(await c.runs(recordingID: "r1").items.first)
        #expect(run.id == "run1" && run.recordingID == "r1" && run.createdAt == 101)
        let segment = try #require(await c.segments(runID: "run1").items.first)
        #expect(segment.id == "s1" && segment.runID == "run1" && segment.start == 1.25 && segment.end == 3.5)
        #expect(segment.original == "原始回答" && segment.edited == "" && segment.text == "")
        #expect(segment.speaker == nil && !segment.speakerEdited && segment.needsReview && !segment.reviewed)
        let speaker = try #require(await c.speakers(runID: "run1").items.first)
        #expect(speaker.speaker == 1 && speaker.name == "回答者")
        let draft = try #require(await c.drafts(runID: "run1").items.first)
        #expect(draft.id == "draft1" && draft.runID == "run1" && draft.createdAt == 102)
        #expect(draft.payload["sourceIDs"] == .array([.string("s1")]))
        #expect(draft.payload["source_ids"] == .array([.string("原始键")]))
        #expect(draft.payload["nested"] == .object(["runID": .string("run1")]))
        #expect(draft.payload["flag"] == .bool(true) && draft.payload["empty"] == .null)
        #expect(draft.payload["count"] == .integer(9_007_199_254_740_993))
    }

    @Test func emptyPagesAndReservedCharactersDoNotChangeRequestScope() async throws {
        let empty = page("", total: 0)
        BackendStubProtocol.respond = { request in
            let url = try #require(request.url)
            #expect(url.query == "offset=0&limit=50")
            #expect(url.absoluteString.contains("%3F%23%25"))
            #expect(url.path.hasSuffix("/runs"))
            return (200, empty)
        }
        let result = try await client().runs(recordingID: "中文 ?#%")
        #expect(result.items.isEmpty && result.total == 0)
        let beyondEnd = page("", total: 0, offset: 500)
        BackendStubProtocol.respond = { _ in (200, beyondEnd) }
        #expect(try await client().recordings(offset: 500).items.isEmpty)
    }

    @Test func invalidPaginationAndIdentifiersNeverSendARequest() async throws {
        BackendStubProtocol.respond = { _ in Issue.record("无效参数不应发起请求"); return (500, Data()) }
        let c = try client()
        for (offset, limit) in [(-1, 50), (0, 0), (0, 201)] {
            await #expect(throws: BackendClientError.invalidRequest) { try await c.recordings(offset: offset, limit: limit) }
        }
        for id in ["", ".", "..", "r1/runs", "r1\\runs", "\n"] {
            await #expect(throws: BackendClientError.invalidRequest) { try await c.recording(id: id) }
        }
    }

    @Test func httpFailuresAreTypedAndNeverExposeServerContent() async throws {
        let c = try client()
        let cases: [(Int, BackendClientError)] = [(401, .unauthorized), (404, .notFound), (409, .conflict),
            (422, .invalidRequest), (503, .unavailable), (500, .httpStatus(500)), (302, .httpStatus(302))]
        for (status, expected) in cases {
            BackendStubProtocol.respond = { _ in
                (status, Data(#"{"error":{"code":"private_code","message":"synthetic-backend-token SELECT private-transcript"}}"#.utf8))
            }
            do { _ = try await c.recording(id: "r1"); Issue.record("应拒绝 HTTP 错误") }
            catch {
                #expect(error as? BackendClientError == expected)
                #expect(!error.localizedDescription.contains("synthetic-backend-token"))
                #expect(!error.localizedDescription.contains("private-transcript"))
                #expect(!String(reflecting: error).contains("SELECT"))
            }
        }
    }

    @Test func invalidResponsesCannotBecomeSuccessfulResults() async throws {
        let invalid = ["not JSON private-transcript", "{}", recording.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":0"),
            recording.replacingOccurrences(of: "Ym9va21hcmstZGF0YQ==", with: "bad-base64!"),
            recording.replacingOccurrences(of: "\"duration\":60.5", with: "\"duration\":\"private-transcript\"")]
        for body in invalid {
            BackendStubProtocol.respond = { _ in (200, Data(body.utf8)) }
            await #expect(throws: BackendClientError.invalidResponse) { try await self.client().recording(id: "r1") }
        }
        for data in [page(recording, total: -1), page(recording, limit: 0), page(recording, offset: 1), page(recording, limit: 1)] {
            BackendStubProtocol.respond = { _ in (200, data) }
            await #expect(throws: BackendClientError.invalidResponse) { try await self.client().recordings() }
        }
        for body in [#"{"status":"ok","service":"other-service","version":"0.1.0"}"#,
                     #"{"status":"starting","service":"interview-audio-backend","version":"0.1.0"}"#] {
            BackendStubProtocol.respond = { _ in (200, Data(body.utf8)) }
            await #expect(throws: BackendClientError.invalidResponse) { try await self.client().health() }
        }
    }

    @Test func timeoutDisconnectionAndCancellationRemainDistinct() async throws {
        for (code, expected) in [(URLError.timedOut, BackendClientError.timedOut), (.cannotConnectToHost, .unavailable),
                                 (.networkConnectionLost, .unavailable), (.notConnectedToInternet, .unavailable)] {
            BackendStubProtocol.respond = { _ in throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "private-transcript"]) }
            await #expect(throws: expected) { try await self.client().health() }
        }
        BackendStubProtocol.respond = { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await self.client().health() }
        BackendStubProtocol.respond = { _ in Issue.record("已取消任务不应发送请求"); return (500, Data()) }
        let c = try client()
        let task = Task {
            try? await Task.sleep(nanoseconds: 10_000_000)
            return try await c.health()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTERVIEW_BACKEND_CONTRACT_INTEGRATION"] == "1"))
    func realBackendReadsAndTransportFailuresUseOnlySyntheticData() async throws {
        let server = try BackendFixtureServer()
        defer { server.stop() }
        let baseURL = try await server.waitUntilReady()
        let c = try BackendClient(baseURL: baseURL, token: token, timeout: 2)
        #expect(try await c.health().status == "ok")
        let status = try await c.status()
        #expect(status.legacyImported && status.counts["recordings"] == 2)
        #expect(status.supports("library_read") && status.supports("business_write"))
        let first = try await c.recordings(limit: 1), second = try await c.recordings(offset: 1, limit: 1)
        #expect(first.total == 2 && first.items.first?.id == "r2" && second.items.first?.id == "r1")
        let r = try await c.recording(id: "r1")
        #expect(r.bookmark == Data("bookmark-data".utf8) && r.interviewDate == nil && r.revision == 1)
        #expect(try await c.runs(recordingID: "r1").items.first?.id == "run1")
        let segments = try await c.segments(runID: "run1")
        #expect(segments.items.map(\.id) == ["s1", "s2"])
        #expect(segments.items.last?.text == "校对后的回答" && segments.items.last?.speakerEdited == true)
        #expect(try await c.segments(runID: "run2").items.first?.edited == "")
        #expect(try await c.speakers(runID: "run1").items.map(\.name) == ["提问者", "回答者"])
        let draft = try #require(await c.drafts(runID: "run1").items.first)
        #expect(draft.payload["chunks"] == .array([.object(["blocks": .array([
            .object(["text": .string("合成整理稿"), "sourceIDs": .array([.string("s1")])])])])]))
        #expect(try await c.drafts(runID: "run2").items.isEmpty)
        struct Source: Decodable { let recording_id: String; let segment_id: String; let start: Double }
        let source: Source = try await c.send("/api/v1/sources/segment/s1?revision=1")
        #expect(source.recording_id == "r1" && source.segment_id == "s1" && source.start == 1)
        let session: AssistantAcknowledgment = try await c.send("/api/v1/sessions", method: "POST", body: JSONSerialization.data(withJSONObject: ["title": "合成对话", "scope": [:]]))
        let run: AssistantAcknowledgment = try await c.send("/api/v1/agent/runs", method: "POST", body: JSONSerialization.data(withJSONObject: ["session_id": session.id, "instruction": "分析当前资料", "context": ["recording_id": "r1"]]))
        var events: [BackendClient.Event] = []
        for try await event in c.events(runID: run.id, after: 0) { events.append(event) }
        #expect(events.contains { $0.kind == "failed" }) // 临时资料没有模型配置，真实状态必须报告失败。
        #expect(events.map(\.id) == events.map(\.id).sorted())
        await #expect(throws: BackendClientError.notFound) { try await c.recording(id: "absent") }
        let unauthenticated = try BackendClient(baseURL: baseURL, token: "wrong-synthetic-token")
        await #expect(throws: BackendClientError.unauthorized) { try await unauthenticated.status() }
        // 重定向若被跟随，测试服务会留下标记；不能只靠模拟状态码验证。
        await #expect(throws: BackendClientError.httpStatus(302)) { try await c.recording(id: "fixture-redirect") }
        #expect(!server.hasMarker("redirect-followed"))
        let impatient = try BackendClient(baseURL: baseURL, token: token, timeout: 0.15)
        await #expect(throws: BackendClientError.timedOut) { try await impatient.recording(id: "fixture-timeout") }
        let task = Task { try await c.recording(id: "fixture-cancel") }
        try await server.waitForMarker("cancel-started")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        server.stop()
        await #expect(throws: BackendClientError.unavailable) { try await c.status() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["INTERVIEW_BACKEND_CONTRACT_INTEGRATION"] == "1"))
    @MainActor func managedProcessAndLibraryProxyPreserveEditsTimelineAndExports() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("backend-parity-\(UUID().uuidString)")
        let manager = BackendProcess()
        defer { manager.stop(); try? FileManager.default.removeItem(at: folder) }
        let segments = [TranscriptSegment(id: "parity-s", start: 61.25, end: 65, original: "原稿", edited: "人工校对", speaker: 0)]
        let r = Recording(id: "parity-r", title: "合成兼容资料", path: "/synthetic.wav", fingerprint: "synthetic", duration: 100)
        let expected = TranscriptExport.render(title: r.title, segments: segments, names: [0: "面试官"], srt: true)
        do {
            let legacy = try LibraryStore(url: folder.appendingPathComponent("library.sqlite"))
            try legacy.save(r)
            try legacy.addTranscript(recordingID: r.id, runID: "parity-run", segments: segments, duration: nil)
            try legacy.renameSpeaker(runID: "parity-run", speaker: 0, name: "面试官")
        }
        let connection = try await manager.start(dataDirectory: folder)
        let proxy = BackendLibraryStore(connection: connection)
        #expect(try proxy.recordings().first?.activeRun == "parity-run")
        let actual = try proxy.segments(runID: "parity-run"), names = try proxy.speakerNames(runID: "parity-run")
        #expect(TranscriptExport.render(title: r.title, segments: actual, names: names, srt: true) == expected)
        #expect(TranscriptExport.render(title: r.title, segments: actual, names: names, srt: false, plainDialogue: true).contains("人工校对"))
        #expect(try proxy.restoreEdit(runID: "parity-run"))
        #expect(try proxy.speakerNames(runID: "parity-run").isEmpty)
        #expect(try proxy.restoreEdit(runID: "parity-run", redo: true))
        try proxy.editText(segmentID: "parity-s", text: "后端修正")
        #expect(try proxy.restoreEdit(runID: "parity-run"))
        #expect(try proxy.segments(runID: "parity-run").first?.text == "人工校对")
        manager.stop()
        let restarted = BackendLibraryStore(connection: try await manager.start(dataDirectory: folder))
        #expect(try restarted.historyLabel(runID: "parity-run", redo: true) == "修改文字")
        #expect(try restarted.restoreEdit(runID: "parity-run", redo: true))
        #expect(try restarted.segments(runID: "parity-run").first?.text == "后端修正")
    }

    @Test func metadataAndMemoryUseVersionedBusinessEndpoints() async throws {
        let expectedToken = token
        BackendStubProtocol.respond = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + expectedToken)
            #expect(request.httpMethod == "PATCH")
            let body = try #require(bodyData(request))
            let value = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(value["expected_revision"] as? Int == 3)
            if request.url?.path == "/api/v1/recordings/r1" {
                let fields = try #require(value["fields"] as? [String: Any])
                #expect(fields["kind"] as? String == "interview")
                #expect(fields["interview_date"] as? String == "2026-10-19")
                return (200, Data(#"{"id":"metadata-1","state":"committed","count":1,"items":[]}"#.utf8))
            }
            #expect(request.url?.path == "/api/v1/memories/m1")
            let fields = try #require(value["fields"] as? [String: Any])
            #expect(fields["state"] as? String == "disabled")
            return (200, Data(#"{"id":"memory-1","state":"committed","count":1,"items":[]}"#.utf8))
        }
        let c = try client()
        let fields: [String: Any] = ["kind": "interview", "interview_date": "2026-10-19", "company": NSNull()]
        let metadataBody = try JSONSerialization.data(withJSONObject: ["operation_id": "metadata-1",
                                                                       "expected_revision": 3, "fields": fields])
        struct Receipt: Decodable { let id: String; let state: String; let count: Int }
        let receipt: Receipt = try await c.send("/api/v1/recordings/r1", method: "PATCH", body: metadataBody)
        #expect(receipt.id == "metadata-1" && receipt.state == "committed" && receipt.count == 1)
        let memoryBody = try JSONSerialization.data(withJSONObject: ["operation_id": "memory-1",
                                                                     "expected_revision": 3, "fields": ["state": "disabled"]])
        let memory: Receipt = try await c.send("/api/v1/memories/m1", method: "PATCH", body: memoryBody)
        #expect(memory.id == "memory-1")

        let json = Data(#"{"id":"m1","category":"preference","content":"偏好先说明背景","scope":"global","sources":[{"resource_type":"message","resource_id":"msg1","revision":1}],"topic":"表达方式","state":"active","supersedes":null,"revision":2}"#.utf8)
        let item = try JSONDecoder().decode(MemoryItem.self, from: json)
        #expect(item.categoryTitle == "偏好" && item.stateTitle == "生效" && item.revision == 2)
        #expect(item.sources.first?.resourceType == "message" && item.sources.first?.resourceID == "msg1")
    }
}

private final class BackendFixtureServer {
    private let directory: URL
    private let process = Process()
    private var stopped = false

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("backend-swift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = root.appendingPathComponent("backend/.venv/bin/python")
        process.arguments = [root.appendingPathComponent("backend/tests/swift_fixture.py").path, directory.path]
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { stop(); try? FileManager.default.removeItem(at: directory) }

    func hasMarker(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }

    func waitUntilReady() async throws -> URL {
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("ready.json")),
               let ready = try? JSONDecoder().decode([String: String].self, from: data),
               let raw = ready["url"], let url = URL(string: raw) {
                let c = try BackendClient(baseURL: url, token: "synthetic-backend-token", timeout: 0.5)
                if (try? await c.health()) != nil { return url }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw AudioFixtureError.startupFailed
    }

    func waitForMarker(_ name: String) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if hasMarker(name) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AudioFixtureError.requestDidNotStart
    }

    func stop() {
        guard !stopped else { return }; stopped = true
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private enum AudioFixtureError: Error { case startupFailed, requestDidNotStart }
}
