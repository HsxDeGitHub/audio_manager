import SwiftUI
import AppKit
import AudioCore

// macOS 27's SDK also exports a State macro that is unavailable in Command Line Tools.
// Use the established property wrapper through an alias, preserving macOS 14 compatibility.

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @UIState private var removeID: String?
    @UIState private var renaming: Recording?
    @UIState private var metadataRecording: Recording?
    @UIState private var nameDraft = ""
    @FocusState private var searchFocused: Bool
    @ObservedObject private var installer: ModelInstaller
    init(model: AppModel) { self.model = model; installer = model.installer }
    var body: some View {
        VStack(spacing: 0) {
            header
            if model.backendUnavailable {
                HStack { Text(model.backendState); Spacer(); Button("重试本地服务") { Task { await model.connectBackend() } } }
                    .font(.caption).padding(12).background(Color.orange.opacity(0.12))
            }
            if model.aiActiveDraftID != nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.aiProgressMessage.isEmpty ? "正在准备 AI 整理…" : model.aiProgressMessage).lineLimit(1)
                    Spacer()
                    Button("查看整理稿") {
                        Task {
                            if let id = model.aiActiveRecordingID { await model.select(id) }
                            if let run = model.aiWorkingDraft?.runID, model.selected?.activeRun != run { model.switchRun(run) }
                            model.selectedAIDraftID = model.aiActiveDraftID; model.readerShowsAI = true
                        }
                    }
                    Button("取消") { model.cancelAI() }
                }.font(.caption).padding(.horizontal, 24).padding(.vertical, 8)
            }
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 220, idealWidth: 248, maxWidth: 280)
                if !model.searchText.isEmpty {
                    searchResults.frame(minWidth: 240, idealWidth: 270, maxWidth: 330)
                }
                detail.frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                AssistantView(model: model, assistant: model.assistant).frame(minWidth: 300, idealWidth: 350, maxWidth: 500)
            }
        }
        .tint(accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showChangeHistory) { ChangeHistoryView(model: model.changeHistory, onChange: { model.reload() }) }
        .sheet(isPresented: $model.showAbout) { AboutView() }
        .sheet(isPresented: $model.showSettings) { ModelSettingsView(model: model, installer: model.installer) }
        .sheet(isPresented: $model.showAISettings) { AISettingsView(model: model) }
        .sheet(isPresented: $model.showAICompose) { AIComposeView(model: model) }
        .sheet(item: $renaming) { recording in
            VStack(alignment: .leading, spacing: 18) {
                Text("重命名音频").font(.headline)
                TextField("音频名称", text: $nameDraft).textFieldStyle(.roundedBorder)
                Text("只修改资料库中的名称。").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("取消") { renaming = nil }.keyboardShortcut(.cancelAction); Button("保存") { model.renameRecording(recording.id, name: nameDraft); renaming = nil }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 420)
        }
        .sheet(item: $metadataRecording) { recording in
            RecordingMetadataView(model: model, recording: recording)
        }
        .sheet(isPresented: $model.showMemories) {
            if let client = model.backendClient { MemoryView(app: model, client: client) }
            else { VStack(spacing: 12) { Text("本地服务尚未连接，无法读取长期记忆。"); Button("关闭") { model.showMemories = false } }.padding(24) }
        }
        .sheet(isPresented: $model.showDocuments) {
            if let client = model.backendClient { DocumentsView(app: model, client: client) }
            else { VStack(spacing: 12) { Text("本地服务尚未连接，无法读取个人材料。"); Button("关闭") { model.showDocuments = false } }.padding(24) }
        }
        .sheet(isPresented: $model.showToolSettings) {
            if let client = model.backendClient { ToolSettingsView(app: model, client: client) }
            else { VStack(spacing: 12) { Text("本地服务尚未连接，无法读取工具目录。"); Button("关闭") { model.showToolSettings = false } }.padding(24) }
        }
        .alert("提示", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("好", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
        .confirmationDialog("从资料库移除录音？", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } }), titleVisibility: .visible) {
            Button("移除记录", role: .destructive) { if let id = removeID { model.remove(id) }; removeID = nil }
        } message: { Text("仅移除转写和应用记录，原音频文件会保留。") }
        .onChange(of: model.searchText) { _, _ in model.refreshSearch() }
        .onChange(of: model.searchAll) { _, _ in model.refreshSearch() }
        .onChange(of: model.searchFocusRequestID) { _, _ in searchFocused = true }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                await model.importFiles(urls)
            }
            return true
        }
    }
    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 30)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("听阅").font(.system(size: 17, weight: .semibold))
                Text("让每段对话都能被找到").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索音频文字", text: $model.searchText).textFieldStyle(.plain)
                    .accessibilityLabel("搜索音频文字")
                    .focused($searchFocused).onExitCommand { model.searchText = ""; searchFocused = false }
                if !model.searchText.isEmpty { Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Picker("搜索范围", selection: $model.searchAll) {
                    Text("全部录音").tag(true)
                    Text("当前录音").tag(false)
                }.labelsHidden().frame(width: 105)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .frame(width: 380)
            Button { model.pickFiles() } label: { Label(model.importing ? "正在导入" : "导入音频", systemImage: "plus") }
                .buttonStyle(.borderedProminent).disabled(model.importing)
            Menu {
                Button("本地识别模型…") { model.showSettings = true }
                Button("大模型配置…") { model.showAISettings = true }
            } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize().help("模型设置").accessibilityLabel("模型设置")
        }.padding(.horizontal, 24).padding(.vertical, 15)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("音频资料库").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(); Text("\(model.recordings.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(18)
            VStack(spacing: 9) {
                TextField("筛选音频名称", text: $model.libraryTitleFilter).textFieldStyle(.roundedBorder)
                HStack(spacing: 6) {
                    Picker("排序", selection: Binding(get: { model.librarySort }, set: { model.setLibrarySort($0) })) {
                        ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden()
                    Picker("状态", selection: Binding(get: { model.libraryFilter }, set: { model.setLibraryFilter($0) })) {
                        ForEach(LibraryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }.font(.caption)
            }.padding(.horizontal, 14).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 6) {
                    if model.visibleRecordings.isEmpty {
                        Text(model.recordings.isEmpty ? "导入第一份音频" : "没有符合筛选条件的音频").font(.caption).foregroundStyle(.secondary).padding(20)
                        if !model.recordings.isEmpty { Button("清除筛选") { model.libraryTitleFilter = ""; model.setLibraryFilter(.all) }.font(.caption) }
                    }
                    ForEach(model.visibleRecordings) { recording in
                        Button { Task { await model.select(recording.id) } } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "waveform").font(.system(size: 16)).foregroundStyle(accent).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(recording.title).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: 6) {
                                        Text(TimeFormat.clock(recording.duration)).monospacedDigit()
                                        Text("·")
                                        Text(recording.state.title).foregroundStyle(recording.state == .failed ? .orange : .secondary)
                                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.selectedID == recording.id ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .contextMenu {
                                Button("重命名…") { nameDraft = recording.title; renaming = recording }
                                Button("资料信息…") { metadataRecording = recording }
                                Divider()
                                Button("转写 / 重试") { model.enqueue(recording.id) }
                                if recording.state.isRunning || recording.state == .queued { Button("取消任务") { model.cancel(recording.id) } }
                                Divider()
                                Button("从资料库移除…", role: .destructive) { removeID = recording.id }
                            }
                    }
                }.padding(.horizontal, 10)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Button("转写全部待处理录音") { model.enqueuePending() }.disabled(model.recordings.allSatisfy { $0.state != .idle })
                if let selected = model.selected {
                    Button("编辑「\(selected.title)」资料信息…") { metadataRecording = selected }.font(.caption)
                }
                Button("修改记录与撤销…") { model.showChangeHistory = true }.font(.caption)
                Button("长期记忆…") { model.showMemories = true }.font(.caption)
                HStack {
                    Label(model.ready ? "模型已就绪 · 可离线识别" : "模型准备中 / 尚未就绪", systemImage: model.ready ? "checkmark.shield" : "cpu").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if model.taskCount > 0 { Text("\(model.taskCount) 项后台任务 · \(model.phaseMessage)").font(.caption).foregroundStyle(.secondary) }
                Label("音频留在原位置", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
                if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(16)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
    }
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.activeHitIndex.map { "\($0 + 1) / \(model.hits.count) 个结果" } ?? "\(model.hits.count) 个匹配片段")
                    Spacer()
                    Button { model.navigateHit(-1) } label: { Image(systemName: "chevron.up") }.help("上一个结果 ⇧⌘G").disabled(model.hits.isEmpty)
                    Button { model.navigateHit(1) } label: { Image(systemName: "chevron.down") }.help("下一个结果 ⌘G").disabled(model.hits.isEmpty)
                }
                if model.hasSearchOrigin {
                    Button { Task { await model.returnFromSearch() } } label: { Label("返回搜索前的位置", systemImage: "arrow.uturn.backward") }
                }
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(15)
            if model.hits.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("没有找到相关内容").foregroundStyle(.secondary)
                    Text("搜索仅覆盖已转写的当前版本").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.hits) { hit in
                            Button { Task { await model.openHit(hit) } } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(hit.recordingTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    highlighted(hit.preview, term: model.searchText, matchRange: hit.previewHighlightRange).font(.system(size: 13)).lineLimit(4).multilineTextAlignment(.leading)
                                    Label("\(TimeFormat.clock(hit.segment.start)) · \(hit.speakerName)", systemImage: "play.circle").font(.caption).foregroundStyle(accent)
                                }.padding(15).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).background(model.activeHitID == hit.id ? accent.opacity(0.1) : .clear)
                                .id(hit.id)
                            Divider().padding(.horizontal, 15)
                        }
                    }
                }.onChange(of: model.activeHitID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
    private var detail: some View {
        Group {
            if let recording = model.selected {
                TranscriptView(model: model, player: model.player, recording: recording)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 58, weight: .light)).foregroundStyle(accent.opacity(0.7))
                    Text("导入音频，边读边听").font(.system(size: 23, weight: .medium))
                    Text("课程、会议、访谈和个人录音，都能在本机查阅。\n搜索文字，点击句子即可回听。").foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)
                    Button("选择音频文件…") { model.pickFiles() }.buttonStyle(.borderedProminent).controlSize(.large)
                    Label("离线识别 · 原文件只读", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private func highlighted(_ value: String, term: String, matchRange: NSRange? = nil) -> Text {
    if let matchRange, let range = Range(matchRange, in: value) {
        return Text(String(value[..<range.lowerBound])) + Text(String(value[range])).foregroundColor(accent).bold() + Text(String(value[range.upperBound...]))
    }
    var result = AttributedString(value)
    if !term.isEmpty, let range = result.range(of: term, options: [.caseInsensitive]) {
        result[range].foregroundColor = accent
        result[range].font = .system(size: 13, weight: .semibold)
    }
    return Text(result)
}

struct SpeakerNamesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("说话人名称").font(.headline)
            Text("仅应用于这份录音。可填写姓名、“主持人”“讲者”等名称。").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(Set(model.segments.compactMap(\.speaker))).sorted(), id: \.self) { speaker in
                SpeakerNameField(model: model, speaker: speaker)
            }
        }
    }
}
struct SpeakerNameField: View {
    @ObservedObject var model: AppModel
    let speaker: Int
    @UIState private var value = ""
    var body: some View {
        HStack {
            Text(SpeakerMatcher.defaultName(speaker)).font(.caption).frame(width: 65, alignment: .leading)
            TextField("名称", text: $value).textFieldStyle(.roundedBorder)
                .onSubmit { model.renameSpeaker(speaker, name: value) }
            Button("保存") { model.renameSpeaker(speaker, name: value) }
        }.onAppear { value = model.speakerName(speaker) }.onChange(of: model.names[speaker]) { _, _ in value = model.speakerName(speaker) }
    }
}

