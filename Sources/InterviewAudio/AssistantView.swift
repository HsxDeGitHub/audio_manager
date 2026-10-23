import SwiftUI
import AppKit
import AudioCore

struct AssistantView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assistant: AssistantModel
    @UIState private var inputHeight: CGFloat = 54
    @UIState private var following = true
    @UIState private var renamingSession: AssistantSession?
    @UIState private var deletingSession: AssistantSession?
    @UIState private var confirmingDeletion = false
    @UIState private var deletionError: String?
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.selectedID) { _, _ in assistant.contextChanged(model: model) }
        .onChange(of: model.selected?.activeRun) { _, _ in assistant.contextChanged(model: model) }
        .task { await assistant.reconnect(model: model) }
        .sheet(item: $renamingSession) { session in
            AssistantRenameSessionView(assistant: assistant, session: session)
        }
        .confirmationDialog("删除会话？", isPresented: $confirmingDeletion, titleVisibility: .visible, presenting: deletingSession) { session in
            Button("删除会话", role: .destructive) {
                Task { @MainActor in
                    do { try await assistant.deleteSession(session.id) }
                    catch { deletionError = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) { }
        } message: { session in
            Text("将从列表中删除“\(session.title)”。录音、转写和已保存的资料修改会保留。")
        }
        .alert("删除失败", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("好") { deletionError = nil }
        } message: { Text(deletionError ?? "") }
    }
    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Label("听阅助手", systemImage: "sparkles").font(.headline)
                Spacer()
                Menu {
                    Menu("侧栏宽度") {
                        ForEach([320, 380, 440, 560], id: \.self) { width in
                            Button("\(width) 点" + (width == 380 ? "（默认）" : "")) { NotificationCenter.default.post(name: .assistantPanelWidthChanged, object: Double(width)) }
                        }
                    }
                    Divider()
                    Button("个人材料…") { model.showDocuments = true }
                    Button("长期记忆…") { model.showMemories = true }
                    Button("工具与 MCP…") { model.showToolSettings = true }
                    Button("大模型配置…") { model.showAISettings = true }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("助手设置").accessibilityLabel("助手设置")
                Button { Task { await assistant.createSession() } } label: { Image(systemName: "square.and.pencil") }.help("新对话").accessibilityLabel("新对话").disabled(assistant.sending || assistant.managingSession)
                Button { assistant.toggle() } label: { Image(systemName: "sidebar.right") }.help("收起助手 ⌘⇧A").accessibilityLabel("收起助手")
            }.buttonStyle(.plain)
            HStack(spacing: 8) {
                Picker("会话", selection: Binding(get: { assistant.selectedSession ?? "" }, set: { id in Task { await assistant.select(id) } })) {
                    Text("新对话").tag("")
                    ForEach(assistant.sessions) { Text($0.title).tag($0.id) }
                }.labelsHidden().accessibilityLabel("助手会话").disabled(assistant.sending || assistant.managingSession)
                Menu {
                    Button { renamingSession = assistant.sessions.first { $0.id == assistant.selectedSession } } label: { Label("重命名话题…", systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive) {
                        deletingSession = assistant.sessions.first { $0.id == assistant.selectedSession }; confirmingDeletion = true
                    } label: { Label("删除会话…", systemImage: "trash") }
                        .disabled(!assistant.canDeleteSelectedSession)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("话题管理").accessibilityLabel("话题管理")
                    .disabled(assistant.client == nil || assistant.sending || assistant.managingSession || !assistant.sessions.contains { $0.id == assistant.selectedSession })
            }
        }.padding(14)
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if assistant.messages.isEmpty && !assistant.sending {
                            VStack(alignment: .leading, spacing: 14) {
                                Image(systemName: "quote.bubble").font(.system(size: 28)).foregroundStyle(accent)
                                Text("边听边问，思路更清楚").font(.headline)
                                Text("分析当前资料、总结面试问题，或引用一段话继续讨论。").font(.callout).foregroundStyle(.secondary)
                                ForEach(["总结这次面试的全部问题", "分析回答中最需要改进的地方"], id: \.self) { prompt in
                                    Button(prompt) { assistant.input = prompt; assistant.focusRequest = UUID() }.buttonStyle(.bordered)
                                }
                            }.padding(.vertical, 26).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(assistant.messages.filter { $0.role == "user" }) { message in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack { Spacer(minLength: 24); Text(message.content).font(.system(size: 14)).textSelection(.enabled).padding(12).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12)) }
                                ForEach(assistant.runs.filter { $0.messageID == message.id }) { run in
                                    AssistantRunView(model: model, assistant: assistant, run: run)
                                }
                            }.id(message.id)
                        }
                        // 兼容没有message_id的旧契约响应。
                        ForEach(assistant.runs.filter { $0.messageID == nil }) { run in AssistantRunView(model: model, assistant: assistant, run: run) }
                        Color.clear.frame(height: 1).id("assistant-bottom")
                    }.padding(16)
                        .background(AssistantScrollProbe { atBottom in following = atBottom })
                }
                if !following {
                    Button { following = true; proxy.scrollTo("assistant-bottom", anchor: .bottom) } label: { Label("回到最新", systemImage: "arrow.down") }
                        .buttonStyle(.borderedProminent).controlSize(.small).padding(.bottom, 8)
                }
            }
            .onChange(of: assistant.changeToken) { _, _ in if following { proxy.scrollTo("assistant-bottom", anchor: .bottom) } }
            .onChange(of: assistant.selectedSession) { _, _ in following = true; proxy.scrollTo("assistant-bottom", anchor: .bottom) }
            .onChange(of: assistant.sending) { _, sending in if sending { following = true; proxy.scrollTo("assistant-bottom", anchor: .bottom) } }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let error = assistant.error, !assistant.runs.contains(where: { $0.result?.error?.message == error }) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top) { Image(systemName: "exclamationmark.circle"); Text(error).textSelection(.enabled); Spacer(); Button { assistant.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示") }
                    HStack {
                        Button(assistant.client == nil ? "重连本地服务" : "刷新连接") { Task { if assistant.client == nil { await model.connectBackend() } else { await assistant.reconnect(model: model) } } }
                        Button("模型配置") { model.showAISettings = true }
                    }.controlSize(.small)
                }.font(.caption).foregroundStyle(.secondary).padding(9).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 7) {
                Menu {
                    Button("当前资料") { assistant.allMaterials = false }
                    Button("全部资料") { assistant.allMaterials = true }
                } label: {
                    Label(assistant.allMaterials ? "全部资料" : model.selected?.title ?? "未选择资料", systemImage: assistant.allMaterials ? "square.stack" : "doc.text").lineLimit(1)
                }.menuStyle(.borderlessButton).font(.caption).accessibilityLabel("提问范围")
                Spacer(minLength: 0)
                if !assistant.allMaterials {
                    Button { assistant.quote(model: model) } label: { Image(systemName: "text.badge.plus") }.buttonStyle(.plain).help("引用选中段落").accessibilityLabel("引用选中段落")
                        .disabled(model.focusSegmentID == nil && model.bulkSelection.isEmpty)
                }
            }.foregroundStyle(.secondary)
            if !assistant.quotedIDs.isEmpty {
                HStack { Label("已引用 \(assistant.quotedIDs.count) 段", systemImage: "quote.opening"); Spacer(); Button("移除引用") { assistant.quotedIDs = [] }.buttonStyle(.plain) }
                    .font(.caption).padding(7).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            if assistant.activeRun != nil || assistant.sending {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(assistant.sending ? "正在发送…" : assistant.progress).font(.caption).lineLimit(2)
                    Spacer()
                    if assistant.activeRun != nil { Button("停止") { Task { await assistant.cancel() } }.controlSize(.small) }
                }.foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ZStack(alignment: .topLeading) {
                    if assistant.input.isEmpty { Text("提问，或描述你想完成的操作…").font(.system(size: 14)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 9).allowsHitTesting(false) }
                    AssistantInput(text: $assistant.input, height: $inputHeight, focusRequest: assistant.focusRequest) { Task { await assistant.send(model: model) } }
                        .frame(height: inputHeight)
                }
                HStack {
                    Text(assistant.input.unicodeScalars.count > 18000 ? "\(assistant.input.unicodeScalars.count)/20000" : "Enter 发送 · ⇧Enter 换行")
                        .font(.caption2).foregroundStyle(assistant.input.unicodeScalars.count > 20000 ? Color.red : Color.secondary)
                    Spacer()
                    Button { Task { await assistant.send(model: model) } } label: { Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 18, height: 18) }
                        .buttonStyle(.borderedProminent).clipShape(RoundedRectangle(cornerRadius: 8)).disabled(!assistant.canSend).accessibilityLabel("发送")
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.20)))
            Text("原话、分析与建议分别标注 · 内容保存在本机").font(.caption2).foregroundStyle(.tertiary)
        }.padding(12)
    }
}

