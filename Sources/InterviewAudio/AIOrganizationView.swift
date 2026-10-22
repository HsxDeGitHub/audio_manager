import SwiftUI
import AppKit
import AudioCore

struct AISettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @UIState private var settings = AISettings()
    @UIState private var showKey = false
    @UIState private var testing = false
    @UIState private var message = ""
    @UIState private var testTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("大模型配置").font(.title2.weight(.semibold))
            Text("连接支持 chat/completions 的文本接口，用于整理已有转写。").font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow { Text("接口地址"); TextField("https://服务地址/v1", text: $settings.baseURL) }
                GridRow { Text("模型名称"); TextField("填写服务提供的模型 ID", text: $settings.model) }
                GridRow {
                    Text("API Key")
                    HStack {
                        if showKey { TextField("本地免认证服务可留空", text: $settings.apiKey) }
                        else { SecureField("本地免认证服务可留空", text: $settings.apiKey) }
                        Toggle("显示", isOn: $showKey).toggleStyle(.checkbox)
                    }
                }
                GridRow { Text("每块正文字数"); TextField("4500", value: $settings.chunkCharacters, format: .number).frame(width: 110) }
                GridRow { Text("输出 token 上限"); TextField("8192", value: $settings.maxOutputTokens, format: .number).frame(width: 110) }
            }.textFieldStyle(.roundedBorder).disabled(testing)
            Text("长录音按块处理。若模型提示上下文不足或输出截断，可减小每块字数。接口地址也可填写完整的 /chat/completions 地址。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("配置（含 API Key）直接保存在本机 llm-settings.json，可手动编辑，文件仅当前用户可读写。").font(.caption).foregroundStyle(.secondary)
            Text(model.aiConfigurationURL.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            Button("打开配置目录") { NSWorkspace.shared.open(model.dataDirectory) }.font(.caption)
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Button(testing ? "测试中…" : "测试连接") { testConnection() }.disabled(testing)
                if testing { ProgressView().controlSize(.small); Button("取消测试") { testTask?.cancel() } }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try model.saveAISettings(settings); dismiss() }
                    catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(testing).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 660)
        .onAppear { model.reloadAISettings(); settings = model.aiSettings }
        .onDisappear { testTask?.cancel() }
    }
    private func testConnection() {
        testing = true; message = "仅发送一条连接测试消息。"
        let configuration = settings
        testTask = Task {
            defer { testing = false }
            do { try await model.aiClient.test(settings: configuration); message = "连接成功，可以保存配置。" }
            catch { message = Task.isCancelled ? "已取消测试。" : error.localizedDescription }
        }
    }
}

struct AIComposeView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @UIState private var mode: AIOrganizationMode = .dialogue
    @UIState private var instructions = ""
    @UIState private var configuring = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AI 整理").font(.title2.weight(.semibold))
            Text(model.selected?.title ?? "").font(.headline).lineLimit(2)
            Picker("整理方式", selection: $mode) {
                ForEach(AIOrganizationMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(mode.instructions).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("额外要求（可选）").font(.headline)
            TextEditor(text: $instructions).font(.body).frame(height: 105).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text("例如：这是技术面试，按问题、回答、追问组织，保留技术细节和实际例子。").font(.caption).foregroundStyle(.secondary)
            Divider()
            if model.aiSettings.model.isEmpty {
                Text("请先在右上角设置菜单中配置大模型接口。").foregroundStyle(.orange)
            } else {
                Text("将向 \(model.aiSettings.baseURL) 的 \(model.aiSettings.model) 发送当前转写文字和说话人标签，用于生成独立整理稿。原音频不会发送。").font(.caption).foregroundStyle(.secondary)
            }
            Text("使用当前转写版本及人工校对内容。生成结果仍需核对，可随时回看原文与回听。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("大模型设置…") { configuring = true }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("开始整理") { model.startAI(mode: mode, instructions: instructions) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.aiSettings.model.isEmpty || model.aiActiveDraftID != nil)
            }
        }.padding(26).frame(width: 650)
        .onAppear { model.reloadAISettings() }
        .sheet(isPresented: $configuring) { AISettingsView(model: model) }
    }
}