struct ModelSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var installer: ModelInstaller
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "cpu").font(.title).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("本地识别模型").font(.title2.weight(.semibold))
                    Text("首次下载约 3.2 GB，准备好后可离线使用。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ForEach(ModelSpec.all) { spec in
                HStack {
                    Image(systemName: installer.valid.contains(spec.id) ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(installer.valid.contains(spec.id) ? accent : .secondary)
                    Text(spec.title).font(.system(size: 13))
                    Spacer()
                    Button("导入文件…") { Task { await installer.importFile(spec: spec, directory: model.modelsDirectory) } }.disabled(installer.busy || model.activeJobID != nil)
                }
            }
            Divider()
            Text("模型目录").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.modelsDirectory.path).font(.caption).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("更换…") { Task { await model.chooseModelsDirectory() } }.disabled(installer.busy || model.activeJobID != nil)
            }
            if !installer.valid.contains(ModelSpec.punctuation.id), !installer.busy {
                Button("下载智能标点模型（可选）") { Task { await installer.download(directory: model.modelsDirectory, specs: [ModelSpec.punctuation]); model.refreshPunctuation() } }.disabled(model.activeJobID != nil)
            }
            if installer.busy {
                if let progress = installer.progress { ProgressView(value: progress); Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()) }
                else { ProgressView().controlSize(.small) }
            }
            Text(installer.message).font(.caption).foregroundStyle(.secondary)
            if let error = installer.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Label("本地识别不发送录音或文字；AI 整理使用单独配置的接口。", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            HStack {
                if installer.busy { Button("取消下载") { installer.cancel() } }
                else if !installer.ready {
                    Button("下载缺少的模型") { Task { await installer.download(directory: model.modelsDirectory) } }.buttonStyle(.borderedProminent).disabled(model.activeJobID != nil)
                }
                Spacer()
                Button(installer.ready ? "完成" : "稍后设置") { dismiss(); model.refreshPunctuation(); if installer.ready { model.enqueuePending() } }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 610)
    }
}

