import SwiftUI
import AudioCore

enum AssistantChangeFilter: String, CaseIterable, Identifiable {
    case all = "全部", text = "文字", punctuation = "标点", speaker = "说话人", review = "待核对"
    var id: String { rawValue }
}

struct AssistantChangeRecord: Identifiable {
    let id: Int
    let item: BackendJSONValue
    let row: [String: BackendJSONValue]
    let before: [String: BackendJSONValue]
    let after: [String: BackendJSONValue]

    init(index: Int, item: BackendJSONValue) {
        id = index; self.item = item
        if case .object(let value) = item { row = value } else { row = [:] }
        if case .object(let value) = row["before"] { before = value } else { before = [:] }
        if case .object(let value) = row["after"] { after = value } else { after = [:] }
    }

    private func text(in values: [String: BackendJSONValue]) -> String? {
        if row["resource_type"]?.stringValue == "segment" {
            return values["edited"]?.stringValue ?? values["original"]?.stringValue
        }
        return values["content"]?.stringValue
    }
    var textChanged: Bool { text(in: before) != text(in: after) }
    var punctuationOnly: Bool {
        guard textChanged, let old = text(in: before), let new = text(in: after) else { return false }
        let ignored = CharacterSet(charactersIn: "，。！？、；：,.!?;:。“”‘’「」『』（）()【】[]《》〈〉…—·").union(.whitespacesAndNewlines)
        return old.unicodeScalars.filter { !ignored.contains($0) } == new.unicodeScalars.filter { !ignored.contains($0) }
    }
    var speakerChanged: Bool {
        before["speaker"] != after["speaker"] ||
            (row["resource_type"]?.stringValue == "speaker" && before["name"] != after["name"])
    }
    var needsReview: Bool {
        (after["needs_review"] == .bool(true) || after["needs_review"]?.doubleValue == 1) &&
            !(after["reviewed"] == .bool(true) || after["reviewed"]?.doubleValue == 1)
    }
    func matches(_ filter: AssistantChangeFilter) -> Bool {
        switch filter {
        case .all: return true
        case .text: return textChanged && !punctuationOnly
        case .punctuation: return punctuationOnly
        case .speaker: return speakerChanged
        case .review: return needsReview
        }
    }
    var preview: String {
        text(in: after) ?? after["name"]?.stringValue ?? after["title"]?.stringValue ?? "查看具体差异"
    }
    var location: String {
        if case .object(let source) = row["source_location"], let start = source["start"]?.doubleValue {
            return TimeFormat.clock(start)
        }
        return ["segment": "录音片段", "document": "个人材料", "speaker": "说话人", "recording": "录音信息", "navigation": "内容导航"][row["resource_type"]?.stringValue ?? ""] ?? "资料修改"
    }
    var reference: AssistantReference? {
        guard let type = row["resource_type"]?.stringValue, let identifier = row["resource_id"]?.stringValue,
              let revision = row["after_revision"]?.doubleValue else { return nil }
        var line: Int?
        if case .object(let location) = row["source_location"], let value = location["line"]?.doubleValue, value >= 1 { line = Int(value) }
        return .init(resourceType: type, resourceID: identifier, revision: Int(revision), line: line, historical: nil, blockID: nil)
    }
}

struct AssistantChangeSummary {
    let records: [AssistantChangeRecord]
    init(_ change: AssistantChange) {
        records = (change.items ?? []).enumerated().map { AssistantChangeRecord(index: $0.offset, item: $0.element) }
    }
    var description: String {
        let labels: [(AssistantChangeFilter, String)] = [(.text, "文字修正"), (.punctuation, "标点/空格"), (.speaker, "说话人调整")]
        let parts = labels.compactMap { filter, title -> String? in
            let count = records.filter { $0.matches(filter) }.count
            return count > 0 ? "\(title) \(count) 处" : nil
        }
        return parts.isEmpty ? "可查看本次保存的具体差异。" : parts.joined(separator: " · ")
    }
    var pendingCount: Int { records.filter(\.needsReview).count }
}

struct AssistantChangeReviewView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assistant: AssistantModel
    let change: AssistantChange
    @Environment(\.dismiss) private var dismiss
    @UIState private var filter = AssistantChangeFilter.all
    @UIState private var selectedID: Int?
    @UIState private var reverting = false
    private var current: AssistantChange {
        assistant.runs.flatMap { $0.result?.allChanges ?? [] }.first { $0.id == change.id } ?? change
    }
    private var records: [AssistantChangeRecord] { AssistantChangeSummary(current).records.filter { $0.matches(filter) } }
    private var selectedIndex: Int { records.firstIndex { $0.id == selectedID } ?? 0 }
    private var selected: AssistantChangeRecord? { records.isEmpty ? nil : records[selectedIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本次修改").font(.title2.weight(.semibold))
                    Text(current.state == "reverted" ? "本次修改已撤销" : "按本次保存时的差异与核对状态筛选")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("筛选修改", selection: $filter) {
                ForEach(AssistantChangeFilter.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityLabel("筛选本次修改")
            HSplitView {
                List(selection: $selectedID) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(record.location).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Spacer()
                                if record.needsReview { Image(systemName: "questionmark.circle").foregroundStyle(.orange).accessibilityLabel("保存时待核对") }
                            }
                            Text(record.preview.isEmpty ? "（空文本）" : record.preview).font(.callout).lineLimit(2)
                        }.padding(.vertical, 4).tag(record.id)
                    }
                }.frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                ScrollView {
                    if let selected {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(selected.location).font(.headline)
                            ChangeDifferenceView(item: selected.item, font: .body)
                            if let reference = selected.reference {
                                Button("在正文中查看") { open(reference) }.buttonStyle(.link)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(records.isEmpty && filter == .all ? "此记录未包含逐项差异。" : "本次修改没有符合筛选条件的项目。")
                            .foregroundStyle(.secondary).padding(24)
                    }
                }.frame(minWidth: 380, maxWidth: .infinity)
            }.frame(maxHeight: .infinity)
            HStack {
                Text(records.isEmpty ? "0 项" : "\(selectedIndex + 1) / \(records.count) 项").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("上一处") { move(-1) }.disabled(records.isEmpty || selectedIndex == 0)
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                Button("下一处") { move(1) }.disabled(records.isEmpty || selectedIndex == records.count - 1)
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                Spacer()
                Button("撤销整次修改") {
                    reverting = true
                    Task { await assistant.revert(change.id, model: model); reverting = false }
                }.disabled(reverting || assistant.activeRun != nil || current.state != "committed")
            }
            if let error = assistant.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(22).frame(minWidth: 840, idealWidth: 960, minHeight: 560, idealHeight: 660)
            .onAppear { selectedID = records.first?.id }
            .onChange(of: filter) { _, _ in selectedID = records.first?.id }
    }
    private func move(_ delta: Int) {
        guard !records.isEmpty else { return }
        selectedID = records[max(0, min(selectedIndex + delta, records.count - 1))].id
    }
    private func open(_ source: AssistantReference) {
        dismiss()
        Task { await model.openAssistantSource(source, play: false) }
    }
}
