import Foundation

enum BackendClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration, invalidRequest, unauthorized, notFound, conflict
    case timedOut, unavailable, invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "本地服务连接配置无效，请重新启动服务。"
        case .invalidRequest: return "请求参数不合法，请检查目标和分页范围。"
        case .unauthorized: return "本地服务会话认证失效，请重新连接服务。"
        case .notFound: return "指定资料或转写版本不存在，请刷新后重试。"
        case .conflict: return "资料版本或操作状态冲突，请刷新后重试。"
        case .timedOut: return "本地服务响应超时，请稍后重试。"
        case .unavailable: return "本地服务暂时不可用，请检查服务状态后重试。"
        case .invalidResponse: return "本地服务返回的数据不符合约定，请检查服务版本。"
        case .httpStatus: return "本地服务未能完成请求，请稍后重试。"
        }
    }
}

struct BackendPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let total: Int
    let offset: Int
    let limit: Int
}

struct BackendHealth: Decodable, Sendable {
    let status: String
    let service: String
    let version: String
}

struct BackendStatus: Decodable, Sendable {
    let schemaRevision: String
    let legacyImported: Bool
    let counts: [String: Int]
    let capabilities: [String: Bool]
    func supports(_ capability: String) -> Bool { capabilities[capability] == true }
    private enum CodingKeys: String, CodingKey {
        case schemaRevision = "schema_revision", legacyImported = "legacy_imported"
        case counts, capabilities
    }
}

// 传输对象独立于旧 LibraryStore 模型；接管前不丢弃 revision 或改写历史状态。
struct BackendRecording: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let path: String
    let bookmark: Data?
    let fingerprint: String
    let duration: Double
    let createdAt: Double
    let state: String
    let error: String?
    let speakerCount: Int?
    let playPosition: Double
    let activeRun: String?
    let kind: String
    let interviewDate: String?
    let company: String?
    let role: String?
    let revision: Int
    private enum CodingKeys: String, CodingKey {
        case id, title, path, bookmark, fingerprint, duration, state, error, kind, company, role, revision
        case createdAt = "created_at", speakerCount = "speaker_count", playPosition = "play_position"
        case activeRun = "active_run", interviewDate = "interview_date"
    }
}

struct BackendTranscriptRun: Decodable, Identifiable, Sendable {
    let id: String
    let recordingID: String
    let createdAt: Double
    private enum CodingKeys: String, CodingKey {
        case id, recordingID = "recording_id", createdAt = "created_at"
    }
}

struct BackendSegment: Decodable, Identifiable, Sendable {
    let id: String
    let runID: String
    let start: Double
    let end: Double
    let original: String
    let edited: String?
    let text: String
    let speaker: Int?
    let speakerEdited: Bool
    let needsReview: Bool
    let reviewed: Bool
    private enum CodingKeys: String, CodingKey {
        case id, start, end, original, edited, text, speaker, reviewed
        case runID = "run_id", speakerEdited = "speaker_edited", needsReview = "needs_review"
    }
}

struct BackendSpeaker: Decodable, Sendable {
    let speaker: Int
    let name: String
}

struct BackendDraft: Decodable, Identifiable, Sendable {
    let id: String
    let runID: String
    let createdAt: Double
    let payload: [String: BackendJSONValue]
    private enum CodingKeys: String, CodingKey {
        case id, payload, runID = "run_id", createdAt = "created_at"
    }
}

// payload 沿用 Swift 既有键名，不能全局使用 convertFromSnakeCase。
indirect enum BackendJSONValue: Decodable, Equatable, Sendable {
    case object([String: BackendJSONValue]), array([BackendJSONValue])
    case string(String), integer(Int64), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let items = try? value.decode([BackendJSONValue].self) { self = .array(items) }
        else { self = .object(try value.decode([String: BackendJSONValue].self)) }
    }
}

final class BackendSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // 会话令牌和资料只能发送到启动时确定的本机服务，不跟随任何重定向。
        completionHandler(nil)
    }
}

