import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class DocumentsModel: ObservableObject {
    @Published var items: [BackendDocument] = []
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    private let client: BackendClient
    private let history: ChangeHistoryModel?
    init(client: BackendClient, history: ChangeHistoryModel? = nil) { self.client = client; self.history = history }
    func load() async {
        do { items = try await client.documents() }
        catch { self.error = error.localizedDescription }
    }
    func importFile(_ url: URL) async -> String? {
        busy = true; error = nil; defer { busy = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let format = url.pathExtension.lowercased()
            let content = try String(contentsOf: url, encoding: .utf8)
            let doc = try await client.importDocument(title: url.deletingPathExtension().lastPathComponent,
                format: format, content: content, operationID: UUID().uuidString)
            notice = doc.duplicate == true ? "内容已存在，已定位到原材料。" : "材料已导入。"
            await load(); return doc.id
        } catch { self.error = "导入失败：\(error.localizedDescription)"; return nil }
    }
    func update(_ item: BackendDocument, fields: [String: Any]) async {
        busy = true; error = nil; defer { busy = false }
        do {
            let receipt = try await client.updateDocument(id: item.id, revision: item.revision, fields: fields, operationID: UUID().uuidString)
            history?.record(receipt)
            notice = fields["removed"] as? Bool == true ? "已移除材料，旧引用不再作为当前证据。" : "材料已保存，旧引用已失效。"
            await load()
        } catch { self.error = error.localizedDescription; await load() }
    }
    func save(_ item: BackendDocument, title: String, content: String) async throws {
        let receipt = try await client.updateDocument(id: item.id, revision: item.revision,
            fields: ["title": title, "content": content], operationID: UUID().uuidString)
        history?.record(receipt); await load()
    }
    func latest(_ id: String) async throws -> BackendDocument {
        let values = try await client.documents()
        guard let item = values.first(where: { $0.id == id }) else { throw BackendClientError.notFound }
        return item
    }
}

struct DocumentsView: View {
    @ObservedObject var app: AppModel
    let embedded: Bool
    @StateObject private var model: DocumentsModel
    @UIState private var selectedID: String?
    @UIState private var editing: BackendDocument?
    @UIState private var removing: BackendDocument?
    @UIState private var showHistory = false
    @Environment(\.dismiss) private var dismiss
    init(app: AppModel, client: BackendClient, embedded: Bool = false) {
        self.app = app; self.embedded = embedded
        _model = StateObject(wrappedValue: DocumentsModel(client: client, history: app.changeHistory))
    }
    private var selected: BackendDocument? { model.items.first { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("个人材料").font(.title2.weight(.semibold))
                Spacer()
                Button("导入 TXT / Markdown…") { importFile() }.disabled(model.busy)
                Button("修改记录与撤销") { showHistory = true }
                Button("刷新") { Task { await model.load() } }.disabled(model.busy)
            }
            Text("材料保存在本机，与助手共用版本校验和内容去重；引用可定位到具体行。")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(model.items, selection: $selectedID) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                        Text("\(item.format.uppercased()) · v\(item.revision)").font(.caption).foregroundStyle(.secondary)
                    }.tag(item.id)
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                VStack(alignment: .leading, spacing: 8) {
                    if let item = selected {
                        HStack {
                            Text(item.title).font(.headline)
                            Spacer()
                            Button("引用全文") { attach(item, range: NSRange(location: 0, length: (item.content as NSString).length)) }
                            Button("编辑") { editing = item }.disabled(model.busy)
                            Button("移除…", role: .destructive) { removing = item }.disabled(model.busy)
                        }
                        Text("选中文字，点击“添加到对话”，可跨行引用。").font(.caption).foregroundStyle(.secondary)
                        DocumentSelectionText(text: item.content, line: app.documentSourceID == item.id ? app.documentSourceLine : 1) { range in attach(item, range: range) }
                            .id(item.id)
                    } else { Text("导入或选择一份个人材料。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.padding(12).frame(minWidth: embedded ? 280 : 420)
            }
            if model.busy { ProgressView().controlSize(.small) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); if !embedded { Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }.padding(20).frame(minWidth: embedded ? 520 : 740, minHeight: 500)
        .task { await model.load(); selectedID = app.documentSourceID ?? model.items.first?.id }
        .onChange(of: app.documentSourceID) { _, id in selectedID = id }
        .sheet(isPresented: $showHistory) { ChangeHistoryView(model: app.changeHistory, onChange: { Task { await model.load(); await app.reload() } }) }
        .sheet(item: $editing) { item in
            DocumentEditor(item: item, latest: { try await model.latest(item.id) }) { base, title, content in
                try await model.save(base, title: title, content: content)
            }
        }
        .confirmationDialog("移除这份材料？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                if let item = removing { Task { await model.update(item, fields: ["removed": true]) } }
                removing = nil
            }
        } message: { Text("材料将退出当前检索，已有旧引用失效。") }
    }
    private func attach(_ item: BackendDocument, range: NSRange) {
        guard let quote = SelectedQuote.document(item, range: range) else { return }
        if app.assistant.addQuote(quote) { if !embedded { dismiss() } }
        else { model.error = app.assistant.error }
    }
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "选择 UTF-8 编码的 TXT 或 Markdown 材料。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { if let id = await model.importFile(url) { selectedID = id } }
    }
}

private struct DocumentEditor: View {
    let latest: () async throws -> BackendDocument
    let save: (BackendDocument, String, String) async throws -> Void
    @UIState private var base: BackendDocument
    @UIState private var current: BackendDocument?
    @StateObject private var state = EditorSaveState()
    @UIState private var title: String
    @UIState private var content: String
    @Environment(\.dismiss) private var dismiss
    init(item: BackendDocument, latest: @escaping () async throws -> BackendDocument, save: @escaping (BackendDocument, String, String) async throws -> Void) {
        self.latest = latest; self.save = save
        _base = UIState(initialValue: item)
        _title = UIState(initialValue: item.title); _content = UIState(initialValue: item.content)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑材料").font(.headline)
            TextField("名称", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $content).frame(minHeight: 260).border(Color.secondary.opacity(0.25))
                .disabled(state.saving)
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let current {
                DisclosureGroup("当前已保存的版本 v\(current.revision)（你的输入已保留）") {
                    ScrollView { Text(current.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                }.font(.caption)
                Button("使用当前版本作为基准，保留输入继续编辑") { base = current; self.current = nil }.disabled(state.saving)
            }
            HStack {
                if state.saving { ProgressView().controlSize(.small) }
                Spacer(); Button("取消") { dismiss() }.disabled(state.saving)
                Button("保存") {
                    Task {
                        if await state.commit({ try await save(base, title, content) }) { dismiss() }
                        else { current = try? await latest() }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(state.saving || current != nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 600)
            .interactiveDismissDisabled(state.saving)
    }
}
