import SwiftUI
import AppKit
import AudioCore

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerController
    let recording: Recording
    @UIState private var followPlayback = true
    @UIState private var showSpeakers = false
    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            if !model.segments.isEmpty {
                readerToolbar
                if model.selectionMode { BulkReviewBar(model: model) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if model.visibleUtterances.isEmpty {
                                Text(model.reviewFilter == .pending ? "没有待核对的句子" : "暂无符合条件的发言").foregroundStyle(.secondary).padding(40)
                            }
                            ForEach(model.visibleUtterances) { utterance in
                                SpeechBlock(model: model, player: player, utterance: utterance, followPlayback: followPlayback)
                                    .id(utterance.id)
                            }
                        }.frame(maxWidth: 900).padding(.horizontal, 30).padding(.vertical, 12).frame(maxWidth: .infinity)
                    }
                    .task(id: recording.id) {
                        // Let native paragraph heights settle before restoring a position in a lazy stack.
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !Task.isCancelled, model.selectedID == recording.id, model.focusSegmentID == nil else { return }
                        model.focusText(at: model.selected?.playPosition ?? 0)
                    }
                    .onChange(of: model.currentSegmentID) { previous, current in
                        let before = model.utteranceID(for: previous), after = model.utteranceID(for: current)
                        if followPlayback, player.playing, before != after, let after {
                            withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(after, anchor: .top) }
                        }
                    }
                    .onChange(of: model.focusRequestID) { _, _ in
                        if let id = model.utteranceID(for: model.focusSegmentID) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: recording.state.isRunning ? "waveform" : "text.alignleft").font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                    Text(recording.state.isRunning ? "正在整理文字，完成后自动显示" : "开始转写，就能边读边听").font(.headline).foregroundStyle(.secondary)
                    Text("后台处理时，可以继续查看其他音频。").font(.caption).foregroundStyle(.secondary)
                    if !recording.state.isRunning && recording.state != .queued {
                        Button("开始转写") { model.enqueue(recording.id) }.buttonStyle(.borderedProminent)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            PlayerBar(model: model, player: player)
        }.background(Color(nsColor: .textBackgroundColor).opacity(0.45))
    }
    private var titleBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(recording.title).font(.system(size: 20, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Label(TimeFormat.clock(recording.duration), systemImage: "clock")
                        if !model.utterances.isEmpty { Text("\(model.utterances.count) 次发言") }
                        Label(recording.state.title, systemImage: recording.state == .completed ? "checkmark.circle" : "circle.dotted")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Menu {
                    Button("导出纯对话 TXT（无时间范围）…") { model.export(srt: false, plainDialogue: true) }
                    Button("导出发言文字 TXT（带时间范围）…") { model.export(srt: false) }
                    Button("导出带时间轴的字幕 SRT…") { model.export(srt: true) }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize().disabled(model.segments.isEmpty)
                Menu {
                    Button("重新转写，保留已有版本") { model.enqueue(recording.id) }.disabled(recording.state.isRunning || recording.state == .queued)
                    Button("重新定位原音频…") { Task { await model.relocate() } }
                    if !model.segments.isEmpty { Button("复制全部文字") { model.copyText(model.exportText(srt: false)) } }
                    if model.runs.count > 1 {
                        Divider()
                        Picker("转写版本", selection: Binding(get: { recording.activeRun ?? "" }, set: { model.switchRun($0) })) {
                            ForEach(model.runs) { run in Text(runLabel(run)).tag(run.id) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("音频与版本操作")
            }
            if let error = recording.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.caption).lineLimit(4).textSelection(.enabled)
                    Spacer()
                    Button("重试") { model.enqueue(recording.id, speakersOnly: !model.segments.isEmpty) }
                }.padding(10).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.activeRecordingID == recording.id {
                HStack(spacing: 10) {
                    if let progress = model.progress { ProgressView(value: progress).frame(width: 120); Text("\(Int(progress * 100))%").monospacedDigit() }
                    else { ProgressView().controlSize(.small) }
                    Text(model.phaseMessage.isEmpty ? recording.state.title : model.phaseMessage).foregroundStyle(.secondary)
                    Spacer(); Button("取消") { model.cancel(recording.id) }
                }.font(.caption)
            } else if recording.state == .queued {
                HStack { Text("排队第 \(model.queuePosition(recording.id) ?? 1) 位").font(.caption).foregroundStyle(.secondary); Spacer(); Button("取消排队") { model.cancel(recording.id) } }
            }
        }.padding(.horizontal, 26).padding(.vertical, 20)
    }
    private var readerToolbar: some View {
        HStack(spacing: 14) {
            Button { showSpeakers.toggle() } label: { Label("说话人", systemImage: "person.2") }
                .popover(isPresented: $showSpeakers) { SpeakerSettingsView(model: model).padding(20).frame(width: 470) }
            Menu {
                Toggle("智能标点（本地）", isOn: Binding(get: { model.smartPunctuation }, set: { model.setSmartPunctuation($0) }))
                if !model.installer.valid.contains(ModelSpec.punctuation.id) { Button("准备智能标点模型…") { model.showSettings = true } }
                Toggle("自动补标点", isOn: Binding(get: { model.readingPunctuation }, set: { model.setReadingPunctuation($0) }))
                Toggle("长发言适当换行", isOn: Binding(get: { model.readingParagraphBreaks }, set: { model.setReadingParagraphBreaks($0) }))
                Picker("阅读密度", selection: Binding(get: { model.readingDensity }, set: { model.setReadingDensity($0) })) {
                    ForEach(ReadingDensity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Divider()
                ForEach([14.0,16,18,20,22], id: \.self) { size in
                    Button("\(Int(size)) 号" + (model.readerFontSize == size ? " ✓" : "")) { model.setReaderFontSize(size) }
                }
            } label: { Label("排版", systemImage: "textformat.size") }.menuStyle(.borderlessButton).fixedSize().help("标点、分段与字号")
            Picker("核对筛选", selection: $model.reviewFilter) {
                ForEach(ReviewFilter.allCases, id: \.self) { Text($0 == .pending ? "待核对 \(model.pendingReviewCount)" : $0.title).tag($0) }
            }.labelsHidden().frame(width: 112)
            Button { model.selectionMode.toggle(); if !model.selectionMode { model.bulkSelection = [] } } label: { Image(systemName: model.selectionMode ? "checkmark.circle.fill" : "checklist") }.help("批量选择发言")
            Menu {
                Button(model.undoLabel.map { "撤销：" + $0 } ?? "没有可撤销的修改") { model.undoEdit() }.disabled(model.undoLabel == nil)
                Button(model.redoLabel.map { "重做：" + $0 } ?? "没有可重做的修改") { model.undoEdit(redo: true) }.disabled(model.redoLabel == nil)
            } label: { Image(systemName: "arrow.uturn.backward") }.menuStyle(.borderlessButton).fixedSize().help("校对修改历史")
            if model.punctuationBusy { ProgressView().controlSize(.mini).help("正在本机优化阅读标点") }
            else if !model.punctuationMessage.isEmpty { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(model.punctuationMessage) }
            Spacer()
            Button { model.locateCurrentSentence() } label: { Image(systemName: "scope") }.help("定位当前播放句子 ⇧⌘L").disabled(model.currentSegmentID == nil)
            Toggle("跟随播放", isOn: $followPlayback).toggleStyle(.checkbox)
        }.font(.caption).padding(.horizontal, 26).padding(.vertical, 11)
    }
    private func runLabel(_ run: TranscriptRun) -> String {
        Date(timeIntervalSince1970: run.createdAt).formatted(date: .abbreviated, time: .shortened) + (run.hasEdits ? " · 已纠错" : "")
    }
}

struct SpeechBlock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerController
    let utterance: SpeechUtterance
    let followPlayback: Bool
    @UIState private var editingSentence: TranscriptSegment?
    @UIState private var editingUtterance = false
    private var speaking: Bool { player.playing && utterance.segments.contains { $0.id == model.currentSegmentID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if model.selectionMode {
                    Toggle("选择这次发言", isOn: Binding(get: { Set(utterance.segments.map(\.id)).isSubset(of: model.bulkSelection) }, set: { _ in model.toggleSelection(utterance) }))
                        .labelsHidden().toggleStyle(.checkbox)
                }
                Text(avatar).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                    .frame(width: 25, height: 25).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                speakerMenu
                Button { if let first = utterance.segments.first { model.playSegment(first) } } label: {
                    Text("\(TimeFormat.clock(utterance.start)) – \(TimeFormat.clock(utterance.end))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("回听这次发言")
                if speaking { Image(systemName: "waveform").font(.caption).foregroundStyle(accent).accessibilityLabel("正在播放这次发言") }
                Spacer()
                if utterance.hasEdits { Text("已校对").font(.system(size: 10)).foregroundStyle(.secondary) }
                if utterance.reviewCount > 0 { Text("\(utterance.reviewCount) 句待核对").font(.system(size: 10)).foregroundStyle(.orange) }
                Menu {
                    Button("标记整段已核对") { model.markReviewed(utterance.segments.map(\.id)) }
                    Button("重新标为待核对") { model.markReviewed(utterance.segments.map(\.id), reviewed: false) }
                    Divider()
                    Button("逐句校对这次发言…") { editingUtterance = true }
                    Button("复制这次发言") { model.copyText(model.readingText(utterance)) }
                    Button("从这次发言开始播放") { if let first = utterance.segments.first { model.playSegment(first) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("发言操作")
            }
            ParagraphTextView(segments: utterance.segments, fontSize: model.readerFontSize,
                              activeID: model.currentSegmentID, focusedID: model.focusSegmentID,
                              focusRequest: model.focusRequestID, searchTerm: model.searchText,
                              followPlayback: followPlayback, playing: player.playing,
                              punctuate: model.readingPunctuation, overrides: model.readingOverrides, density: model.readingDensity, paragraphBreaks: model.readingParagraphBreaks,
                              onPlay: { id in if let sentence = utterance.segments.first(where: { $0.id == id }) { model.playSegment(sentence) } },
                              onEdit: { id in editingSentence = utterance.segments.first(where: { $0.id == id }) })
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, 6).opacity(0.55)
        }.padding(.vertical, 12)
            .sheet(item: $editingSentence) { sentence in SentenceEditor(model: model, sentence: sentence) }
            .sheet(isPresented: $editingUtterance) { UtteranceEditor(model: model, utterance: utterance) }
    }
    private var avatar: String { utterance.speaker.map { $0 < 26 ? String(UnicodeScalar(65 + $0)!) : String($0 + 1) } ?? "·" }
    private var speakerMenu: some View {
        Menu {
            ForEach(Array(Set(model.segments.compactMap(\.speaker)).union(Set(model.names.keys))).sorted(), id: \.self) { speaker in
                Button(model.speakerName(speaker)) { model.editUtteranceSpeaker(utterance, speaker: speaker) }
            }
            Divider()
            Button("未识别") { model.editUtteranceSpeaker(utterance, speaker: nil) }
            Button("新增说话人") { model.editUtteranceSpeaker(utterance, speaker: (model.segments.compactMap(\.speaker).max() ?? -1) + 1) }
        } label: { Text(model.speakerName(utterance.speaker)).font(.system(size: 12, weight: .semibold)) }
        .menuStyle(.borderlessButton).fixedSize().help("调整整段发言的说话人")
    }
}

struct SentenceEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var player: PlayerController
    let sentence: TranscriptSegment
    init(model: AppModel, sentence: TranscriptSegment) { self.model = model; self.sentence = sentence; player = model.player }
    @Environment(\.dismiss) private var dismiss
    @UIState private var currentID = ""
    @UIState private var draft = ""
    @UIState private var initialDraft = ""
    @UIState private var looping = false
    @UIState private var markDone = true
    private var current: TranscriptSegment { model.segments.first { $0.id == currentID } ?? sentence }
    private var next: TranscriptSegment? {
        guard let index = model.segments.firstIndex(where: { $0.id == current.id }), index + 1 < model.segments.count else { return nil }
        return model.segments[index + 1]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("校对这句话").font(.headline); Spacer()
                Button("回听") { looping = false; model.playSegment(current) }.disabled(!model.player.available)
                Toggle("循环回听", isOn: $looping).toggleStyle(.checkbox).disabled(!model.player.available)
            }
            HStack {
                Text("\(TimeFormat.clock(current.start)) – \(TimeFormat.clock(current.end)) · \(model.speakerName(current.speaker))")
                Spacer()
                Text("回听位置 " + TimeFormat.clock(player.position)).monospacedDigit()
                Picker("校对倍速", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                    ForEach([Float(0.75),1,1.25,1.5,2], id: \.self) { Text(String(format: "%g×",$0)).tag($0) }
                }.labelsHidden().frame(width: 70)
            }.font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft).font(.system(size: 16)).frame(height: 170).padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Picker("说话人", selection: Binding(get: { current.speaker ?? -1 }, set: { model.editSpeaker(current.id, speaker: $0 < 0 ? nil : $0) })) {
                    Text("未识别").tag(-1)
                    ForEach(Array(Set(model.segments.compactMap(\.speaker))).sorted(), id: \.self) { Text(model.speakerName($0)).tag($0) }
                }.frame(width: 220)
                Spacer(); Toggle("保存时标记已核对", isOn: $markDone).toggleStyle(.checkbox)
            }
            DisclosureGroup("识别原稿") { Text(current.original).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("恢复原稿") { draft = current.original }; Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并下一句") { save(); if let next { load(next); if looping { startLoop() } } }.disabled(next == nil)
                Button("保存") { save(); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 660)
            .onAppear { load(sentence) }
            .onChange(of: looping) { _, enabled in if enabled { startLoop() } else { model.player.stopLoop() } }
            .onDisappear { if looping { model.player.stopLoop(); model.player.pause() } }
    }
    private func load(_ segment: TranscriptSegment) {
        currentID = segment.id; initialDraft = model.readingSentence(segment); draft = initialDraft
        model.focusSegmentID = segment.id; model.focusRequestID = UUID()
    }
    private func startLoop() { model.player.startLoop(start: max(0,current.start - model.preRoll), end: current.end) }
    private func save() {
        model.saveCorrection(current.id, text: draft != initialDraft ? draft : nil, reviewed: markDone)
    }
}

struct UtteranceEditor: View {
    @ObservedObject var model: AppModel
    let utterance: SpeechUtterance
    @Environment(\.dismiss) private var dismiss
    @UIState private var drafts: [String: String] = [:]
    @UIState private var initialDrafts: [String: String] = [:]
    @UIState private var loopID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("逐句校对这次发言").font(.headline)
            Text("修改文字会自动更新搜索，句子的回听位置保持不变。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(utterance.segments) { sentence in
                        HStack(alignment: .top, spacing: 12) {
                            Button(TimeFormat.clock(sentence.start)) { model.playSegment(sentence) }.font(.caption.monospacedDigit()).buttonStyle(.plain).foregroundStyle(accent).frame(width: 65)
                            Button { if loopID == sentence.id { model.player.stopLoop(); model.player.pause(); loopID = nil } else { loopID = sentence.id; model.player.startLoop(start: max(0,sentence.start - model.preRoll), end: sentence.end) } } label: { Image(systemName: loopID == sentence.id ? "stop.circle" : "repeat") }.buttonStyle(.plain).help("循环回听这句").disabled(!model.player.available)
                            TextEditor(text: Binding(get: { drafts[sentence.id] ?? model.readingSentence(sentence) }, set: { drafts[sentence.id] = $0 }))
                                .font(.system(size: 15)).frame(height: max(54, CGFloat(sentence.text.count / 35 + 1) * 23)).padding(6)
                        }
                    }
                }
            }.frame(height: 380)
            HStack {
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存全部") {
                    let changed = drafts.filter { id, text in initialDrafts[id] != text }
                    model.editTexts(changed); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 650).onAppear {
            initialDrafts = Dictionary(uniqueKeysWithValues: utterance.segments.map { ($0.id, model.readingSentence($0)) })
            drafts = initialDrafts
        }.onDisappear { if loopID != nil { model.player.stopLoop(); model.player.pause() } }
    }
}

