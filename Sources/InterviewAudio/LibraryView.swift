import SwiftUI
import AppKit
import AudioCore

private let accent = Color(red: 0.12, green: 0.43, blue: 0.40)
// macOS 27's SDK also exports a State macro that is unavailable in Command Line Tools.
// Use the established property wrapper through an alias, preserving macOS 14 compatibility.
private typealias UIState<Value> = SwiftUI.State<Value>

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @UIState private var removeID: String?
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                if !model.searchText.isEmpty {
                    searchResults.frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
                }
                detail.frame(minWidth: 490, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showSettings) { ModelSettingsView(model: model, installer: model.installer) }
        .alert("提示", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("好", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
        .confirmationDialog("从资料库移除录音？", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } }), titleVisibility: .visible) {
            Button("移除记录", role: .destructive) { if let id = removeID { model.remove(id) }; removeID = nil }
        } message: { Text("仅移除转写和应用记录，原音频文件会保留。") }
        .onChange(of: model.searchText) { _, _ in model.refreshSearch() }
        .onChange(of: model.searchAll) { _, _ in model.refreshSearch() }
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
                Text("面试音频").font(.system(size: 17, weight: .semibold))
                Text("让每段对话都能被找到").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索面试内容", text: $model.searchText).textFieldStyle(.plain)
                    .accessibilityLabel("搜索面试内容")
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
                Text("录音资料库").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
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
                                    highlighted(hit.segment.text, term: model.searchText).font(.system(size: 13)).lineLimit(4).multilineTextAlignment(.leading)
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
                    Text("把面试录音变成可查阅的文字").font(.system(size: 23, weight: .medium))
                    Text("导入录音，本地转写。搜索关键词，点击文字回听。\n支持 MP3、M4A、WAV 和 FLAC。").foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)
                    Button("选择音频文件…") { model.pickFiles() }.buttonStyle(.borderedProminent).controlSize(.large)
                    Label("离线识别 · 原文件只读", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private func highlighted(_ value: String, term: String) -> Text {
    var result = AttributedString(value)
    if !term.isEmpty, let range = result.range(of: term, options: [.caseInsensitive]) {
        result[range].foregroundColor = accent
        result[range].font = .system(size: 13, weight: .semibold)
    }
    return Text(result)
}

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerController
    let recording: Recording
    @UIState private var followPlayback = true
    @UIState private var showSpeakers = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recording.title).font(.system(size: 20, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                        HStack(spacing: 10) {
                            Text(TimeFormat.clock(recording.duration))
                            Text("\(model.segments.count) 个片段")
                            Label(recording.state.title, systemImage: recording.state == .completed ? "checkmark.circle" : "circle.dotted")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("导出文字 TXT…") { model.export(srt: false) }
                        Button("导出字幕 SRT…") { model.export(srt: true) }
                    } label: { Label("导出", systemImage: "square.and.arrow.up") }.disabled(model.segments.isEmpty)
                }
                HStack(spacing: 12) {
                    Picker("说话人数", selection: Binding(get: { recording.speakerCount ?? 0 }, set: { model.changeSpeakerCount($0 == 0 ? nil : $0) })) {
                        Text("自动判断").tag(0)
                        ForEach(1...12, id: \.self) { Text("\($0) 人").tag($0) }
                    }.frame(width: 175).disabled(recording.state.isRunning || recording.state == .queued)
                    Button(model.segments.isEmpty ? "开始转写" : "重新转写") { model.enqueue(recording.id) }
                        .disabled(recording.state.isRunning || recording.state == .queued)
                    if !model.segments.isEmpty {
                        Button("重试说话人区分") { model.enqueue(recording.id, speakersOnly: true) }.disabled(recording.state.isRunning || recording.state == .queued)
                    }
                    Spacer()
                    if recording.state.isRunning || recording.state == .queued { Button("取消") { model.cancel(recording.id) } }
                }.font(.caption)
                if let error = recording.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(4).textSelection(.enabled) }
                if model.activeRecordingID == recording.id {
                    HStack(spacing: 10) {
                        if let progress = model.progress { ProgressView(value: progress).frame(width: 140); Text("\(Int(progress * 100))%").monospacedDigit() }
                        else { ProgressView().controlSize(.small) }
                        Text(model.phaseMessage).foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }.padding(24)
            Divider()
            if !model.segments.isEmpty {
                HStack {
                    Button { showSpeakers.toggle() } label: { Label("说话人名称", systemImage: "person.2") }
                        .popover(isPresented: $showSpeakers) { SpeakerNamesView(model: model).padding(20).frame(width: 300) }
                    if model.runs.count > 1 {
                        Picker("版本", selection: Binding(get: { recording.activeRun ?? "" }, set: { model.switchRun($0) })) {
                            ForEach(model.runs) { run in Text(runLabel(run)).tag(run.id) }
                        }.frame(maxWidth: 260)
                    }
                    Spacer()
                    Toggle("跟随播放", isOn: $followPlayback).toggleStyle(.checkbox)
                }.font(.caption).padding(.horizontal, 24).padding(.vertical, 12)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.segments) { segment in
                                SegmentRow(model: model, segment: segment, active: model.currentSegmentID == segment.id)
                                    .id(segment.id)
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 12)
                    }
                    .onChange(of: model.currentSegmentID) { _, id in
                        if followPlayback, player.playing, let id { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onChange(of: model.focusRequestID) { _, _ in
                        if let id = model.focusSegmentID { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: recording.state.isRunning ? "waveform" : "text.alignleft").font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                    Text(recording.state.isRunning ? "正在生成文字，完成后会自动显示" : "这份录音还没有转写文字").foregroundStyle(.secondary)
                    Text("识别在本机后台运行，完成的结果会自动保存。").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            PlayerBar(model: model, player: player)
        }
    }
    private func runLabel(_ run: TranscriptRun) -> String {
        let date = Date(timeIntervalSince1970: run.createdAt).formatted(date: .abbreviated, time: .shortened)
        return date + (run.hasEdits ? " · 已纠错" : "")
    }
}

