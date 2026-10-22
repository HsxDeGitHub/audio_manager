import Foundation

/// 设备副作用开始前落盘身份，完成后先保存实际结果，再向业务服务确认。
@MainActor final class DeviceReceiptJournal {
    private struct State: Codable {
        var owner: String
        var inFlight: Set<String> = []
        var receipts: [String: Data] = [:]
    }
    private var state: State
    private let url: URL
    private var active: Set<String> = []
    var owner: String { state.owner }
    var pendingCount: Int { state.receipts.count }
    private(set) var lastError: String?
    init(url: URL) throws {
        self.url = url
        state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State(owner: UUID().uuidString)
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func begin(_ id: String) throws {
        state.inFlight.insert(id); try save(); active.insert(id)
    }
    func finish(_ id: String, status: String, result: [String: Any]?) throws {
        var body: [String: Any] = ["owner": owner, "state": status]
        if let result { body["result"] = result }
        state.receipts[id] = try JSONSerialization.data(withJSONObject: body)
        state.inFlight.remove(id); active.remove(id); try save()
    }
    @discardableResult func flush(_ client: BackendClient) async -> Bool {
        do {
            for id in state.inFlight where !active.contains(id) {
                try finish(id, status: "unknown", result: ["message": "设备在结果保存前中断，不能重复执行。"])
            }
            for (id, body) in state.receipts {
                let _: DeviceAcknowledgment = try await client.send("/api/v1/device/commands/\(id)/reconcile", method: "POST", body: body)
                state.receipts.removeValue(forKey: id); try save()
            }
            lastError = nil; return true
        } catch { lastError = error.localizedDescription; return false }
    }
}
