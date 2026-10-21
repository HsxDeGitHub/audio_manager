import Foundation
import AudioCore

struct AssistantSession: Decodable, Identifiable { let id: String; let title: String }
struct AssistantMessage: Decodable, Identifiable { let id: String; let role: String; let content: String }
struct AssistantReference: Decodable, Hashable {
    let resourceType: String; let resourceID: String; let revision: Int
    let line: Int?; let historical: Bool?
    private enum CodingKeys: String, CodingKey { case resourceType = "resource_type", resourceID = "resource_id", revision, line, historical }
}
struct AssistantClaim: Decodable { let text: String; let kind: String; let sources: [AssistantReference] }
struct AssistantCoverage: Decodable { let total: Int; let covered: Int; let excluded: [BackendJSONValue]? }
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
    var allChanges: [AssistantChange] { changesets ?? changeset.map { [$0] } ?? [] }
}
struct AssistantRun: Decodable, Identifiable { let id: String; let state: String; let result: AssistantResult? }
struct AssistantHistory: Decodable { let items: [AssistantMessage]; let runs: [AssistantRun] }
struct AssistantItems<T: Decodable>: Decodable { let items: [T] }
struct AssistantAcknowledgment: Decodable { let id: String; let state: String? }

@MainActor
final class AssistantModel: ObservableObject {
    @Published var sessions: [AssistantSession] = []
    @Published var selectedSession: String?
    @Published var messages: [AssistantMessage] = []
    @Published var runs: [AssistantRun] = []
    @Published var input = ""
    @Published var allMaterials = false
    @Published var quotedIDs: [String] = []
    @Published var progress = ""
    @Published var error: String?
    @Published var activeRun: String?
    private(set) var client: BackendClient?
    private var listener: Task<Void, Never>?
    private var cursors: [String: Int] = [:]

    func attach(_ connection: BackendConnection) async {
        do { client = try BackendClient(baseURL: connection.baseURL, token: connection.token, timeout: 120); try await reloadSessions() }
        catch { self.error = error.localizedDescription }
    }
    func reloadSessions() async throws {
        guard let client else { return }
        let page: AssistantItems<AssistantSession> = try await client.send("/api/v1/sessions")
        sessions = page.items
        if selectedSession == nil { selectedSession = sessions.first?.id }
        if selectedSession != nil { try await loadHistory() }
    }
    func createSession() async {
        do {
            guard let client else { return }
            let response: AssistantAcknowledgment = try await client.send("/api/v1/sessions", method: "POST", body: JSONSerialization.data(withJSONObject: ["title": "新对话", "scope": [:]]))
            selectedSession = response.id; try await reloadSessions()
        } catch { self.error = error.localizedDescription }
    }
    func loadHistory() async throws {
        guard let client, let selectedSession else { messages = []; runs = []; return }
        let history: AssistantHistory = try await client.send("/api/v1/sessions/\(selectedSession)")
        messages = history.items; runs = history.runs
    }
    func select(_ id: String?) async { selectedSession = id; do { try await loadHistory() } catch { self.error = error.localizedDescription } }
    func send(model: AppModel) async {
        guard activeRun == nil, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let client else { return }
        if selectedSession == nil { await createSession() }
        guard let selectedSession else { return }
        let instruction = input
        let context: [String: Any] = ["scope": allMaterials ? "all" : "current", "recording_id": allMaterials ? NSNull() : model.selectedID as Any? ?? NSNull(),
            "run_id": allMaterials ? NSNull() : model.selected?.activeRun as Any? ?? NSNull(), "segment_ids": allMaterials ? [] : quotedIDs,
            "draft_id": !allMaterials && model.readerShowsAI ? model.selectedAIDraftID as Any? ?? NSNull() : NSNull()]
        do {
            error = nil
            let result: AssistantAcknowledgment = try await client.send("/api/v1/agent/runs", method: "POST", body: JSONSerialization.data(withJSONObject: ["session_id": selectedSession, "message_id": UUID().uuidString, "instruction": instruction, "context": context]))
            input = ""; quotedIDs = []; try await loadHistory(); follow(result.id, model: model)
        } catch { self.error = error.localizedDescription }
    }
    func follow(_ id: String, model: AppModel) {
        listener?.cancel(); activeRun = id; progress = "正在运行…"
        listener = Task {
            defer { activeRun = nil; progress = "" }
            do {
                guard let client else { return }
                for try await event in client.events(runID: id, after: cursors[id] ?? 0) {
                    cursors[id] = event.id
                    if event.kind == "coverage", let coverage = try? JSONDecoder().decode(AssistantCoverage.self, from: event.data) { progress = "已覆盖 \(coverage.covered)/\(coverage.total) 个来源" }
                    else if event.kind == "tool_start" { progress = "正在执行工具…" }
                }
                try await loadHistory(); model.reload()
                if let failure = runs.first(where: { $0.id == id })?.result?.error { self.error = failure.message }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func cancel() async {
        guard let client, let activeRun else { return }
        do { let _: AssistantRun = try await client.send("/api/v1/agent/runs/\(activeRun)/cancel", method: "POST"); try await loadHistory() }
        catch { self.error = error.localizedDescription }
    }
    func resume(_ id: String, model: AppModel) async {
        guard let client else { return }
        do { error = nil; let _: AssistantAcknowledgment = try await client.send("/api/v1/agent/runs/\(id)/resume", method: "POST"); follow(id, model: model) }
        catch { self.error = error.localizedDescription }
    }
    func revert(_ id: String, model: AppModel) async {
        guard let client else { return }
        do { error = nil; let _: AssistantChange = try await client.send("/api/v1/changesets/\(id)/revert", method: "POST", body: JSONSerialization.data(withJSONObject: ["operation_id": UUID().uuidString])); model.reload(); try await loadHistory() }
        catch { self.error = error.localizedDescription }
    }
    func stop() { listener?.cancel() }
}
