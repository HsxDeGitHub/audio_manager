import Foundation
import AudioCore

struct AssistantSession: Decodable, Identifiable { let id: String; let title: String }
struct AssistantMessageContext: Decodable { let runID: String?; let quotes: [SelectedQuote]?; private enum CodingKeys: String, CodingKey { case runID = "run_id", quotes } }
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
struct AssistantProposal: Decodable, Identifiable {
    let id: String; let title: String; let instruction: String; let sources: [AssistantReference]
}
struct AssistantResult: Decodable {
    struct Failure: Decodable { let code: String; let message: String }
    let answer: String?; let claims: [AssistantClaim]?; let coverage: AssistantCoverage?; let changeset: AssistantChange?; let error: Failure?
    let changesets: [AssistantChange]?
    let questions: [AssistantQuestion]?
    let partialResults: [AssistantPartialResult]?
    let proposals: [AssistantProposal]?
    private enum CodingKeys: String, CodingKey { case answer, claims, coverage, changeset, error, changesets, questions, proposals, partialResults = "partial_results" }
    var allChanges: [AssistantChange] { changesets ?? changeset.map { [$0] } ?? [] }
}
struct AssistantRunContext: Decodable {
    let historyOmitted: Bool?
    let scopeTitle: String?
    private enum CodingKeys: String, CodingKey { case historyOmitted = "history_omitted", scopeTitle = "scope_title" }
}
struct AssistantRun: Decodable, Identifiable {
    let id: String; var state: String; let result: AssistantResult?
    var messageID: String? = nil; var output: AssistantOutput? = nil
    var context: AssistantRunContext? = nil
    private enum CodingKeys: String, CodingKey { case id, state, result, output, context, messageID = "message_id" }
}
struct AssistantHistory: Decodable {
    let items: [AssistantMessage]; let runs: [AssistantRun]
    let hasMore: Bool?; let before: String?
    private enum CodingKeys: String, CodingKey { case items, runs, before, hasMore = "has_more" }
}
struct AssistantItems<T: Decodable>: Decodable { let items: [T] }
struct AssistantAcknowledgment: Decodable { let id: String; let state: String? }
struct AssistantSessionDeletion: Decodable { let id: String; let deleted: Bool }

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
        var input = ""; var allMaterials = false; var quotes: [SelectedQuote] = []
        var progress = ""; var error: String?; var activeRun: String?; var sending = false
        var outputs: [String: AssistantOutput] = [:]
        var savedChanges: [String: [AssistantChange]] = [:]
        var pendingInstruction: String?; var pendingBody: Data?
        var pendingContext: Data?
        var historyVersion = 0
        var proposalID: String?
        var hasMoreHistory = false; var historyCursor: String?; var loadingHistory = false
    }
    @Published var sessions: [AssistantSession] = []
    @Published private(set) var selectedSession: String?
    @Published private(set) var renamingSessionID: String?
    @Published private(set) var deletingSessionID: String?
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
    private var draftStore: AssistantDraftStore?
    private var draftTask: Task<Void, Never>?
    private var current: Conversation { conversations[selectedSession ?? ""] ?? Conversation() }
    var messages: [AssistantMessage] { current.messages }
    var runs: [AssistantRun] { get { current.runs } set { update(selectedSession) { $0.runs = newValue } } }
    var input: String { get { current.input } set { update(selectedSession) { $0.input = newValue; $0.proposalID = nil } } }
    var allMaterials: Bool { get { current.allMaterials } set { update(selectedSession) { $0.allMaterials = newValue } } }
    var quotes: [SelectedQuote] { current.quotes }
    var progress: String { current.progress }
    var error: String? { current.error }
    var activeRun: String? { current.activeRun }
    var sending: Bool { current.sending }
    var activeInstruction: String? {
        if sending { return current.pendingInstruction ?? (input.isEmpty ? nil : input) }
        guard let id = activeRun else { return nil }
        if let messageID = runs.first(where: { $0.id == id })?.messageID,
           let message = messages.first(where: { $0.id == messageID && $0.role == "user" }) { return message.content }
        return current.pendingInstruction ?? messages.last(where: { $0.role == "user" })?.content
    }
    var activeSavedChanges: [AssistantChange] {
        guard let id = activeRun else { return [] }
        return current.savedChanges[id] ?? runs.first(where: { $0.id == id })?.result?.allChanges ?? []
    }
    var unpairedRuns: [AssistantRun] {
        let messageIDs = Set(messages.filter { $0.role == "user" }.map(\.id))
        return runs.filter { $0.messageID.map { !messageIDs.contains($0) } ?? true }
    }
    var hasMoreHistory: Bool { current.hasMoreHistory }
    var loadingHistory: Bool { current.loadingHistory }
    var anyRunning: Bool { conversations.values.contains { $0.activeRun != nil || $0.sending } }
    var managingSession: Bool { renamingSessionID != nil || deletingSessionID != nil }
    var canDeleteSelectedSession: Bool { client != nil && selectedSession != nil && activeRun == nil && !sending && !managingSession }
    var canSend: Bool { client != nil && activeRun == nil && !sending && !managingSession && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && input.unicodeScalars.count <= 20000 }
    var changeToken: String { messages.map(\.id).joined() + runs.map { $0.id + $0.state }.joined() + current.outputs.keys.sorted().map { "\($0):\(current.outputs[$0]?.lastEventID ?? 0)" }.joined() }
    func output(_ id: String) -> String { current.outputs[id]?.text ?? "" }
    private func update(_ session: String?, _ body: (inout Conversation) -> Void) {
        let key = session ?? ""; var value = conversations[key] ?? Conversation()
        let before = AssistantDraft(input: value.input, allMaterials: value.allMaterials, quotes: value.quotes)
        body(&value); conversations[key] = value
        if before != AssistantDraft(input: value.input, allMaterials: value.allMaterials, quotes: value.quotes) { scheduleDraftSave() }
    }
    init(client: BackendClient? = nil) { self.client = client }
    func activate(_ id: String?) { selectedSession = id; focusRequest = UUID(); scheduleDraftSave() }
    func bind(_ model: AppModel) async {
        app = model
        if draftStore == nil { await restoreDrafts(from: model.dataDirectory.appendingPathComponent("assistant-drafts.json")) }
    }
    func restoreDrafts(from url: URL) async {
        let store = AssistantDraftStore(url: url); draftStore = store
        do {
            guard let snapshot = try await store.load() else { return }
            for (id, draft) in snapshot.items where conversations[id]?.input.isEmpty != false {
                conversations[id] = Conversation(input: draft.input, allMaterials: draft.allMaterials, quotes: draft.quotes)
            }
            if selectedSession == nil { selectedSession = snapshot.selectedSession }
        } catch { update(selectedSession) { $0.error = "本地草稿无法读取，已保留原文件。" } }
    }
    private func scheduleDraftSave() {
        guard draftStore != nil else { return }
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await self?.flushDrafts()
        }
    }
    func flushDrafts() async {
        guard let draftStore else { return }
        let values = conversations.filter { !$0.value.input.isEmpty || !$0.value.quotes.isEmpty || $0.value.allMaterials }
        let snapshot = AssistantDraftSnapshot(selectedSession: selectedSession, items: values.mapValues { AssistantDraft(input: $0.input, allMaterials: $0.allMaterials, quotes: $0.quotes) })
        do { try await draftStore.save(snapshot) }
        catch { update(selectedSession) { $0.error = "草稿暂未保存到磁盘，当前输入仍保留；请检查存储空间。" } }
    }
    func toggle() { isVisible.toggle(); if isVisible { focusRequest = UUID() } }
    func quote(model: AppModel) {
        let ids = model.bulkSelection.isEmpty ? Set(model.focusSegmentID.map { [$0] } ?? []) : model.bulkSelection
        let segments = model.segments.filter { ids.contains($0.id) }
        let joined = ReadingTranscript(segments: segments, punctuate: model.readingPunctuation, overrides: model.readingOverrides)
        quoteTranscript(text: joined.text, range: NSRange(location: 0, length: (joined.text as NSString).length), ranges: joined.ranges, segments: segments, model: model)
    }
    func quoteTranscript(text: String, range: NSRange, ranges: [String: NSRange], segments: [TranscriptSegment], model: AppModel) {
        guard let recording = model.selected, let run = recording.activeRun,
              let quote = SelectedQuote.transcript(text: text, range: range, ranges: ranges, segments: segments, title: recording.title, recordingID: recording.id, runID: run,
                                                  revision: { model.store?.contentRevision("segment", id: $0) ?? 1 }) else { return }
        addQuote(quote)
    }
    @discardableResult func addQuote(_ quote: SelectedQuote) -> Bool {
        isVisible = true; focusRequest = UUID()
        if let recording = quote.recordingID, quotes.contains(where: { $0.recordingID != nil && ($0.recordingID != recording || $0.runID != quote.runID) }) {
            update(selectedSession) { $0.error = "当前引用来自另一份录音或版本，请先清空对应引用，再添加新选区。" }; return false
        }
        if quotes.contains(where: { $0.text == quote.text && $0.sources == quote.sources }) { return true }
        guard !quote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard quotes.count < 20, quote.text.unicodeScalars.count <= 12000,
              quotes.reduce(quote.text.unicodeScalars.count, { $0 + $1.text.unicodeScalars.count }) <= 20000 else {
            update(selectedSession) { $0.error = "最多附加 20 条引用，总计 20000 字；请缩小选区后重试。" }; return false
        }
        update(selectedSession) { $0.quotes.append(quote); $0.allMaterials = false; $0.error = nil }
        return true
    }
    func removeQuote(_ id: String) { update(selectedSession) { $0.quotes.removeAll { $0.id == id } } }
    func clearQuotes() { update(selectedSession) { $0.quotes = [] } }
    func chooseProposal(_ proposal: AssistantProposal) {
        update(selectedSession) { $0.input = "执行方案：\(proposal.title)\n\(proposal.instruction)"; $0.proposalID = proposal.id }
        focusRequest = UUID()
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
        if selectedSession == nil || !sessions.contains(where: { $0.id == selectedSession }) { activate(sessions.first?.id) }
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
    func renameSession(_ id: String, title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= 120 else { throw BackendClientError.invalidRequest }
        guard let client else { throw BackendClientError.unavailable }
        guard sessions.contains(where: { $0.id == id }) else { throw BackendClientError.notFound }
        guard !managingSession else { throw BackendClientError.conflict }
        renamingSessionID = id
        defer { renamingSessionID = nil }
        let session: AssistantSession = try await client.send("/api/v1/sessions/\(id)", method: "PATCH",
            body: JSONSerialization.data(withJSONObject: ["title": title]))
        guard session.id == id else { throw BackendClientError.invalidResponse }
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index] = session }
    }
    func deleteSession(_ id: String) async throws {
        guard let client else { throw BackendClientError.unavailable }
        guard sessions.contains(where: { $0.id == id }) else { throw BackendClientError.notFound }
        guard !managingSession, conversations[id]?.activeRun == nil, conversations[id]?.sending != true else { throw BackendClientError.conflict }
        deletingSessionID = id
        defer { deletingSessionID = nil }
        let response: AssistantSessionDeletion = try await client.send("/api/v1/sessions/\(id)", method: "DELETE")
        guard response.id == id, response.deleted else { throw BackendClientError.invalidResponse }
        for run in conversations[id]?.runs ?? [] {
            lifecycles[run.id] = nil; listeners.removeValue(forKey: run.id)?.cancel()
        }
        sessions.removeAll { $0.id == id }; conversations[id] = nil
        scheduleDraftSave()
        if selectedSession == id {
            if sessions.isEmpty { conversations[""] = nil }
            activate(sessions.first?.id)
            do { try await loadHistory() }
            catch { update(selectedSession) { $0.error = error.localizedDescription } }
        }
    }
    func loadHistory() async throws { if let selectedSession { try await refresh(selectedSession) } }
    private func refresh(_ id: String) async throws {
        guard let client else { return }
        update(id) { $0.historyVersion += 1 }; let version = conversations[id]?.historyVersion
        let history: AssistantHistory = try await client.send("/api/v1/sessions/\(id)")
        guard conversations[id]?.historyVersion == version else { return }
        update(id) { value in
            let messageIDs = Set(history.items.map(\.id)), runIDs = Set(history.runs.map(\.id))
            value.messages = value.messages.filter { !messageIDs.contains($0.id) } + history.items
            value.runs = value.runs.filter { !runIDs.contains($0.id) } + history.runs
            if value.historyCursor == nil { value.hasMoreHistory = history.hasMore ?? false; value.historyCursor = history.before }
            for run in history.runs {
                if let snapshot = run.output, snapshot.lastEventID >= (value.outputs[run.id]?.lastEventID ?? 0) { value.outputs[run.id] = snapshot }
            }
        }
        if let run = history.runs.first(where: { ["queued", "running"].contains($0.state) }), let app, listeners[run.id] == nil { follow(run.id, session: id, model: app) }
    }
    func loadOlderHistory() async {
        guard let client, let id = selectedSession, hasMoreHistory, !loadingHistory, let cursor = current.historyCursor else { return }
        update(id) { $0.loadingHistory = true }
        defer { update(id) { $0.loadingHistory = false } }
        do {
            let history: AssistantHistory = try await client.send("/api/v1/sessions/\(id)?before=\(cursor)&limit=50")
            update(id) { value in
                let messageIDs = Set(value.messages.map(\.id)), runIDs = Set(value.runs.map(\.id))
                value.messages = history.items.filter { !messageIDs.contains($0.id) } + value.messages
                value.runs = history.runs.filter { !runIDs.contains($0.id) } + value.runs
                value.historyCursor = history.before; value.hasMoreHistory = history.hasMore ?? false
            }
        } catch { update(id) { $0.error = error.localizedDescription } }
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
        let instruction = conversations[id]?.input ?? ""
        let value = conversations[id] ?? Conversation()
        do {
            let quoteObjects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value.quotes))
            let segments = Array(Set(value.quotes.flatMap(\.sources).filter { $0.resourceType == "segment" }.map(\.resourceID))).sorted()
            let documents = Array(Set(value.quotes.flatMap(\.sources).filter { $0.resourceType == "document" }.map(\.resourceID))).sorted()
            let documentOnly = !documents.isEmpty && segments.isEmpty
            let pinned = value.quotes.first { $0.recordingID != nil }
            let context: [String: Any] = ["scope": value.allMaterials ? "all" : "current", "recording_id": value.allMaterials || documentOnly ? NSNull() : (pinned?.recordingID ?? model.selectedID) as Any? ?? NSNull(),
                "run_id": value.allMaterials || documentOnly ? NSNull() : (pinned?.runID ?? model.selected?.activeRun) as Any? ?? NSNull(), "segment_ids": value.allMaterials ? [] : segments,
                "document_ids": documents, "quotes": quoteObjects, "proposal_id": value.proposalID as Any? ?? NSNull()]
            let contextData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
            let body: Data
            if value.pendingInstruction == instruction, value.pendingContext == contextData, let saved = value.pendingBody { body = saved }
            else {
                body = try JSONSerialization.data(withJSONObject: ["session_id": id, "message_id": UUID().uuidString, "instruction": instruction, "context": context])
                update(id) { $0.pendingInstruction = instruction; $0.pendingBody = body; $0.pendingContext = contextData }
            }
            let identity = try JSONDecoder().decode(MessageIdentity.self, from: body)
            let result: AssistantAcknowledgment = try await client.send("/api/v1/agent/runs", method: "POST", body: body)
            update(id) {
                // 后端已接收后立即保留问题；历史刷新失败时仍能看见本轮任务。
                if !$0.messages.contains(where: { $0.id == identity.messageID }) {
                    $0.messages.append(AssistantMessage(id: identity.messageID, role: "user", content: instruction,
                        context: AssistantMessageContext(runID: pinned?.runID ?? model.selected?.activeRun, quotes: value.quotes)))
                }
                if $0.input == instruction { $0.input = ""; $0.proposalID = nil }
                $0.quotes.removeAll { quote in value.quotes.contains { $0.id == quote.id } }
                $0.pendingBody = nil; $0.pendingInstruction = nil; $0.pendingContext = nil
            }
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
                        if !(run.result?.allChanges.isEmpty ?? true) { await model?.reload() }
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
            else if event.kind == "task_stage", let payload = try? JSONSerialization.jsonObject(with: event.data) as? [String: String] { value.progress = payload["message"] ?? "正在处理任务…" }
            else if event.kind == "generation_mode", let payload = try? JSONSerialization.jsonObject(with: event.data) as? [String: String] { value.progress = payload["message"] ?? "正在生成…" }
            else if event.kind == "changeset", let change = try? JSONDecoder().decode(AssistantChange.self, from: event.data) {
                var changes = value.savedChanges[run] ?? []
                changes.removeAll { $0.id == change.id }; changes.append(change)
                value.savedChanges[run] = changes
            }
        }
    }
    private struct MessageIdentity: Decodable {
        let messageID: String
        private enum CodingKeys: String, CodingKey { case messageID = "message_id" }
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
            try await refresh(session)
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
            await model.reload(); if let session { try await refresh(session) }
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
