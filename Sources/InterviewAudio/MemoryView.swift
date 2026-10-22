import SwiftUI
import Foundation

// 长期记忆与助手共用同一后端记录；界面不推断说话人身份，也不从删除项重建。
struct MemoryItem: Decodable, Identifiable {
    let id: String
    let category: String
    let content: String
    let scope: String
    let sources: [AssistantReference]
    let topic: String
    let state: String
    let supersedes: String?
    let revision: Int

    var categoryTitle: String {
        ["user_statement": "用户陈述", "preference": "偏好", "analysis": "分析"][category] ?? "待核对"
    }
    var stateTitle: String {
        ["active": "生效", "disabled": "已停用", "deleted": "已删除",
         "needs_review": "待核对", "superseded": "已被纠正"][state] ?? state
    }
}

private struct MemoryPage: Decodable { let items: [MemoryItem] }

@MainActor
final class MemoryModel: ObservableObject {
    @Published var items: [MemoryItem] = []
    @Published var loading = false
    @Published var busy = false
    @Published var error: String?
    private let client: BackendClient
    private let history: ChangeHistoryModel?

    init(client: BackendClient, history: ChangeHistoryModel? = nil) { self.client = client; self.history = history }

    func load() async {
        loading = true; defer { loading = false }
        do {
            let page: MemoryPage = try await client.send("/api/v1/memories")
            items = page.items
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func update(_ item: MemoryItem, fields: [String: Any]) async {
        busy = true; defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["operation_id": UUID().uuidString,
                                                                   "expected_revision": item.revision, "fields": fields])
            let receipt: AssistantChange = try await client.send("/api/v1/memories/\(item.id)", method: "PATCH", body: body)
            history?.record(receipt)
            await load()
        } catch { let message = error.localizedDescription; await load(); self.error = message }
    }
}

struct MemoryView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: MemoryModel
    @UIState private var editing: MemoryItem?
    @UIState private var deleting: MemoryItem?
    @UIState private var showHistory = false
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, client: BackendClient) {
        self.app = app
        _model = StateObject(wrappedValue: MemoryModel(client: client, history: app.changeHistory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "brain").font(.title).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("长期记忆").font(.title2.weight(.semibold))
                    Text("只保存有来源的用户陈述、偏好和分析；删除后不会从同一来源自动重建。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("修改记录与撤销") { showHistory = true }
                Button("刷新") { Task { await model.load() } }.disabled(model.busy)
            }
            Divider()
            if model.loading && model.items.isEmpty { ProgressView().controlSize(.small) }
            if model.items.isEmpty && !model.loading {
                Text("还没有长期记忆。个人陈述来自用户消息，分析记忆来自有来源的分析结论。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.items) { item in
                            row(item)
                        }
                    }
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("记忆来源可逐项查看；分析不会被当作本人亲历。").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(minWidth: 640, minHeight: 480)
        .task { await model.load() }
        .sheet(isPresented: $showHistory) { ChangeHistoryView(model: app.changeHistory, onChange: { Task { await model.load() }; app.reload() }) }
        .sheet(item: $editing) { item in
            MemoryEditor(item: item) { text in
                Task { await model.update(item, fields: ["content": text]) }
            }
        }
        .confirmationDialog("删除这条记忆？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除并阻止同源重建", role: .destructive) {
                if let item = deleting { Task { await model.update(item, fields: ["state": "deleted"]) } }
                deleting = nil
            }
        } message: { Text("不会删除原始录音、聊天或资料；仅停止把该记忆注入后续回答。") }
    }

    private func row(_ item: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(item.categoryTitle).font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(accent.opacity(0.12), in: Capsule())
                Text(item.topic).font(.caption).foregroundStyle(.secondary)
                Text(item.stateTitle).font(.caption)
                    .foregroundStyle(item.state == "active" ? Color.secondary : Color.orange)
                Spacer()
                Text("\(item.sources.count) 个来源 · v\(item.revision)").font(.caption2).foregroundStyle(.tertiary)
            }
            Text(item.content).textSelection(.enabled)
            if item.category == "analysis" { Text("分析判断 · 不代表本人确认或亲历").font(.caption).foregroundStyle(.orange) }
            Text("适用范围：\(scopeTitle(item.scope))").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("编辑") { editing = item }
                if item.state == "active" { Button("停用") { Task { await model.update(item, fields: ["state": "disabled"]) } } }
                if item.state == "disabled" { Button("启用") { Task { await model.update(item, fields: ["state": "active"]) } } }
                if item.state != "deleted" { Button("删除…", role: .destructive) { deleting = item } }
                if !item.sources.isEmpty {
                    DisclosureGroup("来源") {
                        ForEach(item.sources, id: \.self) { source in
                            Text("\(source.resourceType) · \(source.resourceID) · v\(source.revision)")
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.font(.caption)
                }
                Spacer()
            }.buttonStyle(.link).disabled(model.busy)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .opacity(item.state == "deleted" ? 0.55 : 1)
    }

    private func scopeTitle(_ scope: String) -> String {
        if scope == "global" { return "全部会话" }
        if scope.hasPrefix("recording:") { return "指定录音资料" }
        if scope.hasPrefix("document:") { return "指定个人材料" }
        if scope.hasPrefix("session:") { return "当前会话" }
        return scope
    }
}

private struct MemoryEditor: View {
    let item: MemoryItem
    let save: (String) -> Void
    @UIState private var text: String
    @Environment(\.dismiss) private var dismiss
    init(item: MemoryItem, save: @escaping (String) -> Void) {
        self.item = item; self.save = save
        _text = UIState(initialValue: item.content)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑记忆").font(.headline)
            Text("修改内容不会改变记忆类型和来源；明确纠正请由助手生成新的记忆。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).frame(minHeight: 120).border(Color.secondary.opacity(0.25))
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(text.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 520)
    }
}
