import Foundation
import AudioCore

struct AssistantSession: Decodable, Identifiable { let id: String; let title: String }
struct AssistantMessageContext: Decodable { let runID: String?; private enum CodingKeys: String, CodingKey { case runID = "run_id" } }
struct AssistantMessage: Decodable, Identifiable { let id: String; let role: String; let content: String; var context: AssistantMessageContext? = nil }
struct AssistantReference: Decodable, Hashable {
    let resourceType: String; let resourceID: String; let revision: Int
    let line: Int?; let historical: Bool?; let blockID: String?
    private enum CodingKeys: String, CodingKey { case resourceType = "resource_type", resourceID = "resource_id", revision, line, historical, blockID = "block_id" }
}
struct AssistantClaim: Decodable { let text: String; let kind: String; let sources: [AssistantReference] }
struct AssistantCoveragePart: Decodable, Identifiable {
    let id: String; let resourceType: String; let resourceID: String; let revision: Int
    let charStart: Int; let charEnd: Int; let state: String; let start: Double?; let line: Int?; let title: String?
    private enum CodingKeys: String, CodingKey { case id, revision, state, start, line, title, resourceType = "resource_type", resourceID = "resource_id", charStart = "char_start", charEnd = "char_end" }
    var label: String {
        let source = title ?? start.map { "音频片段 \(TimeFormat.clock($0))" } ?? "资料文本"
        return source + (charEnd > charStart ? " · 第 \(charStart + 1)–\(charEnd) 字" : " · 空文本")
    }
    var stateTitle: String { ["pending":"未处理", "running":"处理中", "completed":"已完成", "failed":"失败，可继续", "cancelled":"已取消"][state] ?? state }
    var reference: AssistantReference { AssistantReference(resourceType: resourceType, resourceID: resourceID, revision: revision, line: line, historical: nil, blockID: nil) }
}
struct AssistantCoverage: Decodable {
    let total: Int; let covered: Int; let excluded: [BackendJSONValue]?
    let unit: String?; let sourceCovered: Int?; let sourceTotal: Int?; let parts: [AssistantCoveragePart]?
    private enum CodingKeys: String, CodingKey { case total, covered, excluded, unit, parts, sourceCovered = "source_covered", sourceTotal = "source_total" }
    var progressTitle: String { (unit == "parts" ? "资料分块" : unit == "interviews" ? "面试覆盖" : "来源覆盖") + " \(covered)/\(total)" }
}
struct AssistantPartialResult: Decodable { let answer: String }
struct AssistantChange: Decodable { let id: String; let state: String; let count: Int; let items: [BackendJSONValue]? }
struct AssistantQuestion: Decodable, Identifiable {
    let text: String; let source: AssistantReference; let start: Double?
    var id: String { "\(source.resourceType):\(source.resourceID):\(source.revision):\(text)" }
}
struct AssistantResult: Decodable {
    struct Failure: Decodable { let code: String; let message: String }
    let answer: String?; let claims: [AssistantClaim]?; let coverage: AssistantCoverage?; let changeset: AssistantChange?; let error: Failure?
    let changesets: [AssistantChange]?
    let questions: [AssistantQuestion]?
    let partialResults: [AssistantPartialResult]?
    private enum CodingKeys: String, CodingKey { case answer, claims, coverage, changeset, error, changesets, questions, partialResults = "partial_results" }
    var allChanges: [AssistantChange] { changesets ?? changeset.map { [$0] } ?? [] }
}
struct AssistantRunContext: Decodable {
    let historyOmitted: Bool?
    private enum CodingKeys: String, CodingKey { case historyOmitted = "history_omitted" }
}
struct AssistantRun: Decodable, Identifiable {
    let id: String; var state: String; let result: AssistantResult?
    var messageID: String? = nil; var output: AssistantOutput? = nil
    var context: AssistantRunContext? = nil
    private enum CodingKeys: String, CodingKey { case id, state, result, output, context, messageID = "message_id" }
}
struct AssistantHistory: Decodable { let items: [AssistantMessage]; let runs: [AssistantRun] }
struct AssistantItems<T: Decodable>: Decodable { let items: [T] }
struct AssistantAcknowledgment: Decodable { let id: String; let state: String? }

