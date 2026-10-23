import SwiftUI

@MainActor
final class ChangeHistoryModel: ObservableObject {
    @Published var items: [AssistantChange] = []
    @Published var error: String?
    @Published var busy = false
    @Published var total = 0
    var client: BackendClient?
    func record(_ receipt: AssistantChange) {
        items.removeAll { $0.id == receipt.id }; items.insert(receipt, at: 0)
    }
    func load(more: Bool = false) async {
        guard let client else { return }
        busy = true; defer { busy = false }
        do {
            struct Page: Decodable { let items: [AssistantChange]; let total: Int }
            let page: Page = try await client.send("/api/v1/changesets?offset=\(more ? items.count : 0)&limit=50")
            items = more ? items + page.items : page.items; total = page.total; error = nil
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func revert(_ id: String) async -> Bool {
        guard let client else { return false }
        busy = true; defer { busy = false }
        do {
            let _: AssistantChange = try await client.send("/api/v1/changesets/\(id)/revert", method: "POST",
                body: JSONSerialization.data(withJSONObject: ["operation_id": UUID().uuidString]))
            await load(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct ChangeHistoryView: View {
    @ObservedObject var model: ChangeHistoryModel
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("修改记录").font(.title2); Spacer(); Button("刷新") { Task { await model.load() } }; Button("关闭") { dismiss() } }
            Text("界面和助手的内容修改保留在本机；撤销时会检查后续编辑冲突。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.items, id: \.id) { change in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(change.count) 个对象 · \(change.state == "committed" ? "已提交" : "已撤销")")
                                Spacer()
                                Button("整次撤销") { Task { if await model.revert(change.id) { onChange() } } }
                                    .disabled(model.busy || change.state != "committed")
                            }
                            ForEach(Array((change.items ?? []).enumerated()), id: \.offset) { _, item in
                                Text(ChangeDifference.describe(item)).font(.caption).textSelection(.enabled)
                            }
                        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if model.items.count < model.total { Button("更早的修改") { Task { await model.load(more: true) } } }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(22).frame(minWidth: 620, minHeight: 440).task { await model.load() }
    }
}

enum ChangeDifference {
    static func describe(_ item: BackendJSONValue) -> String {
        guard case .object(let row) = item, case .object(let before) = row["before"], case .object(let after) = row["after"] else { return "修改详情不可用" }
        let labels = ["edited":"正文", "title":"名称", "payload":"整理稿", "content":"内容", "state":"状态", "removed":"移除", "kind":"类型", "company":"公司", "role":"岗位", "interview_date":"实际面试日期"]
        return after.keys.sorted().filter { before[$0] != after[$0] && $0 != "revision" }.map { key in
            "\(labels[key] ?? key)\n修改前：\(display(visibleValue(key, in: before)))\n修改后：\(display(visibleValue(key, in: after)))"
        }.joined(separator: "\n\n")
    }
    private static func visibleValue(_ key: String, in row: [String: BackendJSONValue]) -> BackendJSONValue? {
        if key == "edited", row[key] == nil || row[key] == .null { return row["original"] }
        return row[key]
    }
    private static func display(_ value: BackendJSONValue?) -> String {
        guard let value else { return "无" }
        if case .string(let text) = value { return text.isEmpty ? "（空）" : text }
        if case .null = value { return "无" }
        return String(describing: value.anyValue)
    }
}
