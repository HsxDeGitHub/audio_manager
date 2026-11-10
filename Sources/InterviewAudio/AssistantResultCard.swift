import SwiftUI
import AudioCore

enum AssistantScopePresentation {
    static func title(allMaterials: Bool, quotes: Int, material: String?, materialCount: Int? = nil) -> String {
        if allMaterials { return materialCount.map { "全部资料 · \($0) 份" } ?? "全部资料" }
        if quotes > 0 { return "引用片段 · \(quotes) 条" }
        return material.map { "当前资料 · " + $0 } ?? "未选择资料"
    }
    static func elapsed(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return value < 60 ? "已等待 \(value) 秒" : "已等待 \(value / 60) 分 \(value % 60) 秒"
    }
}

struct AssistantResultCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assistant: AssistantModel
    let change: AssistantChange
    @UIState private var selectedIndex = 0
    private var segmentItems: [BackendJSONValue] {
        (change.items ?? []).filter { item in
            guard case .object(let row) = item else { return false }
            return row["resource_type"]?.stringValue == "segment"
        }
    }
    private var selectedRow: [String: BackendJSONValue]? {
        guard !segmentItems.isEmpty, case .object(let row) = segmentItems[min(selectedIndex, segmentItems.count - 1)] else { return nil }
        return row
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(change.count == 0 ? "没有需要保存的差异" : change.state == "reverted" ? "已撤销 \(change.count) 项修改" : "已保存 \(change.count) 项修改",
                  systemImage: change.state == "reverted" ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
            if !segmentItems.isEmpty {
                if let row = selectedRow, case .object(let before) = row["before"], case .object(let after) = row["after"] {
                    let text = after["edited"]?.stringValue ?? after["original"]?.stringValue ?? ""
                    if case .object(let location) = row["source_location"], let start = location["start"]?.doubleValue {
                        Text("\(TimeFormat.clock(start))  \(text)").font(.callout).lineLimit(2)
                    }
                    if before["speaker"] != after["speaker"], case .object(let names) = row["speaker_names"] {
                        Text("\(names["before"]?.stringValue ?? "未识别") → \(names["after"]?.stringValue ?? "未识别")")
                            .font(.callout.weight(.medium))
                    }
                }
                Button { locate() } label: {
                    Label("定位修改 \(min(selectedIndex + 1, segmentItems.count))/\(segmentItems.count)", systemImage: "scope")
                }.buttonStyle(.link).font(.caption)
                if segmentItems.count > 1 {
                    Button("下一处修改") { selectedIndex = (selectedIndex + 1) % segmentItems.count; locate() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            DisclosureGroup("查看前后差异") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((change.items ?? []).enumerated()), id: \.offset) { _, item in
                        ChangeDifferenceView(item: item) { source in Task { await model.openAssistantSource(source, play: false) } }
                    }
                }.padding(.top, 8)
            }.font(.caption)
            Button("撤销整次修改") { Task { await assistant.revert(change.id, model: model) } }
                .controlSize(.small).disabled(assistant.activeRun != nil || change.state != "committed")
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.16)))
    }
    private func locate() {
        guard !segmentItems.isEmpty,
              case .object(let row) = segmentItems[min(selectedIndex, segmentItems.count - 1)],
              let id = row["resource_id"]?.stringValue,
              let revision = row["after_revision"]?.doubleValue else { return }
        Task { await model.openAssistantSource(.init(resourceType: "segment", resourceID: id, revision: Int(revision), line: nil, historical: nil, blockID: nil), play: false) }
    }
}
