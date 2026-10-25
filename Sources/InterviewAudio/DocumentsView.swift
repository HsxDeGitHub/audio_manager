import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class DocumentsModel: ObservableObject {
    @Published var items: [BackendDocument] = []
    @Published var busy = false
    @Published var loading = false
    @Published var selectedID: String?
    @Published var filterText = ""
    @Published var error: String?
    @Published var notice: String?
    private var client: BackendClient?
    private var connectionVersion = UUID()
    private var loadVersion = UUID()
    private let history: ChangeHistoryModel?
    init(client: BackendClient? = nil, history: ChangeHistoryModel? = nil) { self.client = client; self.history = history }
    var selected: BackendDocument? { items.first { $0.id == selectedID } }
    var visibleItems: [BackendDocument] {
        let term = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? items : items.filter { $0.title.localizedStandardContains(term) }
    }
    func connect(_ client: BackendClient?) async {
        self.client = client; connectionVersion = UUID(); loading = false
        if client != nil { await load() }
    }
    func load() async {
        guard let client else { return }
        let version = connectionVersion
        let request = UUID(); loadVersion = request
        loading = true
        defer { if connectionVersion == version, loadVersion == request { loading = false } }
        do {
            let values = try await client.documents()
            guard connectionVersion == version, loadVersion == request, !Task.isCancelled else { return }
            items = values; error = nil
            if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
        } catch { if connectionVersion == version, loadVersion == request, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func importFile(_ url: URL) async -> String? {
        guard let client else { error = "本地服务尚未连接，请重试连接。"; return nil }
        busy = true; error = nil; defer { busy = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let format = url.pathExtension.lowercased()
            let content = try String(contentsOf: url, encoding: .utf8)
            let doc = try await client.importDocument(title: url.deletingPathExtension().lastPathComponent,
                format: format, content: content, operationID: UUID().uuidString)
            notice = doc.duplicate == true ? "内容已存在，已定位到原材料。" : "材料已导入。"
            await load(); filterText = ""; selectedID = doc.id; return doc.id
        } catch { self.error = "导入失败：\(error.localizedDescription)"; return nil }
    }
    func update(_ item: BackendDocument, fields: [String: Any]) async {
        guard let client else { error = "本地服务尚未连接，请重试连接。"; return }
        busy = true; error = nil; defer { busy = false }
        do {
            let receipt = try await client.updateDocument(id: item.id, revision: item.revision, fields: fields, operationID: UUID().uuidString)
            history?.record(receipt)
            notice = fields["removed"] as? Bool == true ? "已移除材料，旧引用不再作为当前证据。" : "材料已保存，旧引用已失效。"
            await load()
        } catch { let message = error.localizedDescription; await load(); self.error = message }
    }
    func save(_ item: BackendDocument, title: String, content: String) async throws {
        guard let client else { throw BackendClientError.unavailable }
        let receipt = try await client.updateDocument(id: item.id, revision: item.revision,
            fields: ["title": title, "content": content], operationID: UUID().uuidString)
        history?.record(receipt); await load()
    }
    func latest(_ id: String) async throws -> BackendDocument {
        guard let client else { throw BackendClientError.unavailable }
        let values = try await client.documents()
        guard let item = values.first(where: { $0.id == id }) else { throw BackendClientError.notFound }
        return item
    }
    func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "选择 UTF-8 编码的 TXT 或 Markdown 材料。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await importFile(url) }
    }
}

struct DocumentsSidebar: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: DocumentsModel
    var onSelect: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("个人材料").font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.loading { ProgressView().controlSize(.mini) }
                Text("\(model.items.count)").monospacedDigit()
            }.foregroundStyle(.secondary).padding(16)
            if model.visibleItems.isEmpty {
                VStack(spacing: 10) {
                    Text(model.items.isEmpty ? "导入 TXT 或 Markdown，供阅读和引用。" : "没有符合筛选条件的材料")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if model.items.isEmpty { Button("导入材料…") { model.pickFile() }.disabled(model.busy || app.backendClient == nil) }
                    else { Button("清除筛选") { model.filterText = "" } }
                }.padding(16)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.visibleItems) { item in
                        Button {
                            model.selectedID = item.id
                            app.documentSourceID = nil; app.documentSourceLine = 1
                            onSelect()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "doc.text").foregroundStyle(accent).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                    Text("\(item.format.uppercased()) · 版本 \(item.revision)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedID == item.id ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 10)
            }
            Divider()
            HStack {
                Button { Task { await model.load() } } label: { Label("刷新材料", systemImage: "arrow.clockwise") }
                    .disabled(model.loading || app.backendClient == nil)
                Spacer()
            }.font(.caption).padding(16)
        }.background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
    }
}

struct DocumentsView: View {
    @ObservedObject var app: AppModel
    let embedded: Bool
    @ObservedObject var model: DocumentsModel
    @UIState private var editing: BackendDocument?
    @UIState private var removing: BackendDocument?
    @UIState private var showHistory = false
    @Environment(\.dismiss) private var dismiss
    init(app: AppModel, model: DocumentsModel, embedded: Bool = false) {
        self.app = app; self.model = model; self.embedded = embedded
    }
    private var selected: BackendDocument? { model.selected }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(embedded ? selected?.title ?? "个人材料" : "个人材料").font(.system(size: 18, weight: .semibold)).lineLimit(1)
                    Text(selected.map { "\($0.format.uppercased()) · 版本 \($0.revision) · 保存在本机" } ?? "选择一份材料开始阅读")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let item = selected {
                    Button("引用全文") { attach(item, range: NSRange(location: 0, length: (item.content as NSString).length)) }
                    Button("编辑") { editing = item }.disabled(model.busy)
                }
                Menu {
                    if !embedded { Button("导入 TXT / Markdown…") { model.pickFile() }.disabled(model.busy) }
                    Button("修改记录与撤销…") { showHistory = true }
                    Button("刷新材料") { Task { await model.load() } }.disabled(model.loading)
                    if let item = selected { Divider(); Button("移除材料…", role: .destructive) { removing = item }.disabled(model.busy) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("材料操作")
            }
            Divider()
            if embedded { documentBody }
            else {
                HSplitView {
                    DocumentsSidebar(app: app, model: model).frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                    documentBody.frame(minWidth: 420)
                }
            }
            if model.busy { ProgressView().controlSize(.small) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); if !embedded { Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }.padding(embedded ? 18 : 20).frame(minWidth: embedded ? 520 : 740, minHeight: 500)
        // 助手修改或全局撤销刷新工作区后，同步材料列表和正文；切换回来也读取最新版本。
        .task(id: app.libraryLoading) { if !app.libraryLoading { await model.load() } }
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
    private var documentBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = selected {
                Text("选中文字，点击“添加到对话”，可跨行引用。").font(.caption).foregroundStyle(.secondary)
                DocumentSelectionText(text: item.content, line: app.documentSourceID == item.id ? app.documentSourceLine : 1) { range in attach(item, range: range) }
                    .id(item.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(model.loading ? "正在读取个人材料…" : "导入或选择一份个人材料。").foregroundStyle(.secondary)
                    if !model.loading { Button("导入 TXT / Markdown…") { model.pickFile() }.disabled(model.busy) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func attach(_ item: BackendDocument, range: NSRange) {
        guard let quote = SelectedQuote.document(item, range: range) else { return }
        if app.assistant.addQuote(quote) { if !embedded { dismiss() } }
        else { model.error = app.assistant.error }
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