struct BulkReviewBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Text("已选择 \(model.bulkSelection.count) 句").font(.caption.monospacedDigit())
            Button("选择当前结果") { model.bulkSelection = Set(model.visibleUtterances.flatMap { $0.segments.map(\.id) }) }
            Button("清空") { model.bulkSelection = [] }
            Spacer()
            Menu("修改说话人") {
                ForEach(Array(Set(model.segments.compactMap(\.speaker))).sorted(), id: \.self) { speaker in
                    Button(model.speakerName(speaker)) { model.setBulkSpeaker(speaker) }
                }
                Button("未识别") { model.setBulkSpeaker(nil) }
            }.menuStyle(.borderlessButton).fixedSize().disabled(model.bulkSelection.isEmpty)
            Button("标记已核对") { model.markReviewed(Array(model.bulkSelection)); model.bulkSelection = [] }.disabled(model.bulkSelection.isEmpty)
        }.font(.caption).padding(.horizontal, 26).padding(.vertical, 10).background(accent.opacity(0.07))
    }
}

struct SpeakerSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @UIState private var sources: Set<Int> = []
    @UIState private var target = -1
    private var speakers: [Int] { Array(Set(model.segments.compactMap(\.speaker))).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("说话人整理").font(.headline); Spacer(); Button("完成") { dismiss() } }
            Text("试听会播放最多 8 秒；再次点击切换样本。勾选重复标签后，可合并到同一个人。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(speakers, id: \.self) { speaker in
                        HStack(spacing: 8) {
                            Toggle("选择 " + model.speakerName(speaker), isOn: Binding(get: { sources.contains(speaker) }, set: { if $0 { sources.insert(speaker) } else { sources.remove(speaker) } })).labelsHidden().toggleStyle(.checkbox)
                            SpeakerNameField(model: model, speaker: speaker)
                            Button { model.previewSpeaker(speaker) } label: { Image(systemName: "play.circle") }.help("试听 " + model.speakerName(speaker)).disabled(!model.player.available)
                        }
                    }
                }.padding(.vertical, 3)
            }.frame(maxHeight: 270)
            HStack {
                Picker("合并到", selection: $target) {
                    Text("选择目标说话人").tag(-1)
                    ForEach(speakers, id: \.self) { Text(model.speakerName($0)).tag($0) }
                }
                Button("合并所选") { model.mergeSpeakers(sources, into: target); sources = [] }
                    .disabled(target < 0 || sources.subtracting([target]).isEmpty)
            }
            Text("合并仅改变归属，文字与时间轴保持原样。可撤销。名称按目标说话人保留。").font(.caption2).foregroundStyle(.secondary)
            Divider()
            if let recording = model.selected {
                Picker("实际人数", selection: Binding(get: { recording.speakerCount ?? 0 }, set: { model.changeSpeakerCount($0 == 0 ? nil : $0) })) {
                    Text("自动判断").tag(0)
                    ForEach(1...12, id: \.self) { Text("\($0) 人").tag($0) }
                }.disabled(recording.state.isRunning || recording.state == .queued)
                Button("重新区分说话人") { model.enqueue(recording.id, speakersOnly: true) }.disabled(recording.state.isRunning || recording.state == .queued)
                Text("重新区分会保留人工归属与名称，并重新开始修改历史。").font(.caption2).foregroundStyle(.secondary)
            }
        }.onChange(of: model.selectedID) { _, _ in sources = []; target = -1 }
        .onChange(of: speakers) { _, ids in
            sources.formIntersection(Set(ids)); if !ids.contains(target) { target = -1 }
        }
    }
}