struct AssistantOutput: Decodable {
    struct Block: Decodable { let blockID: String; var text: String; private enum CodingKeys: String, CodingKey { case blockID = "block_id", text } }
    var attemptID = ""; var blocks: [Block] = []; var lastEventID = 0
    private enum CodingKeys: String, CodingKey { case attemptID = "attempt_id", blocks, lastEventID = "last_event_id" }
    var text: String { blocks.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") }
    mutating func apply(_ event: BackendClient.Event) {
        guard event.id > lastEventID else { return }; lastEventID = event.id
        guard let payload = try? JSONSerialization.jsonObject(with: event.data) as? [String: Any] else { return }
        if event.kind == "answer_reset", let attempt = payload["attempt_id"] as? String { attemptID = attempt; blocks = []; return }
        guard payload["attempt_id"] as? String == attemptID, let block = payload["block_id"] as? String else { return }
        if event.kind == "answer_start" {
            if let index = blocks.firstIndex(where: { $0.blockID == block }) { blocks[index].text = "" }
            else { blocks.append(Block(blockID: block, text: "")) }
        } else if event.kind == "answer_delta", let text = payload["text"] as? String {
            if let index = blocks.firstIndex(where: { $0.blockID == block }) { blocks[index].text += text }
            else { blocks.append(Block(blockID: block, text: text)) }
        }
    }
}

@MainActor
final class AssistantModel: ObservableObject {
    struct Conversation {
        var messages: [AssistantMessage] = []; var runs: [AssistantRun] = []
        var input = ""; var allMaterials = false; var quotedIDs: [String] = []; var quoteScope: String?
        var progress = ""; var error: String?; var activeRun: String?; var sending = false
        var outputs: [String: AssistantOutput] = [:]
        var pendingInstruction: String?; var pendingBody: Data?
        var historyVersion = 0
    }
    @Published var sessions: [AssistantSession] = []
    @Published private(set) var selectedSession: String?
    @Published private var conversations: [String: Conversation] = [:]
    @Published private(set) var client: BackendClient?
    @Published var isVisible = UserDefaults.standard.bool(forKey: "assistant.visible") {
        didSet { UserDefaults.standard.set(isVisible, forKey: "assistant.visible"); if isVisible { hasUnread = false } }
    }
    @Published var hasUnread = false
    @Published var focusRequest = UUID()
    private var listeners: [String: Task<Void, Never>] = [:]
    private var lifecycles: [String: UUID] = [:]
    private weak var app: AppModel?
    private var current: Conversation { conversations[selectedSession ?? ""] ?? Conversation() }
    var messages: [AssistantMessage] { current.messages }
    var runs: [AssistantRun] { get { current.runs } set { update(selectedSession) { $0.runs = newValue } } }
    var input: String { get { current.input } set { update(selectedSession) { $0.input = newValue } } }
    var allMaterials: Bool { get { current.allMaterials } set { update(selectedSession) { $0.allMaterials = newValue; $0.quotedIDs = []; $0.quoteScope = nil } } }
    var quotedIDs: [String] { get { current.quotedIDs } set { update(selectedSession) { $0.quotedIDs = newValue; if newValue.isEmpty { $0.quoteScope = nil } } } }
    var progress: String { current.progress }
    var error: String? { current.error }
    var activeRun: String? { current.activeRun }
    var sending: Bool { current.sending }
    var anyRunning: Bool { conversations.values.contains { $0.activeRun != nil || $0.sending } }
    var canSend: Bool { client != nil && activeRun == nil && !sending && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && input.unicodeScalars.count <= 20000 }
    var changeToken: String { messages.map(\.id).joined() + runs.map { $0.id + $0.state }.joined() + current.outputs.keys.sorted().map { "\($0):\(current.outputs[$0]?.lastEventID ?? 0)" }.joined() }
    func output(_ id: String) -> String { current.outputs[id]?.text ?? "" }
    private func update(_ session: String?, _ body: (inout Conversation) -> Void) {
        let key = session ?? ""; var value = conversations[key] ?? Conversation(); body(&value); conversations[key] = value
    }
    init(client: BackendClient? = nil) { self.client = client }
    func activate(_ id: String?) { selectedSession = id; focusRequest = UUID() }
    func bind(_ model: AppModel) { app = model }
    func toggle() { isVisible.toggle(); if isVisible { focusRequest = UUID() } }
    func quote(model: AppModel) {
        quotedIDs = model.bulkSelection.isEmpty ? model.focusSegmentID.map { [$0] } ?? [] : Array(model.bulkSelection).sorted()
        update(selectedSession) { $0.quoteScope = scopeKey(model) }
        isVisible = true; focusRequest = UUID()
    }
    private func scopeKey(_ model: AppModel) -> String { [model.selectedID ?? "", model.selected?.activeRun ?? "", model.readerShowsAI ? model.selectedAIDraftID ?? "" : ""].joined(separator: ":") }
    func contextChanged(model: AppModel) {
        let key = scopeKey(model)
        for session in Array(conversations.keys) where conversations[session]?.quoteScope != nil && conversations[session]?.quoteScope != key {
            update(session) { $0.quotedIDs = []; $0.quoteScope = nil; $0.error = "阅读资料或版本已切换，旧引用已移除，草稿已保留。" }
        }
    }
    func attach(_ connection: BackendConnection, onTransportFailure: (@Sendable () -> Void)? = nil) async throws {
        client = try BackendClient(baseURL: connection.baseURL, token: connection.token, timeout: 120, onTransportFailure: onTransportFailure)
        try await reloadSessions()
        for id in Array(conversations.keys) { update(id) { $0.error = nil } }
    }
    func reloadSessions() async throws {
        guard let client else { return }
        let page: AssistantItems<AssistantSession> = try await client.send("/api/v1/sessions")
        sessions = page.items
        if selectedSession == nil { activate(sessions.first?.id) }
        if let id = selectedSession { try await refresh(id) }
    }
    func createSession() async {
        guard let client else { return }
        do {
            let response: AssistantAcknowledgment = try await client.send("/api/v1/sessions", method: "POST", body: JSONSerialization.data(withJSONObject: ["title": "新对话", "scope": [:]]))
            let old = selectedSession
            if old == nil, let draft = conversations[""] { conversations[response.id] = draft; conversations[""] = nil }
            activate(response.id); try await reloadSessions()
        } catch { update(selectedSession) { $0.error = error.localizedDescription } }
    }
    func loadHistory() async throws { if let selectedSession { try await refresh(selectedSession) } }
    private func refresh(_ id: String) async throws {
        guard let client else { return }
        update(id) { $0.historyVersion += 1 }; let version = conversations[id]?.historyVersion
        let history: AssistantHistory = try await client.send("/api/v1/sessions/\(id)")
        guard conversations[id]?.historyVersion == version else { return }
        update(id) { value in
            value.messages = history.items; value.runs = history.runs
            for run in history.runs {
                if let snapshot = run.output, snapshot.lastEventID >= (value.outputs[run.id]?.lastEventID ?? 0) { value.outputs[run.id] = snapshot }
            }
        }
        if let run = history.runs.first(where: { ["queued", "running"].contains($0.state) }), let app, listeners[run.id] == nil { follow(run.id, session: id, model: app) }
    }
    func select(_ id: String?) async {
        activate(id?.isEmpty == true ? nil : id)
        do { try await loadHistory() } catch { update(selectedSession) { $0.error = error.localizedDescription } }
    }
    func send(model: AppModel) async {
        guard canSend, let client else { return }; app = model
        // 在首次会话创建前锁定，避免Enter与按钮同时创建两个会话。
        let original = selectedSession; update(original) { $0.sending = true; $0.error = nil }
        if selectedSession == nil { await createSession() }
        guard let id = selectedSession else { update(original) { $0.sending = false }; return }
        update(id) { $0.sending = true }
        defer { update(id) { $0.sending = false } }
        contextChanged(model: model)
        let instruction = conversations[id]?.input ?? ""
        let value = conversations[id] ?? Conversation()
        do {
            let body: Data
            if value.pendingInstruction == instruction, let saved = value.pendingBody { body = saved }
            else {
                let context: [String: Any] = ["scope": value.allMaterials ? "all" : "current", "recording_id": value.allMaterials ? NSNull() : model.selectedID as Any? ?? NSNull(),
                    "run_id": value.allMaterials ? NSNull() : model.selected?.activeRun as Any? ?? NSNull(), "segment_ids": value.allMaterials ? [] : value.quotedIDs,
                    "draft_id": !value.allMaterials && model.readerShowsAI ? model.selectedAIDraftID as Any? ?? NSNull() : NSNull()]
                body = try JSONSerialization.data(withJSONObject: ["session_id": id, "message_id": UUID().uuidString, "instruction": instruction, "context": context])
                update(id) { $0.pendingInstruction = instruction; $0.pendingBody = body }
            }
            let result: AssistantAcknowledgment = try await client.send("/api/v1/agent/runs", method: "POST", body: body)
            update(id) { if $0.input == instruction { $0.input = "" }; $0.quotedIDs = []; $0.quoteScope = nil; $0.pendingBody = nil; $0.pendingInstruction = nil }
            // 先绑定运行，历史加载失败也不会丢失刚创建的运行。
            follow(result.id, session: id, model: model)
            try await refresh(id)
            let page: AssistantItems<AssistantSession> = try await client.send("/api/v1/sessions"); sessions = page.items
        } catch { update(id) { $0.error = error.localizedDescription } }
    }
    func follow(_ id: String, session: String, model: AppModel) {
        guard listeners[id] == nil else { return }; app = model
        let lifecycle = UUID(); lifecycles[id] = lifecycle
        update(session) { $0.activeRun = id; $0.progress = "正在读取资料…" }
        listeners[id] = Task { [weak self, weak model] in
            guard let self else { return }
            defer {
                if self.lifecycles[id] == lifecycle {
                    self.listeners[id] = nil; self.lifecycles[id] = nil
                    self.update(session) { if $0.activeRun == id { $0.activeRun = nil; $0.progress = "" } }
                }
            }
            var failures = 0
            while !Task.isCancelled {
                do {
                    guard let client = self.client else { return }
                    let cursor = self.conversations[session]?.outputs[id]?.lastEventID ?? 0
                    var terminal = false
                    for try await event in client.events(runID: id, after: cursor) {
                        try Task.checkCancellation(); failures = 0
                        self.consume(event, run: id, session: session)
                        if ["completed", "failed", "interrupted"].contains(event.kind) { terminal = true; break }
                    }
                    let run: AssistantRun = try await client.send("/api/v1/agent/runs/\(id)")
                    if terminal || !["queued", "running"].contains(run.state) {
                        try await self.refresh(session)
                        if !(run.result?.allChanges.isEmpty ?? true) { model?.reload() }
                        if let failure = run.result?.error { self.update(session) { $0.error = failure.message } }
                        if !self.isVisible || self.selectedSession != session { self.hasUnread = true }
                        return
                    }
                    failures += 1
                } catch is CancellationError { return }
                catch { failures += 1; if failures >= 3 { self.update(session) { $0.error = "连接中断，已保留输出。请重新连接以继续接收。" }; return } }
                self.update(session) { $0.progress = "正在重新连接，已生成内容会保留…" }
                try? await Task.sleep(for: .milliseconds(300 * min(failures, 3)))
            }
        }
    }
    func consume(_ event: BackendClient.Event, run: String, session: String) {
        guard event.id > (conversations[session]?.outputs[run]?.lastEventID ?? 0) else { return }
        update(session) { value in
            var output = value.outputs[run] ?? AssistantOutput(); output.apply(event); value.outputs[run] = output
            if event.kind == "answer_delta" { value.progress = "正在生成回答…" }
            else if event.kind == "coverage", let coverage = try? JSONDecoder().decode(AssistantCoverage.self, from: event.data) { value.progress = coverage.progressTitle }
            else if event.kind == "tool_start" { value.progress = "正在执行工具…" }
            else if event.kind == "tool_end" { value.progress = "正在整理工具结果…" }
            else if event.kind == "generation_mode", let payload = try? JSONSerialization.jsonObject(with: event.data) as? [String: String] { value.progress = payload["message"] ?? "正在生成…" }
        }
    }
    func cancel() async {
        guard let client, let run = activeRun, let session = selectedSession else { return }
        do { let _: AssistantRun = try await client.send("/api/v1/agent/runs/\(run)/cancel", method: "POST"); try await refresh(session) }
        catch { update(session) { $0.error = error.localizedDescription } }
    }
    func resume(_ id: String, model: AppModel) async {
        guard let client, let session = selectedSession else { return }
        do {
            update(session) { $0.error = nil }
            let _: AssistantAcknowledgment = try await client.send("/api/v1/agent/runs/\(id)/resume", method: "POST")
            follow(id, session: session, model: model)
        } catch { update(session) { $0.error = error.localizedDescription } }
    }
    func reconnect(model: AppModel) async {
        app = model
        do { try await loadHistory(); update(selectedSession) { $0.error = nil } }
        catch { update(selectedSession) { $0.error = error.localizedDescription } }
    }
    func revert(_ id: String, model: AppModel) async {
        guard let client else { return }; let session = selectedSession
        do {
            update(session) { $0.error = nil }
            let _: AssistantChange = try await client.send("/api/v1/changesets/\(id)/revert", method: "POST", body: JSONSerialization.data(withJSONObject: ["operation_id": UUID().uuidString]))
            model.reload(); if let session { try await refresh(session) }
        } catch { update(session) { $0.error = error.localizedDescription } }
    }
    func clearError() { update(selectedSession) { $0.error = nil } }
    func disconnected() {
        stop(); client = nil
        for id in Array(conversations.keys) {
            update(id) { value in
                value.activeRun = nil; value.sending = false; value.progress = ""
                value.error = "本地服务已失联，草稿与输出已保留。"
                value.runs = value.runs.map { run in var copy = run; if ["queued", "running"].contains(run.state) { copy.state = "interrupted" }; return copy }
            }
        }
    }
    func stop() { listeners.values.forEach { $0.cancel() }; listeners = [:]; lifecycles = [:]; app = nil }
}