private struct AssistantRenameSessionView: View {
    @ObservedObject var assistant: AssistantModel
    let session: AssistantSession
    @Environment(\.dismiss) private var dismiss
    @UIState private var title: String
    @UIState private var saving = false
    @UIState private var error: String?
    @FocusState private var focused: Bool

    init(assistant: AssistantModel, session: AssistantSession) {
        self.assistant = assistant; self.session = session
        _title = UIState(initialValue: session.title)
    }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmedTitle.isEmpty && trimmedTitle.unicodeScalars.count <= 120 }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名话题").font(.headline)
            TextField("话题名称", text: $title).textFieldStyle(.roundedBorder).focused($focused).disabled(saving)
            Text("名称最多 120 个字符").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("保存") {
                    saving = true; error = nil
                    Task { @MainActor in
                        defer { saving = false }
                        do { try await assistant.renameSession(session.id, title: title); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(!valid || saving)
            }
        }.padding(24).frame(width: 360).interactiveDismissDisabled(saving)
            .onAppear { focused = true }
    }
}

private struct AssistantRunView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var assistant: AssistantModel
    let run: AssistantRun
    private var running: Bool { assistant.activeRun == run.id }
    private var answer: String {
        if ["completed", "awaiting_input"].contains(run.state), let answer = run.result?.answer { return answer }
        let partial = assistant.output(run.id)
        return partial.isEmpty ? run.result?.answer ?? "" : partial
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(accent)
                Text("听阅").fontWeight(.medium)
                Text(running ? "生成中 · 待校验" : stateTitle).foregroundStyle(.secondary)
                Spacer()
                if !answer.isEmpty { Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制回答").accessibilityLabel("复制回答") }
            }.font(.caption)
            if run.context?.historyOmitted == true { Text("历史较长，本次仅参考最近的部分对话。").font(.caption).foregroundStyle(.secondary) }
            if !answer.isEmpty {
                if running || !["completed", "awaiting_input"].contains(run.state) { Text(answer).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                else { AssistantMarkdown(text: answer) }
            } else if running { Text("正在读取资料并准备回答…").font(.callout).foregroundStyle(.secondary) }
            if let result = run.result { details(result) }
            if let error = run.result?.error {
                Label(error.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                if error.code.hasPrefix("model_") { Button("打开大模型配置") { model.showAISettings = true }.controlSize(.small) }
            }
            if ["interrupted", "failed", "cancelled"].contains(run.state) {
                HStack {
                    Button("继续未完成任务") { Task { await assistant.resume(run.id, model: model) } }.disabled(assistant.activeRun != nil)
                    Button("基于当前资料重新提问") {
                        assistant.input = assistant.messages.first(where: { $0.id == run.messageID })?.content ?? ""
                        assistant.focusRequest = UUID()
                    }
                }.font(.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var stateTitle: String { ["completed":"已完成", "awaiting_input":"需要补充", "cancelled":"已停止 · 输出未完成", "failed":"失败 · 输出未完成", "interrupted":"已中断 · 可继续"][run.state] ?? "准备中" }
    @ViewBuilder private func details(_ result: AssistantResult) -> some View {
        if let coverage = result.coverage {
            Text("\(coverage.progressTitle) · 未纳入 \(coverage.excluded?.count ?? 0) 项").font(.caption).foregroundStyle(.secondary)
            if let parts = coverage.parts, !parts.isEmpty {
                DisclosureGroup("覆盖明细") {
                    if let covered = coverage.sourceCovered, let total = coverage.sourceTotal { Text("完整来源 \(covered)/\(total)") }
                    ForEach(parts) { part in HStack { Button(part.label) { Task { await model.openAssistantSource(part.reference, play: false) } }.buttonStyle(.link); Spacer(); Text(part.stateTitle) } }
                }.font(.caption)
            }
        }
        if let partial = result.partialResults, !partial.isEmpty {
            DisclosureGroup("已保留的分块分析（\(partial.count)）") { ForEach(Array(partial.enumerated()), id: \.offset) { _, item in Text(item.answer).textSelection(.enabled) } }.font(.caption)
        }
        if let questions = result.questions, !questions.isEmpty {
            DisclosureGroup("问题清单与来源（\(questions.count)）") {
                ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                    VStack(alignment: .leading, spacing: 5) { Text("\(index + 1). \(question.text)").textSelection(.enabled); sourceButtons(question.source) }.padding(.vertical, 5)
                }
            }.font(.caption)
        }
        if let claims = result.claims, !claims.isEmpty {
            DisclosureGroup("依据与分析（\(claims.count)）") {
                ForEach(Array(claims.enumerated()), id: \.offset) { _, claim in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(kindTitle(claim.kind))：\(claim.text)").textSelection(.enabled)
                        ForEach(Array(Set(claim.sources)).sorted { $0.resourceID < $1.resourceID }, id: \.self) { source in sourceButtons(source) }
                    }.padding(.vertical, 5)
                }
            }.font(.caption)
        }
        ForEach(result.allChanges, id: \.id) { change in
            VStack(alignment: .leading, spacing: 7) {
                Label("修改 \(change.count) 项 · \(change.state == "reverted" ? "已撤销" : "已提交")", systemImage: "checkmark.circle")
                if let items = change.items { DisclosureGroup("前后差异") { ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text(ChangeDifference.describe(item)).textSelection(.enabled) } } }
                Button("撤销整次修改") { Task { await assistant.revert(change.id, model: model) } }.disabled(assistant.activeRun != nil || change.state == "reverted")
            }.font(.caption).padding(10).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func sourceButtons(_ source: AssistantReference) -> some View {
        HStack {
            if source.historical == true { Text("历史引用").foregroundStyle(.secondary) }
            Button("查看来源") { Task { await model.openAssistantSource(source, play: false) } }
            if source.resourceType == "segment" { Button("回听") { Task { await model.openAssistantSource(source, play: true) } } }
        }.buttonStyle(.link)
    }
    private func kindTitle(_ kind: String) -> String { ["original_statement":"原话", "user_statement":"用户陈述", "analysis":"分析", "suggestion":"建议", "insufficient_evidence":"证据不足"][kind] ?? "待核对" }
}

struct AssistantToggle: View {
    @ObservedObject var assistant: AssistantModel
    var body: some View {
        Button { assistant.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "sidebar.right")
                Text("听阅助手")
                if assistant.anyRunning { ProgressView().controlSize(.mini) }
                else if assistant.hasUnread { Circle().fill(accent).frame(width: 6, height: 6) }
            }
        }.help("显示或收起助手 ⌘⇧A").accessibilityLabel("显示或收起听阅助手")
    }
}