struct AIDraftReaderView: View {
    @ObservedObject var model: AppModel
    @UIState private var editingBlock: AIBlock?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !model.aiDrafts.isEmpty {
                    Picker("整理稿", selection: Binding(get: { model.selectedAIDraftID ?? "" }, set: { model.selectedAIDraftID = $0 })) {
                        ForEach(model.aiDrafts) { draft in
                            Text("\(Date(timeIntervalSince1970: draft.createdAt).formatted(date: .abbreviated, time: .shortened)) · \(draft.mode.title) · \(draft.state.title)").tag(draft.id)
                        }
                    }.frame(maxWidth: 600)
                }
                Spacer()
                Button("生成新稿") { model.showAICompose = true }.disabled(model.aiActiveDraftID != nil)
            }.padding(.horizontal, 26).padding(.vertical, 12)
            if let draft = model.selectedAIDraft {
                draftStatus(draft)
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(draft.blocks) { block in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top) {
                                    if !block.title.isEmpty { Text(block.title).font(.headline).textSelection(.enabled) }
                                    Spacer()
                                    Button("编辑") { editingBlock = block }.font(.caption).disabled(draft.id == model.aiActiveDraftID)
                                }
                                Text(block.text).font(.system(size: model.readerFontSize)).lineSpacing(7).textSelection(.enabled)
                                Menu {
                                    ForEach(draft.sources.filter { block.sourceIDs.contains($0.id) }, id: \.id) { source in
                                        Button("\(TimeFormat.clock(source.start)) · \(source.speaker) · 查看原文") { model.openAISource(source, play: false) }
                                        Button("\(TimeFormat.clock(source.start)) · 回听") { model.openAISource(source, play: true) }
                                    }
                                } label: { Label("原文与回听（\(block.sourceIDs.count) 处）", systemImage: "waveform") }
                                    .menuStyle(.borderlessButton).fixedSize().font(.caption)
                                Divider()
                            }.id(block.id).background(model.focusAIDraftBlockID == block.id ? accent.opacity(0.08) : Color.clear)
                        }
                        if draft.blocks.isEmpty { Text("整理后的段落将在这里显示。").foregroundStyle(.secondary).padding(.vertical, 40) }
                    }.frame(maxWidth: 900, alignment: .leading).padding(30).frame(maxWidth: .infinity)
                }.onChange(of: model.focusAIDraftBlockID, initial: true) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
                    Text("当前转写版本还没有 AI 整理稿").foregroundStyle(.secondary)
                    Button("开始整理") { model.showAICompose = true }.disabled(model.aiActiveDraftID != nil)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $editingBlock) { block in
            AIBlockEditor(block: block) { title, text in
                if let draft = model.selectedAIDraft { model.saveAIBlock(draftID: draft.id, blockID: block.id, title: title, text: text) }
            }
        }
    }
    @ViewBuilder private func draftStatus(_ draft: AIDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(draft.model) · \(draft.state.title) · \(draft.completedChunks)/\(draft.chunks.count) 块").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if draft.id == model.aiActiveDraftID { Button("取消整理") { model.cancelAI() } }
                else if draft.state != .completed { Button("继续 / 重试未完成分块") { model.resumeAI(draft) }.disabled(model.aiActiveDraftID != nil) }
                Menu("导出整理稿") {
                    Button("TXT…") { model.exportAI(markdown: false) }
                    Button("Markdown…") { model.exportAI(markdown: true) }
                    Button("复制全部") { model.copyText(draft.export(markdown: false)) }
                }.menuStyle(.borderlessButton).fixedSize().disabled(draft.blocks.isEmpty)
            }
            if model.aiDraftIsStale { Text("原文或说话人已修改，这份整理稿基于之前的内容；可以生成新稿。").font(.caption).foregroundStyle(.orange) }
            if let error = draft.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if draft.chunks.count > 1 { Text("长录音分块整理，按原文顺序合并；跨块主题可能分开出现。").font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 26).padding(.bottom, 12)
    }
}

private struct AIBlockEditor: View {
    let block: AIBlock
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @UIState private var title = ""
    @UIState private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑整理段落").font(.headline)
            TextField("标题 / 说话人", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $text).font(.body).frame(minHeight: 260)
            HStack {
                Text("只修改整理稿，保留原文来源。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(title, text); dismiss() }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 680)
        .onAppear { title = block.title; text = block.text }
    }
}
