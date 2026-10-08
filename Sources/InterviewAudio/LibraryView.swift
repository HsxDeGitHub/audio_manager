import SwiftUI
import AppKit
import AudioCore

// macOS 27's SDK also exports a State macro that is unavailable in Command Line Tools.
// Use the established property wrapper through an alias, preserving macOS 14 compatibility.

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @UIState private var removeID: String?
    @UIState private var renaming: Recording?
    @UIState private var nameDraft = ""
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 220, idealWidth: 248, maxWidth: 280)
                if !model.searchText.isEmpty {
                    searchResults.frame(minWidth: 240, idealWidth: 270, maxWidth: 330)
                }
                detail.frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showSettings) { ModelSettingsView(model: model, installer: model.installer) }
        .sheet(item: $renaming) { recording in
            VStack(alignment: .leading, spacing: 18) {
                Text("重命名音频").font(.headline)
                TextField("音频名称", text: $nameDraft).textFieldStyle(.roundedBorder)
                Text("只修改资料库中的名称。").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("取消") { renaming = nil }.keyboardShortcut(.cancelAction); Button("保存") { model.renameRecording(recording.id, name: nameDraft); renaming = nil }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 420)
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
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("模型设置").accessibilityLabel("模型设置")
        }.padding(.horizontal, 24).padding(.vertical, 15)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("音频资料库").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(); Text("\(model.recordings.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(18)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.recordings) { recording in
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
                Label("音频留在原位置", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
                if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(16)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
    }
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(model.hits.count) 个匹配片段").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(18)
            if model.hits.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("没有找到相关内容").foregroundStyle(.secondary)
                    Text("搜索仅覆盖已转写的当前版本").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.hits) { hit in
                            Button { Task { await model.openHit(hit) } } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(hit.recordingTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    highlighted(hit.preview, term: model.searchText, matchRange: hit.previewHighlightRange).font(.system(size: 13)).lineLimit(4).multilineTextAlignment(.leading)
                                    Label("\(TimeFormat.clock(hit.segment.start)) · \(hit.speakerName)", systemImage: "play.circle").font(.caption).foregroundStyle(accent)
                                }.padding(15).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider().padding(.horizontal, 15)
                        }
                    }
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
        }.onAppear { value = model.speakerName(speaker) }
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
            if installer.busy {
                if let progress = installer.progress { ProgressView(value: progress); Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()) }
                else { ProgressView().controlSize(.small) }
            }
            Text(installer.message).font(.caption).foregroundStyle(.secondary)
            if let error = installer.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Label("录音和文字保存在本机。仅下载模型时连接网络。", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            HStack {
                if installer.busy { Button("取消下载") { installer.cancel() } }
                else if !installer.ready {
                    Button("下载缺少的模型") { Task { await installer.download(directory: model.modelsDirectory) } }.buttonStyle(.borderedProminent).disabled(model.activeJobID != nil)
                }
                Spacer()
                Button(installer.ready ? "完成" : "稍后设置") { dismiss(); if installer.ready { model.enqueuePending() } }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 610)
    }
}
