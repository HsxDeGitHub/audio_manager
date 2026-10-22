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
}

struct DocumentsView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: DocumentsModel
    @UIState private var selectedID: String?
    @UIState private var editing: BackendDocument?
    @UIState private var removing: BackendDocument?
    @UIState private var showHistory = false
    @Environment(\.dismiss) private var dismiss
    init(app: AppModel, client: BackendClient) {
        self.app = app
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
                            Button("编辑") { editing = item }.disabled(model.busy)
                            Button("移除…", role: .destructive) { removing = item }.disabled(model.busy)
                        }
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 5) {
                                    ForEach(Array(item.content.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                                        HStack(alignment: .top) {
                                            Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 35, alignment: .trailing)
                                            Text(line.isEmpty ? " " : line).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }.padding(4).background(app.documentSourceID == item.id && app.documentSourceLine == index + 1 ? Color.accentColor.opacity(0.14) : Color.clear).id(index + 1)
                                    }
                                }
                            }
                            .task(id: item.id) { proxy.scrollTo(app.documentSourceID == item.id ? app.documentSourceLine : 1, anchor: .center) }
                            .onChange(of: app.documentSourceLine) { _, line in proxy.scrollTo(line, anchor: .center) }
                        }
                    } else { Text("导入或选择一份个人材料。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.padding(12).frame(minWidth: 420)
            }
            if model.busy { ProgressView().controlSize(.small) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(minWidth: 740, minHeight: 500)
        .task { await model.load(); selectedID = app.documentSourceID ?? model.items.first?.id }
        .onChange(of: app.documentSourceID) { _, id in selectedID = id }
        .sheet(isPresented: $showHistory) { ChangeHistoryView(model: app.changeHistory, onChange: { Task { await model.load() }; app.reload() }) }
        .sheet(item: $editing) { item in
            DocumentEditor(item: item) { title, content in Task { await model.update(item, fields: ["title": title, "content": content]) } }
        }
        .confirmationDialog("移除这份材料？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                if let item = removing { Task { await model.update(item, fields: ["removed": true]) } }
                removing = nil
            }
        } message: { Text("材料将退出当前检索，已有旧引用失效。") }
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
    let item: BackendDocument
    let save: (String, String) -> Void
    @UIState private var title: String
    @UIState private var content: String
    @Environment(\.dismiss) private var dismiss
    init(item: BackendDocument, save: @escaping (String, String) -> Void) {
        self.item = item; self.save = save
        _title = UIState(initialValue: item.title); _content = UIState(initialValue: item.content)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑材料").font(.headline)
            TextField("名称", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $content).frame(minHeight: 260).border(Color.secondary.opacity(0.25))
            HStack {
                Spacer(); Button("取消") { dismiss() }
                Button("保存") { save(title, content); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 600)
    }
}
