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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.utterances) { utterance in
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
                    Button("导出发言文字 TXT…") { model.export(srt: false) }
                    Button("导出带时间轴的字幕 SRT…") { model.export(srt: true) }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize().disabled(model.segments.isEmpty)
                Menu {
                    Button("重新转写，保留已有版本") { model.enqueue(recording.id) }.disabled(recording.state.isRunning || recording.state == .queued)
                    Button("重新定位原音频…") { Task { await model.relocate() } }
                    if !model.segments.isEmpty { Button("复制全部文字") { model.copyText(TranscriptExport.render(title: recording.title, segments: model.segments, names: model.names, srt: false)) } }
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
                    Text(recording.state == .diarizing ? "正在整理说话人，文字已可阅读" : "正在本机转写文字").foregroundStyle(.secondary)
                    Spacer(); Button("取消") { model.cancel(recording.id) }
                }.font(.caption)
            } else if recording.state == .queued {
                HStack { Text("已加入处理队列").font(.caption).foregroundStyle(.secondary); Spacer(); Button("取消排队") { model.cancel(recording.id) } }
            }
        }.padding(.horizontal, 26).padding(.vertical, 20)
    }
    private var readerToolbar: some View {
        HStack(spacing: 14) {
            Button { showSpeakers.toggle() } label: { Label("说话人", systemImage: "person.2") }
                .popover(isPresented: $showSpeakers) { SpeakerSettingsView(model: model).padding(20).frame(width: 340) }
            Menu {
                ForEach([14.0,16,18,20,22], id: \.self) { size in
                    Button("\(Int(size)) 号" + (model.readerFontSize == size ? " ✓" : "")) { model.setReaderFontSize(size) }
                }
            } label: { Label("字号", systemImage: "textformat.size") }.menuStyle(.borderlessButton).fixedSize()
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
                    Button("逐句校对这次发言…") { editingUtterance = true }
                    Button("复制这次发言") { model.copyText(utterance.text) }
                    Button("从这次发言开始播放") { if let first = utterance.segments.first { model.playSegment(first) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("发言操作")
            }
            ParagraphTextView(segments: utterance.segments, fontSize: model.readerFontSize,
                              activeID: model.currentSegmentID, focusedID: model.focusSegmentID,
                              focusRequest: model.focusRequestID, searchTerm: model.searchText,
                              followPlayback: followPlayback, playing: player.playing,
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
    let sentence: TranscriptSegment
    @Environment(\.dismiss) private var dismiss
    @UIState private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("校对这句话").font(.headline); Spacer(); Button("回听") { model.playSegment(sentence) } }
            Text("\(TimeFormat.clock(sentence.start)) – \(TimeFormat.clock(sentence.end)) · 保存后仍可定位回听").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft).font(.system(size: 16)).frame(height: 170).padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            DisclosureGroup("识别原稿") { Text(sentence.original).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack { Button("恢复原稿") { draft = sentence.original }; Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存") { if draft != sentence.text { model.editText(sentence.id, text: draft) }; dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 550).onAppear { draft = sentence.text }
    }
}

struct UtteranceEditor: View {
    @ObservedObject var model: AppModel
    let utterance: SpeechUtterance
    @Environment(\.dismiss) private var dismiss
    @UIState private var drafts: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("逐句校对这次发言").font(.headline)
            Text("修改文字会自动更新搜索，句子的回听位置保持不变。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(utterance.segments) { sentence in
                        HStack(alignment: .top, spacing: 12) {
                            Button(TimeFormat.clock(sentence.start)) { model.playSegment(sentence) }.font(.caption.monospacedDigit()).buttonStyle(.plain).foregroundStyle(accent).frame(width: 65)
                            TextEditor(text: Binding(get: { drafts[sentence.id] ?? sentence.text }, set: { drafts[sentence.id] = $0 }))
                                .font(.system(size: 15)).frame(height: max(54, CGFloat(sentence.text.count / 35 + 1) * 23)).padding(6)
                        }
                    }
                }
            }.frame(height: 380)
            HStack {
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存全部") {
                    let changed = drafts.filter { id, text in utterance.segments.first(where: { $0.id == id })?.text != text }
                    model.editTexts(changed); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 650)
    }
}

struct SpeakerSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("说话人与名称").font(.headline)
            Text("名称仅用于当前音频。也可以点发言段落上的名称，纠正整段归属。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(Set(model.segments.compactMap(\.speaker))).sorted(), id: \.self) { speaker in SpeakerNameField(model: model, speaker: speaker) }
                }.padding(.vertical, 3)
            }.frame(maxHeight: 270)
            Divider()
            if let recording = model.selected {
                Picker("实际人数", selection: Binding(get: { recording.speakerCount ?? 0 }, set: { model.changeSpeakerCount($0 == 0 ? nil : $0) })) {
                    Text("自动判断").tag(0)
                    ForEach(1...12, id: \.self) { Text("\($0) 人").tag($0) }
                }.disabled(recording.state.isRunning || recording.state == .queued)
                Text("已知人数时，指定人数后重新区分通常更稳定。").font(.caption).foregroundStyle(.secondary)
                Button("重新区分说话人") { model.enqueue(recording.id, speakersOnly: true) }.disabled(recording.state.isRunning || recording.state == .queued)
            }
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
                HStack { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2); Spacer(); Button("重新定位文件…") { Task { await model.relocate() } } }
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