struct PlayerBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerController
    @UIState private var scrubbing = false
    @UIState private var scrubPosition: Double = 0
    var body: some View {
        VStack(spacing: 12) {
            if let error = player.error {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2); Spacer(); Button("重新定位文件…") { Task { await model.relocate() } } }
                    if let path = model.selected?.path { Text("原路径：" + path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            if let loop = player.loop {
                HStack { Label("循环回听 \(TimeFormat.clock(loop.start)) – \(TimeFormat.clock(loop.end))", systemImage: "repeat"); Spacer(); Button("结束循环") { player.stopLoop() } }.font(.caption).foregroundStyle(accent)
            }
            HStack(spacing: 14) {
                Button { player.seek(player.position - 10) } label: { Image(systemName: "gobackward.10").font(.system(size: 19)) }.buttonStyle(.plain).help("后退 10 秒 ⌘←")
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 15)).foregroundStyle(Color(nsColor: .textBackgroundColor))
                        .frame(width: 38, height: 38).background(accent, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel(player.playing ? "暂停" : "播放")
                Button { player.seek(player.position + 10) } label: { Image(systemName: "goforward.10").font(.system(size: 19)) }.buttonStyle(.plain).help("前进 10 秒 ⌘→")
                Text(TimeFormat.clock(scrubbing ? scrubPosition : player.position)).font(.caption.monospacedDigit()).frame(width: 60)
                Slider(value: Binding(get: { scrubbing ? scrubPosition : min(player.position, max(1, player.duration)) }, set: {
                    scrubPosition = $0; if !scrubbing { player.seek($0) }
                }), in: 0...max(1, player.duration), onEditingChanged: { editing in
                    if editing { scrubPosition = player.position; scrubbing = true }
                    else { player.seek(scrubPosition); scrubbing = false }
                }).accessibilityLabel("音频播放进度")
                Text(TimeFormat.clock(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60)
                Picker("倍速", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                    ForEach([Float(0.75),1,1.25,1.5,1.75,2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }.labelsHidden().frame(width: 68)
                Menu {
                    Text("点击句子时，提前播放")
                    ForEach([0.0,0.5,1,2], id: \.self) { amount in
                        Button(String(format: "%g 秒", amount) + (model.preRoll == amount ? " ✓" : "")) { model.setPreRoll(amount) }
                    }
                } label: { Image(systemName: "slider.horizontal.3") }.menuStyle(.borderlessButton).fixedSize().help("回听设置")
            }.disabled(!player.available)
        }.padding(.horizontal, 24).padding(.vertical, 15).background(Color(nsColor: .windowBackgroundColor))
    }
}