struct SegmentRow: View {
    @ObservedObject var model: AppModel
    let segment: TranscriptSegment
    let active: Bool
    @UIState private var editing = false
    @UIState private var draft = ""
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button { model.playSegment(segment) } label: {
                VStack(spacing: 6) {
                    Image(systemName: active ? "waveform" : "play.circle").font(.system(size: 19))
                    Text(TimeFormat.clock(segment.start)).font(.system(size: 11, design: .monospaced))
                }.foregroundStyle(active ? accent : .secondary).frame(width: 58).padding(.top, 4)
            }.buttonStyle(.plain).help("从此片段前一秒播放")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(Array(Set(model.segments.compactMap(\.speaker)).union(Set(model.names.keys))).sorted(), id: \.self) { speaker in
                            Button(model.speakerName(speaker)) { model.editSpeaker(segment.id, speaker: speaker) }
                        }
                        Divider()
                        Button("未识别") { model.editSpeaker(segment.id, speaker: nil) }
                        Button("新增说话人") {
                            let next = (model.segments.compactMap(\.speaker).max() ?? -1) + 1
                            model.editSpeaker(segment.id, speaker: next)
                        }
                    } label: { Text(model.speakerName(segment.speaker)).font(.system(size: 12, weight: .semibold)) }
                    .menuStyle(.borderlessButton).fixedSize()
                    if segment.needsReview { Label("待核对", systemImage: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.orange).help("此片段跨越说话人边界或未检测到说话人，请回听核对。") }
                    if segment.manuallyEdited { Text("已纠错").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    Spacer()
                    Button {
                        draft = segment.text; editing = true
                    } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(.secondary).help("修改识别文字")
                }
                Text(segment.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { model.playSegment(segment) }
            }
        }
        .padding(14)
        .background(active ? accent.opacity(0.09) : Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? accent.opacity(0.25) : .clear, lineWidth: 1))
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("修改识别文字").font(.headline)
                Text("\(TimeFormat.clock(segment.start)) – \(TimeFormat.clock(segment.end)) · 时间位置保持不变").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft).font(.body).frame(height: 180).padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                DisclosureGroup("查看识别原稿") { Text(segment.original).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack { Spacer(); Button("取消") { editing = false }.keyboardShortcut(.cancelAction); Button("保存") { model.editText(segment.id, text: draft); editing = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 540)
        }
    }
}

struct SpeakerNamesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("说话人名称").font(.headline)
            Text("仅应用于这份录音。可填写“面试官”“候选人”或姓名。").font(.caption).foregroundStyle(.secondary)
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

struct PlayerBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerController
    var body: some View {
        VStack(spacing: 12) {
            if let error = player.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    Spacer(); Button("重新定位文件…") { Task { await model.relocate() } }
                }
            }
            HStack(spacing: 12) {
                Text(TimeFormat.clock(player.position)).font(.caption.monospacedDigit()).frame(width: 60)
                Slider(value: Binding(get: { min(player.position, max(1, player.duration)) }, set: { player.seek($0) }), in: 0...max(1, player.duration))
                    .disabled(!player.available).accessibilityLabel("音频播放进度")
                Text(TimeFormat.clock(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60)
            }
            HStack(spacing: 24) {
                Spacer()
                Button { player.seek(player.position - 10) } label: { Image(systemName: "gobackward.10").font(.title2) }.buttonStyle(.plain).help("后退 10 秒")
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 17)).foregroundStyle(.white).frame(width: 44, height: 44).background(accent, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel(player.playing ? "暂停" : "播放")
                Button { player.seek(player.position + 10) } label: { Image(systemName: "goforward.10").font(.title2) }.buttonStyle(.plain).help("前进 10 秒")
                Spacer()
                Picker("倍速", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                    ForEach([Float(0.75),1,1.25,1.5,1.75,2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }.frame(width: 100)
            }.disabled(!player.available)
        }.padding(.horizontal, 24).padding(.vertical, 18)
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