/// 资料类型与真实面试信息由用户直接填写；助手修改走同一 PATCH 业务接口和版本校验。
struct RecordingMetadataView: View {
    @ObservedObject var model: AppModel
    let recording: Recording
    @UIState private var kind = "unknown"
    @UIState private var dateText = ""
    @UIState private var company = ""
    @UIState private var role = ""
    @UIState private var revision = 1
    @UIState private var loading = true
    @UIState private var saving = false
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private var parsedDate: Date? { Self.dateFormatter.date(from: dateText) }
    private var dateValid: Bool {
        if dateText.isEmpty { return true }
        guard let parsed = parsedDate else { return false }
        return Self.dateFormatter.string(from: parsed) == dateText
    }
    private var kindTitle: String { ["unknown": "未分类", "interview": "面试", "other": "其他"][kind] ?? kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "info.circle").font(.title).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("资料信息").font(.title2.weight(.semibold))
                    Text(recording.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            Divider()
            HStack {
                Text("类型").frame(width: 90, alignment: .leading)
                Picker("类型", selection: $kind) {
                    Text("未分类").tag("unknown"); Text("面试").tag("interview"); Text("其他").tag("other")
                }.labelsHidden().frame(width: 150)
                Text("周报只纳入已分类且已知实际日期的面试。").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Text("实际面试日期").frame(width: 90, alignment: .leading)
                TextField("YYYY-MM-DD，留空表示未知", text: $dateText).textFieldStyle(.roundedBorder).frame(width: 190)
                Button("今天") { dateText = Self.dateFormatter.string(from: Date()) }.font(.caption)
                Button("清空") { dateText = "" }.font(.caption)
            }
            if !dateValid {
                Text("日期需为有效的 YYYY-MM-DD；导入时间不会被当作实际面试日期。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("公司").frame(width: 90, alignment: .leading)
                TextField("可选", text: $company).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("岗位").frame(width: 90, alignment: .leading)
                TextField("可选", text: $role).textFieldStyle(.roundedBorder)
            }
            if !loading {
                Text("当前类型：\(kindTitle) · 版本 \(revision)").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Text("资料正文不会被当成操作指令。").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(loading || saving || !dateValid)
            }
        }
        .padding(26).frame(width: 560)
        .task { await load() }
    }

    private func load() async {
        do {
            let value = try await model.recordingMetadata(recording.id)
            kind = value.kind
            dateText = value.interviewDate ?? ""
            company = value.company ?? ""
            role = value.role ?? ""
            revision = value.revision
            loading = false
        } catch {
            loading = false
            model.alert = error.localizedDescription
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        let companyText = company.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleText = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields: [String: Any] = [
            "kind": kind,
            "interview_date": dateText.isEmpty ? NSNull() : dateText,
            "company": companyText.isEmpty ? NSNull() : companyText,
            "role": roleText.isEmpty ? NSNull() : roleText
        ]
        do {
            try await model.updateRecordingMetadata(recording.id, fields: fields, revision: revision)
            dismiss()
        } catch {
            model.alert = error.localizedDescription
        }
    }
}