final class BackendClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let baseURL: URL
    private let token: String
    private let timeout: TimeInterval
    private let session: URLSession
    var description: String { "BackendClient（本机业务服务）" }
    var debugDescription: String { description }

    init(baseURL: URL, token: String, timeout: TimeInterval = 15,
         configuration: URLSessionConfiguration = .ephemeral) throws {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", timeout.isFinite, timeout > 0,
              !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw BackendClientError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.token = token
        self.timeout = timeout
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        session = URLSession(configuration: config, delegate: BackendSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func health() async throws -> BackendHealth {
        let value: BackendHealth = try await get(["health"], authenticated: false)
        guard value.status == "ok", value.service == "interview-audio-backend", !value.version.isEmpty else {
            throw BackendClientError.invalidResponse
        }
        return value
    }

    func status() async throws -> BackendStatus {
        let value: BackendStatus = try await get(["api", "v1", "system", "status"])
        guard !value.schemaRevision.isEmpty, value.counts.values.allSatisfy({ $0 >= 0 }) else {
            throw BackendClientError.invalidResponse
        }
        return value
    }

    func recordings(offset: Int = 0, limit: Int = 50) async throws -> BackendPage<BackendRecording> {
        let value: BackendPage<BackendRecording> = try await page(["recordings"], offset: offset, limit: limit)
        guard value.items.allSatisfy({ $0.revision > 0 }) else { throw BackendClientError.invalidResponse }
        return value
    }

    func recording(id: String) async throws -> BackendRecording {
        try validateID(id)
        let value: BackendRecording = try await get(["api", "v1", "recordings", id])
        guard value.id == id, value.revision > 0 else { throw BackendClientError.invalidResponse }
        return value
    }

    func runs(recordingID: String, offset: Int = 0, limit: Int = 50) async throws -> BackendPage<BackendTranscriptRun> {
        try validateID(recordingID)
        return try await page(["recordings", recordingID, "runs"], offset: offset, limit: limit)
    }

    func segments(runID: String, offset: Int = 0, limit: Int = 50) async throws -> BackendPage<BackendSegment> {
        try validateID(runID)
        return try await page(["transcripts", runID, "segments"], offset: offset, limit: limit)
    }

    func speakers(runID: String, offset: Int = 0, limit: Int = 50) async throws -> BackendPage<BackendSpeaker> {
        try validateID(runID)
        return try await page(["transcripts", runID, "speakers"], offset: offset, limit: limit)
    }

    func drafts(runID: String, offset: Int = 0, limit: Int = 50) async throws -> BackendPage<BackendDraft> {
        try validateID(runID)
        return try await page(["transcripts", runID, "drafts"], offset: offset, limit: limit)
    }

    func send<Value: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Value {
        guard let parsed = URLComponents(string: path), parsed.scheme == nil, parsed.host == nil, parsed.fragment == nil, parsed.path.hasPrefix("/") else { throw BackendClientError.invalidRequest }
        let parts = parsed.path.split(separator: "/").map(String.init)
        for component in parts { try validateID(component) }
        return try await get(parts, query: parsed.queryItems ?? [], method: method, body: body)
    }

    struct Event: Sendable { let id: Int; let kind: String; let data: Data }
    func events(runID: String, after: Int) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validateID(runID)
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/agent/runs/\(runID)/events"), timeoutInterval: 120)
                    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    request.setValue(String(after), forHTTPHeaderField: "Last-Event-ID")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw BackendClientError.invalidResponse }
                    guard http.statusCode == 200 else { throw http.statusCode == 401 ? BackendClientError.unauthorized : BackendClientError.unavailable }
                    var identifier = after, kind = "message", lines: [String] = []
                    var buffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        guard byte == 10 else { continue }
                        let line = String(decoding: buffer.dropLast(), as: UTF8.self).trimmingCharacters(in: .newlines)
                        buffer.removeAll(keepingCapacity: true)
                        if line.isEmpty {
                            if !lines.isEmpty { continuation.yield(Event(id: identifier, kind: kind, data: Data(lines.joined(separator: "\n").utf8))) }
                            lines = []; kind = "message"
                        } else if line.hasPrefix("id: ") { identifier = Int(line.dropFirst(4)) ?? identifier }
                        else if line.hasPrefix("event: ") { kind = String(line.dropFirst(7)) }
                        else if line.hasPrefix("data: ") { lines.append(String(line.dropFirst(6))) }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()) }
                    else { continuation.finish(throwing: (error as? BackendClientError) ?? BackendClientError.unavailable) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func validateID(_ id: String) throws {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"),
              id.rangeOfCharacter(from: .controlCharacters) == nil else { throw BackendClientError.invalidRequest }
    }

    private func page<Item>(_ path: [String], offset: Int, limit: Int) async throws -> BackendPage<Item> {
        guard offset >= 0, (1...200).contains(limit) else { throw BackendClientError.invalidRequest }
        let value: BackendPage<Item> = try await get(["api", "v1"] + path, query: [
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))])
        guard value.offset == offset, value.limit == limit, value.total >= 0, value.items.count <= limit,
              value.items.isEmpty || (offset <= value.total && value.items.count <= value.total - offset) else {
            throw BackendClientError.invalidResponse
        }
        return value
    }

    private func get<Value: Decodable>(_ path: [String], query: [URLQueryItem] = [],
                                       authenticated: Bool = true, method: String = "GET", body: Data? = nil) async throws -> Value {
        try Task.checkCancellation()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw BackendClientError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if (error as? URLError)?.code == .timedOut { throw BackendClientError.timedOut }
            throw BackendClientError.unavailable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw BackendClientError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw BackendClientError.unauthorized
        case 404: throw BackendClientError.notFound
        case 409: throw BackendClientError.conflict
        case 422: throw BackendClientError.invalidRequest
        case 503: throw BackendClientError.unavailable
        default: throw BackendClientError.httpStatus(http.statusCode)
        }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw BackendClientError.invalidResponse }
    }
}
