import SwiftUI
import AudioCore

enum NavigationKind: String, Codable, CaseIterable, Identifiable {
    case chapter, bookmark, later
    var id: String { rawValue }
    var title: String { switch self { case .chapter: return "章节"; case .bookmark: return "书签"; case .later: return "稍后复听" } }
    var symbol: String { switch self { case .chapter: return "list.bullet.indent"; case .bookmark: return "bookmark"; case .later: return "headphones" } }
}

struct NavigationMark: Decodable, Identifiable {
    let id: String
    let runID: String
    let segmentID: String
    let kind: NavigationKind
    let title: String
    let start: Double
    let end: Double
    let revision: Int
    enum CodingKeys: String, CodingKey {
        case id, kind, title, start, end, revision
        case runID = "run_id", segmentID = "segment_id"
    }
}

@MainActor final class NavigationModel: ObservableObject {
    @Published var items: [NavigationMark] = []
    @Published var error: String?
    @Published var busy = false
    var client: BackendClient?
    private(set) var recordingID: String?
    private(set) var runID: String?
    private var generation = UUID()
    private var pendingCreate: (fingerprint: Data, body: Data)?
    private var pendingUpdate: (fingerprint: Data, body: Data)?

    func load(recordingID: String, runID: String?) async {
        let changed = self.recordingID != recordingID || self.runID != runID
        self.recordingID = recordingID; self.runID = runID
        if changed { items = []; error = nil }
        let request = UUID(); generation = request
        guard let client, let runID else { return }
        do {
            let page: AssistantItems<NavigationMark> = try await client.send("/api/v1/recordings/\(recordingID)/navigation?run_id=\(runID)")
            guard generation == request else { return }
            items = page.items; error = nil
        } catch { if generation == request { self.error = error.localizedDescription } }
    }

    @discardableResult func create(_ marks: [[String: Any]], recordingID: String, history: ChangeHistoryModel) async -> Bool {
        guard let client, !busy, !marks.isEmpty else { return false }
        busy = true; defer { busy = false }
        do {
            let fingerprint = try JSONSerialization.data(withJSONObject: ["recording_id": recordingID, "marks": marks], options: .sortedKeys)
            if pendingCreate?.fingerprint != fingerprint {
                let rows = marks.map { $0.merging(["id": UUID().uuidString]) { _, new in new } }
                let body = try JSONSerialization.data(withJSONObject: ["operation_id": UUID().uuidString, "marks": rows])
                pendingCreate = (fingerprint, body)
            }
            let change: AssistantChange = try await client.send("/api/v1/recordings/\(recordingID)/navigation", method: "POST", body: pendingCreate?.body)
            history.record(change); pendingCreate = nil
            if self.recordingID == recordingID { await load(recordingID: recordingID, runID: runID) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func update(_ mark: NavigationMark, fields: [String: Any], history: ChangeHistoryModel) async -> Bool {
        guard let client, !busy else { return false }
        busy = true; defer { busy = false }
        do {
            let fingerprint = try JSONSerialization.data(withJSONObject: ["id": mark.id, "revision": mark.revision, "fields": fields], options: .sortedKeys)
            if pendingUpdate?.fingerprint != fingerprint {
                let data = try JSONSerialization.data(withJSONObject: ["operation_id": UUID().uuidString,
                    "expected_revision": mark.revision, "fields": fields])
                pendingUpdate = (fingerprint, data)
            }
            let change: AssistantChange = try await client.send("/api/v1/navigation/\(mark.id)", method: "PATCH", body: pendingUpdate?.body)
            pendingUpdate = nil
            history.record(change)
            if let recordingID { await load(recordingID: recordingID, runID: runID) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct NavigationPanel: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: NavigationModel
    @UIState private var kind = NavigationKind.chapter
    @UIState private var adding = false
    @UIState private var editing: NavigationMark?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("内容导航").font(.headline)
                Spacer()
                Button { adding = true } label: { Label("添加", systemImage: "plus") }.disabled(app.segments.isEmpty || model.busy)
            }
            Picker("导航类型", selection: $kind) { ForEach(NavigationKind.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.items.filter({ $0.kind == kind }).isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: kind.symbol).font(.title2).foregroundStyle(.secondary)
                            Text("还没有\(kind.title)").font(.callout.weight(.medium))
                            Text(kind == .chapter ? "标记重要段落，或从助手问题清单生成章节。" : "给当前句子添加标记，方便下次回来。").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 24)
                    }
                    ForEach(model.items.filter { $0.kind == kind }) { mark in
                        HStack(alignment: .top) {
                            Button { app.revealSegment(mark.segmentID) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(mark.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Text(TimeFormat.clock(mark.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Menu {
                                Button("回听") { app.revealSegment(mark.segmentID, play: true) }
                                Button("编辑标题与位置…") { editing = mark }
                                Button("移除标记", role: .destructive) { Task { await model.update(mark, fields: ["removed": true], history: app.changeHistory) } }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("\(mark.title)的操作")
                        }.padding(10).background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Button("修改记录与撤销…") { app.showChangeHistory = true }.font(.caption)
        }.padding(18).frame(width: 340, height: 450)
            .sheet(isPresented: $adding) { NavigationEditor(app: app, model: model, kind: kind) }
            .sheet(item: $editing) { NavigationEditor(app: app, model: model, kind: $0.kind, mark: $0) }
    }
}

struct NavigationEditor: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: NavigationModel
    let kind: NavigationKind
    var mark: NavigationMark? = nil
    var initialSegmentID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @UIState private var title = ""
    @UIState private var segmentID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(mark == nil ? "添加\(kind.title)" : "编辑\(kind.title)").font(.title2.weight(.semibold))
            TextField("标题", text: $title).textFieldStyle(.roundedBorder).accessibilityLabel("导航标题")
            Picker("定位句子", selection: $segmentID) {
                ForEach(app.segments) { segment in Text("\(TimeFormat.clock(segment.start))  \(segment.text.prefix(28))").tag(segment.id) }
            }
            Text("位置绑定原始句子，切换转写版本后分别保留。可在修改记录中撤销。").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.busy ? "保存中…" : "保存") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200 || segmentID.isEmpty)
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(model.busy)
            .onAppear {
                segmentID = mark?.segmentID ?? initialSegmentID ?? app.focusSegmentID ?? app.currentSegmentID ?? app.segments.first?.id ?? ""
                title = mark?.title ?? app.segments.first(where: { $0.id == segmentID }).map { String($0.text.prefix(40)) } ?? ""
                model.error = nil
            }
    }
    private func save() async {
        guard let recordingID = app.selectedID else { return }
        let success: Bool
        if let mark { success = await model.update(mark, fields: ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "segment_id": segmentID], history: app.changeHistory) }
        else {
            guard let store = app.store else { return }
            let revision = store.contentRevision("segment", id: segmentID)
            success = await model.create([["segment_id": segmentID, "expected_revision": revision, "kind": kind.rawValue,
                "title": title.trimmingCharacters(in: .whitespacesAndNewlines)]], recordingID: recordingID, history: app.changeHistory)
        }
        if success { dismiss() }
    }
}
