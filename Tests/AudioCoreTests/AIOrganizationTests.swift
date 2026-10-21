import Foundation
import Testing
import AudioCore

private final class AIStubProtocol: URLProtocol, @unchecked Sendable {
    static var respond: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let respond = Self.respond else { throw URLError(.badServerResponse) }
            let (status, data) = try respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) final class AIOrganizationTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    deinit { AIStubProtocol.respond = nil; try? FileManager.default.removeItem(at: folder) }
    private func settings() -> AISettings {
        var s = AISettings(); s.baseURL = "https://example.test/v1/"; s.model = "test-model"; s.apiKey = "fixture-secret"
        return s
    }
    private func sources() -> [AISource] {
        AISource.snapshot(segments: [
            TranscriptSegment(id: "a", start: 0, end: 2, original: "原始识别", edited: "请介绍项目。", speaker: 0),
            TranscriptSegment(id: "b", start: 3, end: 8, original: "我做过 Go 服务端。", speaker: 1)
        ], names: [0: "提问者",1: "回答者"])
    }
    private func draft(_ mode: AIOrganizationMode = .dialogue) throws -> AIDraft {
        try AIDraft(runID: "run", recordingID: "recording", title: "测试访谈", settings: settings(), mode: mode, instructions: "保留具体例子", sources: sources())
    }
    private func client() -> AIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AIStubProtocol.self]
        return AIClient(session: URLSession(configuration: config))
    }
    private func response(_ text: String, finish: String = "stop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": finish]]])
    }
    private static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try #require(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
    @Test func configurationCanBeEditedDirectlyAndEndpointIsNormalized() throws {
        let minimal = Data(#"{"baseURL":"http://localhost:11434/v1","model":"local-model"}"#.utf8)
        let s = try JSONDecoder().decode(AISettings.self, from: minimal)
        try s.validate()
        #expect(s.apiKey.isEmpty && s.chunkCharacters == 4500)
        #expect(try s.endpoint().absoluteString == "http://localhost:11434/v1/chat/completions")
        var complete = s; complete.baseURL = "https://example.test/chat/completions"
        #expect(try complete.endpoint().absoluteString == complete.baseURL)
        for bad in ["", "file:///tmp/model", "https://key@example.test", "https://example.test?key=secret", "https://example.test/#part"] {
            complete.baseURL = bad
            #expect(throws: (any Error).self) { try complete.validate() }
        }
        let url = folder.appendingPathComponent("llm-settings.json")
        try settings().save(to: url)
        #expect(try AISettings.load(from: url) == settings())
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
    @Test func snapshotUsesCorrectionsAndFingerprintTracksNamesAndContent() {
        let original = sources()
        #expect(original[0].text == "请介绍项目。")
        #expect(original[0].speaker == "提问者")
        #expect(original[0].id == "a" && original[0].start == 0)
        #expect(AISource.fingerprint(original) == AISource.fingerprint(sources()))
        var changed = original; changed[0].speaker = "新名字"
        #expect(AISource.fingerprint(original) != AISource.fingerprint(changed))
        changed = original; changed[0].text += "修改"
        #expect(AISource.fingerprint(original) != AISource.fingerprint(changed))
    }
    @Test func longUnicodeSegmentAndTinySegmentsAreNeverTruncated() throws {
        var config = settings(); config.chunkCharacters = 500
        let text = String(repeating: "中文🙂", count: 800)
        let raw = [TranscriptSegment(id: "long", start: 0, end: 500, original: text, speaker: 0)]
        let d = try AIDraft(runID: "run", recordingID: "recording", title: "长录音", settings: config, mode: .dialogue, instructions: "", sources: AISource.snapshot(segments: raw, names: [:]))
        #expect(d.chunks.count == 5)
        #expect(d.chunks.flatMap(\.sources).map(\.text).joined() == text)
        #expect(d.chunks.allSatisfy { $0.sources.map(\.text).joined().count <= 500 })
        #expect(d.chunks.flatMap(\.sources).allSatisfy { $0.id == "long" && $0.start == 0 })
        #expect(!d.chunks[1].context.isEmpty)
        let tiny = (0..<125).map { TranscriptSegment(id: "id\($0)", start: Double($0), end: Double($0+1), original: "嗯") }
        let tinyDraft = try AIDraft(runID: "run", recordingID: "recording", title: "短句", settings: config, mode: .dialogue, instructions: "", sources: AISource.snapshot(segments: tiny, names: [:]))
        #expect(tinyDraft.chunks.count == 3)
        #expect(tinyDraft.chunks.flatMap(\.sources).map(\.id) == tiny.map(\.id))
    }
    @Test func outputRequiresValidReferencesAndCompleteDialogueCoverage() throws {
        let chunk = try draft().chunks[0]
        let valid = #"{"blocks":[{"title":"项目交流","text":"项目介绍与回答。","source_ids":["S1","S2"]}]}"#
        let blocks = try AIClient.parse("```json\n\(valid)\n```", chunk: chunk, requireCoverage: true)
        #expect(blocks[0].sourceIDs == ["a","b"])
        for invalid in [
            #"{"blocks":[{"text":"编造来源","source_ids":["S999"]}]}"#,
            #"{"blocks":[{"text":"缺失第二句","source_ids":["S1"]}]}"#,
            #"{"blocks":[{"text":"","source_ids":["S1","S2"]}]}"#,
            #"{"blocks":[]}"#, "不是 JSON"
        ] { #expect(throws: (any Error).self) { try AIClient.parse(invalid, chunk: chunk, requireCoverage: true) } }
        let summary = #"{"blocks":[{"text":"只提取重点。","source_ids":["S2"]}]}"#
        #expect(try AIClient.parse(summary, chunk: chunk, requireCoverage: false).count == 1)
        var withContext = chunk; withContext.sources = [chunk.sources[1]]; withContext.context = [chunk.sources[0]]
        #expect(throws: (any Error).self) { try AIClient.parse(valid, chunk: withContext, requireCoverage: false) }
    }
    @Test func draftPersistenceIsIndependentAndCascadesWithRecording() throws {
        let dbURL = folder.appendingPathComponent("library.sqlite")
        let db = try LibraryStore(url: dbURL)
        let audio = folder.appendingPathComponent("original.wav"); try Data("fixture".utf8).write(to: audio)
        let r = Recording(id: "recording", title: "测试", path: audio.path, fingerprint: "fixture", duration: 10)
        try db.save(r)
        let segment = TranscriptSegment(id: "a", start: 0, end: 2, original: "原稿", edited: "人工修正", speaker: 0)
        try db.addTranscript(recordingID: r.id, runID: "run", segments: [segment], duration: nil)
        let before = try db.segments(runID: "run")
        var d = try draft(); d.chunks[0].blocks = [AIBlock(title: "标题", text: "整理后的文字", sourceIDs: ["a","b"])]; d.state = .cancelled
        try db.saveAIDraft(d)
        let reopened = try LibraryStore(url: dbURL)
        let saved = try #require(reopened.aiDrafts(runID: "run").first)
        #expect(saved.state == .cancelled && saved.completedChunks == 1)
        #expect(saved.blocks.first?.text == "整理后的文字")
        #expect(try reopened.segments(runID: "run") == before)
        #expect(try reopened.historyLabel(runID: "run") == nil)
        #expect(try reopened.aiDrafts(runID: "other-run").isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!encoded.contains("fixture-secret") && !encoded.contains("apiKey"))
        #expect(saved.export(markdown: true).contains("# 测试访谈"))
        #expect(saved.export(markdown: false).contains("未完成"))
        d.state = .completed; try db.saveAIDraft(d)
        #expect(try db.aiDrafts(runID: "run").count == 1)
        #expect(!d.export(markdown: true).contains("未完成"))
        try db.remove(r.id)
        #expect(try db.aiDrafts(runID: "run").isEmpty)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }
    @Test func compatibleRequestUsesSnapshotAndKeepsKeyOutOfBody() async throws {
        let expected = try response(#"{"blocks":[{"title":"交流","text":"整理后的问答","source_ids":["S1","S2"]}]}"#)
        AIStubProtocol.respond = { request in
            #expect(request.url?.absoluteString == "https://example.test/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
            let data = try Self.body(request)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["model"] as? String == "test-model")
            #expect(body["max_tokens"] as? Int == 8192)
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages.count == 2)
            #expect(messages[0]["content"]?.contains("保留具体例子") == true)
            #expect(messages[1]["content"]?.contains("请介绍项目") == true)
            #expect(!String(decoding: data, as: UTF8.self).contains("fixture-secret"))
            return (200, expected)
        }
        let result = try await client().organize(settings: settings(), draft: draft(), chunkIndex: 0)
        #expect(result[0].sourceIDs == ["a","b"])
    }
    @Test func providerErrorsAndTruncatedOutputsCannotBecomeSavedResults() async throws {
        for (status, body) in [(401, Data("fixture-secret private transcript".utf8)), (200, try response("partial", finish: "length")), (200, Data("invalid JSON".utf8)), (200, try response(""))] {
            AIStubProtocol.respond = { _ in (status,body) }
            do { _ = try await client().organize(settings: settings(), draft: draft(), chunkIndex: 0); Issue.record("应拒绝无效响应") }
            catch {
                #expect(!error.localizedDescription.contains("fixture-secret"))
                #expect(!error.localizedDescription.contains("private transcript"))
            }
        }
    }
    @Test func connectionTestDoesNotSendPrivateTranscriptAndLocalKeyMayBeEmpty() async throws {
        let output = try response("连接成功")
        var local = settings(); local.apiKey = ""
        AIStubProtocol.respond = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = String(decoding: try Self.body(request), as: UTF8.self)
            #expect(!body.contains("请介绍项目") && !body.contains("保留具体例子"))
            return (200,output)
        }
        try await client().test(settings: local)
    }
    @Test func cancelledTaskNeverSendsNetworkRequest() async throws {
        AIStubProtocol.respond = { _ in Issue.record("取消后不应发送请求"); return (500,Data()) }
        let c = client(), config = settings()
        let task = Task {
            try? await Task.sleep(nanoseconds: 10_000_000)
            try await c.test(settings: config)
        }
        task.cancel()
        do { try await task.value; Issue.record("应抛出取消错误") }
        catch { #expect(error is CancellationError) }
    }
}
