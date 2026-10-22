import SwiftUI
import AudioCore

struct AssistantView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assistant: AssistantModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("听阅助手").font(.headline)
                Spacer()
                Button("材料") { model.showDocuments = true }
                Button("记忆") { model.showMemories = true }
                Button("工具") { model.showToolSettings = true }
                Button("新对话") { Task { await assistant.createSession() } }
            }
            Picker("会话", selection: Binding(get: { assistant.selectedSession ?? "" }, set: { id in Task { await assistant.select(id) } })) {
                Text("选择会话").tag("")
                ForEach(assistant.sessions) { Text($0.title).tag($0.id) }
            }
            Toggle("全部资料", isOn: $assistant.allMaterials)
            Text(assistant.allMaterials ? "发送时固定全部资料及版本" : "当前：\(model.selected?.title ?? "未选择资料")").font(.caption).foregroundStyle(.secondary)
            if !assistant.allMaterials {
                HStack {
                    Button("引用选中段落") { assistant.quotedIDs = model.bulkSelection.isEmpty ? model.focusSegmentID.map { [$0] } ?? [] : Array(model.bulkSelection) }
                    if !assistant.quotedIDs.isEmpty { Text("\(assistant.quotedIDs.count) 段").font(.caption); Button("清除") { assistant.quotedIDs = [] } }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(assistant.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.role == "user" ? "你" : "助手").font(.caption).foregroundStyle(.secondary)
                            Text(message.content).textSelection(.enabled)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(assistant.runs) { run in
                        if let result = run.result {
                            if let coverage = result.coverage {
                                Text("\(coverage.progressTitle) · 无法纳入 \(coverage.excluded?.count ?? 0) 项").font(.caption).foregroundStyle(.secondary)
                                if let covered = coverage.sourceCovered, let total = coverage.sourceTotal { Text("完整来源 \(covered)/\(total)").font(.caption2).foregroundStyle(.secondary) }
                                if let parts = coverage.parts, !parts.isEmpty {
                                    DisclosureGroup("已完成与剩余范围") {
                                        ForEach(parts) { part in
                                            HStack {
                                                Button(part.label) { Task { await model.openAssistantSource(part.reference, play: false) } }.buttonStyle(.link)
                                                Spacer(); Text(part.stateTitle)
                                            }.font(.caption)
                                        }
                                    }
                                }
                            }
                            if let partial = result.partialResults, !partial.isEmpty {
                                DisclosureGroup("已保留的分块分析（\(partial.count)）") {
                                    ForEach(Array(partial.enumerated()), id: \.offset) { _, item in Text(item.answer).font(.caption).textSelection(.enabled) }
                                }
                            }
                            if let questions = result.questions, !questions.isEmpty {
                                DisclosureGroup("问题清单（\(questions.count) 条）") {
                                    ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("\(index + 1). \(question.text)").textSelection(.enabled)
                                            HStack {
                                                Button("查看来源") { Task { await model.openAssistantSource(question.source, play: false) } }
                                                if question.source.resourceType == "segment" {
                                                    Button("回听") { Task { await model.openAssistantSource(question.source, play: true) } }
                                                }
                                                if let start = question.start { Text("\(Int(start) / 60):\(String(format: "%02d", Int(start) % 60))").foregroundStyle(.secondary) }
                                            }.font(.caption)
                                        }.padding(.vertical, 5)
                                    }
                                }
                            }
                            if let claims = result.claims {
                                ForEach(Array(claims.enumerated()), id: \.offset) { _, claim in
                                    VStack(alignment: .leading) {
                                        Text("\(kindTitle(claim.kind))：\(claim.text)").font(.caption)
                                        ForEach(claim.sources, id: \.self) { source in
                                            HStack {
                                                if source.historical == true { Text("修改前历史引用").foregroundStyle(.secondary) }
                                                Button("查看来源") { Task { await model.openAssistantSource(source, play: false) } }
                                                if source.resourceType == "segment" { Button("回听") { Task { await model.openAssistantSource(source, play: true) } } }
                                            }.font(.caption)
                                        }
                                    }
                                }
                            }
                            ForEach(result.allChanges, id: \.id) { change in
                                Text("修改 \(change.count) 项 · \(change.state == "reverted" ? "已撤销" : "已提交")").font(.caption)
                                if let items = change.items { DisclosureGroup("前后差异") { ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text(difference(item)).font(.caption).textSelection(.enabled) } } }
                                Button("撤销整次修改") { Task { await assistant.revert(change.id, model: model) } }.disabled(assistant.activeRun != nil || change.state == "reverted")
                            }
                            if let error = result.error { Text(error.message).font(.caption).foregroundStyle(.red) }
                        }
                        if ["interrupted", "failed", "cancelled"].contains(run.state) { Button("继续中断任务") { Task { await assistant.resume(run.id, model: model) } }.disabled(assistant.activeRun != nil) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = assistant.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if assistant.activeRun != nil { HStack { ProgressView().controlSize(.small); Text(assistant.progress).font(.caption); Spacer(); Button("取消") { Task { await assistant.cancel() } } } }
            TextEditor(text: $assistant.input).frame(minHeight: 70, maxHeight: 110).border(Color.secondary.opacity(0.25))
            HStack { Text("原话、分析与建议分别标注").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("发送") { Task { await assistant.send(model: model) } }.buttonStyle(.borderedProminent).disabled(assistant.activeRun != nil || assistant.client == nil || assistant.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(14)
    }
    private func kindTitle(_ kind: String) -> String { ["original_statement": "原话", "user_statement": "用户陈述", "analysis": "分析", "suggestion": "建议", "insufficient_evidence": "证据不足"][kind] ?? "待核对" }
    private func difference(_ item: BackendJSONValue) -> String {
        guard case .object(let row) = item, case .object(let before) = row["before"], case .object(let after) = row["after"] else { return "修改详情不可用" }
        let labels = ["edited": "正文", "title": "名称", "name": "说话人名称", "speaker": "说话人归属", "payload": "整理稿", "content": "内容", "kind": "资料类型", "interview_date": "实际面试日期", "company": "公司", "role": "岗位", "state": "状态"]
        return after.keys.sorted().filter { before[$0] != after[$0] && $0 != "revision" }.map { key in
            "\(labels[key] ?? "内容")\n修改前：\(display(before[key]))\n修改后：\(display(after[key]))"
        }.joined(separator: "\n\n")
    }
    private func display(_ value: BackendJSONValue?) -> String {
        switch value {
        case .string(let text): return text.isEmpty ? "（空）" : text
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .bool(let value): return value ? "是" : "否"
        case .array(let values): return values.map { display($0) }.joined(separator: "、")
        case .object(let values): return values.keys.sorted().map { "\($0)：\(display(values[$0]))" }.joined(separator: "\n")
        case .null, .none: return "无"
        }
    }
}
