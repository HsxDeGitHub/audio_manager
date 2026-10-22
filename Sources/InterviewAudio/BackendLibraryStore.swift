import Foundation
import AudioCore

/// 兼容原界面调用的远程代理；不打开任何 SQLite 文件。
final class BackendLibraryStore {
    private let connection: BackendConnection
    private let session: URLSession
    private var versions: [String: Int] = [:]
    private let onTransportFailure: (@Sendable () -> Void)?
    init(connection: BackendConnection, onTransportFailure: (@Sendable () -> Void)? = nil) {
        self.onTransportFailure = onTransportFailure
        self.connection = connection
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: BackendSessionDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    private final class ResultBox: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<Data, Error>?
        func set(_ value: Result<Data, Error>) { lock.lock(); defer { lock.unlock() }; result = value }
        func get() -> Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }
    func json(_ action: String, _ args: [String: Any] = [:], operationID: String? = nil) throws -> Data {
        let read = ["recordings", "runs", "segments", "speakerNames", "historyLabel", "readingCache", "aiDrafts", "versions"].contains(action)
        let body: [String: Any] = ["action": action, "arguments": args, "operation_id": operationID ?? UUID().uuidString,
                                   "expected_versions": read ? [:] : versions]
        let data = try request("/api/v1/library/execute", method: "POST", body: body)
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let value = envelope?["value"], let revisions = envelope?["versions"] as? [String: Int] else { throw BackendClientError.invalidResponse }
        versions = revisions
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> Data {
        var request = URLRequest(url: connection.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = method
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let onFailure = onTransportFailure
        let box = ResultBox(), semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                if (error as? URLError)?.code != .cancelled { onFailure?() }
                box.set(.failure((error as? URLError)?.code == .timedOut ? BackendClientError.timedOut : BackendClientError.unavailable)); return
            }
            guard let response = response as? HTTPURLResponse, let data else { box.set(.failure(BackendClientError.invalidResponse)); return }
            switch response.statusCode {
            case 200: box.set(.success(data))
            case 401: box.set(.failure(BackendClientError.unauthorized))
            case 404: box.set(.failure(BackendClientError.notFound))
            case 409: box.set(.failure(BackendClientError.conflict))
            case 422: box.set(.failure(BackendClientError.invalidRequest))
            default: box.set(.failure(BackendClientError.unavailable))
            }
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 6) == .success else { task.cancel(); throw BackendClientError.timedOut }
        guard let result = box.get() else { throw BackendClientError.invalidResponse }
        return try result.get()
    }
    private func decode<T: Decodable>(_ action: String, _ args: [String: Any] = [:]) throws -> T { try JSONDecoder().decode(T.self, from: json(action, args)) }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    func contentRevision(_ kind: String, id: String) -> Int { versions["\(kind):\(id)"] ?? 1 }
    func recordings() throws -> [Recording] { try decode("recordings") }
    func save(_ r: Recording) throws { _ = try json("save", ["recording": object(r)]) }
    func remove(_ id: String) throws { _ = try json("remove", ["id": id]) }
    func runs(recordingID: String) throws -> [TranscriptRun] {
        struct Run: Decodable { let id: String; let createdAt: Double; let hasEdits: Bool }
        let values: [Run] = try decode("runs", ["recordingID": recordingID])
        return values.map { TranscriptRun(id: $0.id, createdAt: $0.createdAt, hasEdits: $0.hasEdits) }
    }
    @discardableResult func addTranscript(recordingID: String, runID: String, segments: [TranscriptSegment], duration: Double?) throws -> Bool {
        try decode("addTranscript", ["recordingID": recordingID, "runID": runID, "segments": object(segments), "duration": duration as Any? ?? NSNull()])
    }
    func segments(runID: String) throws -> [TranscriptSegment] { try decode("segments", ["runID": runID]) }
    func speakerNames(runID: String) throws -> [Int: String] { let names: [String: String] = try decode("speakerNames", ["runID": runID]); return Dictionary(uniqueKeysWithValues: names.compactMap { k, v in Int(k).map { ($0, v) } }) }
    func historyLabel(runID: String, redo: Bool = false) throws -> String? { try decode("historyLabel", ["runID": runID, "redo": redo]) }
    @discardableResult func restoreEdit(runID: String, redo: Bool = false) throws -> Bool { try decode("restoreEdit", ["runID": runID, "redo": redo]) }
    func saveCorrection(segmentID: String, text: String?, markReviewed: Bool) throws { _ = try json("saveCorrection", ["segmentID": segmentID, "text": text as Any? ?? NSNull(), "markReviewed": markReviewed]) }
    func editText(segmentID: String, text: String) throws { try editTexts([segmentID: text]) }
    func editTexts(_ edits: [String: String]) throws { _ = try json("editTexts", ["edits": edits]) }
    func editSpeaker(segmentID: String, speaker: Int?) throws { try editSpeakers(segmentIDs: [segmentID], speaker: speaker) }
    func editSpeakers(segmentIDs: [String], speaker: Int?) throws { _ = try json("editSpeakers", ["segmentIDs": segmentIDs, "speaker": speaker as Any? ?? NSNull()]) }
    func markReviewed(segmentIDs: [String], reviewed: Bool) throws { _ = try json("markReviewed", ["segmentIDs": segmentIDs, "reviewed": reviewed]) }
    func mergeSpeakers(runID: String, sources: Set<Int>, target: Int) throws { _ = try json("mergeSpeakers", ["runID": runID, "sources": Array(sources), "target": target]) }
    func renameSpeaker(runID: String, speaker: Int, name: String) throws { _ = try json("renameSpeaker", ["runID": runID, "speaker": speaker, "name": name]) }
    func applySpeakers(runID: String, turns: [SpeakerTurn]) throws { _ = try json("applySpeakers", ["runID": runID, "turns": object(turns)]) }
    func readingCache(runID: String) throws -> [String: [String: String]] { try decode("readingCache", ["runID": runID]) }
    func saveReadingCache(runID: String, key: String, rendered: [String: String]) throws { _ = try json("saveReadingCache", ["runID": runID, "key": key, "rendered": rendered]) }
    func aiDrafts(runID: String) throws -> [AIDraft] { try decode("aiDrafts", ["runID": runID]) }
    func editAIDraftBlock(draftID: String, blockID: String, title: String, text: String) throws -> AssistantChange {
        let data = try request("/api/v1/changesets", method: "POST", body: ["operation_id": UUID().uuidString,
            "targets": [["resource_type": "draft", "resource_id": draftID, "expected_revision": versions["draft:\(draftID)"] ?? 1,
                         "fields": ["blocks": [blockID: ["title": title, "text": text]]]]]])
        return try JSONDecoder().decode(AssistantChange.self, from: data)
    }
    func saveAIDraft(_ draft: AIDraft) throws { _ = try json("saveAIDraft", ["draft": object(draft)]) }
    func search(_ term: String, recordingID: String? = nil, punctuate: Bool = true, paragraphBreaks: Bool = true, density: ReadingDensity = .balanced, smartPunctuation: Bool = false) throws -> [SearchHit] {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var results: [SearchHit] = []
        for r in try recordings() where recordingID == nil || r.id == recordingID {
            guard let run = r.activeRun else { continue }
            let groups = UtteranceGrouping.make(try segments(runID: run)), cache = smartPunctuation ? try readingCache(runID: run) : [:]
            let overrides = groups.reduce(into: [String: String]()) { value, group in if let saved = cache[PunctuationProjection.key(group.segments)] { value.merge(saved) { _, new in new } } }
            results += TranscriptSearch.find(term, utterances: groups, recordingID: r.id, recordingTitle: r.title, names: try speakerNames(runID: run), punctuate: punctuate, paragraphBreaks: paragraphBreaks, density: density, overrides: overrides)
        }
        return results
    }
}
