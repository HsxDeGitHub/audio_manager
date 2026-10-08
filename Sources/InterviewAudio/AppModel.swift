import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import AudioCore

private struct QueuedJob { var recordingID: String; var speakersOnly: Bool }

@MainActor
final class AppModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var selectedID: String?
    @Published var segments: [TranscriptSegment] = []
    @Published var utterances: [SpeechUtterance] = []
    @Published var names: [Int: String] = [:]
    @Published var runs: [TranscriptRun] = []
    @Published var searchText = ""
    @Published var searchAll = true
    @Published var hits: [SearchHit] = []
    @Published var showSettings = false
    @Published var alert: String?
    @Published var notice = ""
    @Published var importing = false
    @Published var activeJobID: String?
    @Published var activeRecordingID: String?
    @Published var progress: Double?
    @Published var phaseMessage = ""
    @Published var modelsDirectory: URL
    @Published var focusSegmentID: String?
    @Published var focusRequestID = UUID()
    @Published var searchFocusRequestID = UUID()
    @Published var readerFontSize: Double = 16
    @Published var preRoll: Double = 1
    @Published var readingPunctuation = true
    @Published var readingParagraphBreaks = true
    let installer = ModelInstaller()
    let player = PlayerController()
    let dataDirectory: URL
    let toolsDirectory: URL
    private var store: LibraryStore?
    private var queue: [QueuedJob] = []
    private var worker: Process?
    private var request: WorkerRequest?
    private var logHandle: FileHandle?
    private var cancelledJob = false
    private var lastSavedPosition = Date.distantPast
    private var searchTask: Task<Void, Never>?
    private var segmentToUtterance: [String: String] = [:]
    private var lastRecordingID: String?
    private var prepared = false
    var selected: Recording? { recordings.first { $0.id == selectedID } }
    var ready: Bool { installer.ready }
    var taskCount: Int { queue.count + (worker == nil ? 0 : 1) }
    var currentSegmentID: String? { player.available ? segments.first { $0.start <= player.position && player.position < $0.end }?.id : nil }
    func utteranceID(for segmentID: String?) -> String? { segmentID.flatMap { segmentToUtterance[$0] } }

    init() {
        let override = ProcessInfo.processInfo.environment["INTERVIEW_AUDIO_DATA_DIR"]
        dataDirectory = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InterviewAudio", isDirectory: true)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = Bundle.main.resourceURL ?? cwd
        let packagedTools = resources.appendingPathComponent("Tools", isDirectory: true)
        toolsDirectory = FileManager.default.fileExists(atPath: packagedTools.appendingPathComponent("whisper-cli").path)
            ? packagedTools : cwd.appendingPathComponent(".runtime/tools", isDirectory: true)
        let adjacent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Models", isDirectory: true)
        let developmentModels = cwd.appendingPathComponent("Models", isDirectory: true)
        let defaultModels = FileManager.default.fileExists(atPath: adjacent.appendingPathComponent("ggml-large-v3.bin").path) ? adjacent
            : FileManager.default.fileExists(atPath: developmentModels.appendingPathComponent("ggml-large-v3.bin").path) ? developmentModels
            : dataDirectory.appendingPathComponent("Models", isDirectory: true)
        let preferences = try? JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: dataDirectory.appendingPathComponent("settings.json")))
        modelsDirectory = preferences.map { URL(fileURLWithPath: $0.modelsDirectory, isDirectory: true) } ?? defaultModels
        readerFontSize = min(22, max(14, preferences?.readerFontSize ?? 16))
        preRoll = min(2, max(0, preferences?.preRoll ?? 1))
        lastRecordingID = preferences?.lastRecordingID
        readingPunctuation = preferences?.readingPunctuation ?? true
        readingParagraphBreaks = preferences?.readingParagraphBreaks ?? true
        do {
            store = try LibraryStore(url: dataDirectory.appendingPathComponent("library.sqlite"))
            reload()
        } catch { alert = "资料库初始化失败：\(error.localizedDescription)" }
        player.onPosition = { [weak self] position in
            guard let self, Date().timeIntervalSince(self.lastSavedPosition) > 3 else { return }
            self.savePosition(position)
        }
    }

    func prepare() async {
        guard !prepared else { return }; prepared = true
        async let validation: Void = installer.validate(directory: modelsDirectory)
        let restored = recordings.first(where: { $0.id == lastRecordingID }) ?? recordings.first
        if let restored { await select(restored.id) }
        await validation
        if !installer.ready { showSettings = true }
    }
    func reload() {
        do {
            recordings = try store?.recordings() ?? []
            loadTranscript()
            refreshSearch()
        } catch { alert = error.localizedDescription }
    }
    private func loadTranscript() {
        do {
            runs = try selectedID.map { try store?.runs(recordingID: $0) ?? [] } ?? []
            if let run = selected?.activeRun {
                segments = try store?.segments(runID: run) ?? []
                names = try store?.speakerNames(runID: run) ?? [:]
            } else { segments = []; names = [:] }
            utterances = UtteranceGrouping.make(segments)
            segmentToUtterance = Dictionary(uniqueKeysWithValues: utterances.flatMap { utterance in
                utterance.segments.map { ($0.id, utterance.id) }
            })
        } catch { alert = error.localizedDescription }
    }
    func savePosition(_ value: Double? = nil) {
        guard player.available, var recording = selected else { return }
        recording.playPosition = min(max(0, value ?? player.position), max(recording.duration, player.duration))
        do {
            try store?.save(recording)
            if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index] = recording }
            lastSavedPosition = Date()
        } catch { alert = error.localizedDescription }
    }
    private func save(_ recording: Recording) {
        do { try store?.save(recording); reload() } catch { alert = error.localizedDescription }
    }
    func resolve(_ recording: Recording) -> URL {
        if let bookmark = recording.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: recording.path)
    }
    func select(_ id: String?) async {
        // Save the old selection before changing it (selection is kept separately from the List binding).
        if selectedID != id { savePosition(); selectedID = id }
        lastRecordingID = id; savePreferences()
        focusSegmentID = nil; loadTranscript(); refreshSearch()
        guard let recording = selected else { player.unload(); return }
        await player.load(url: resolve(recording), fingerprint: recording.fingerprint, position: recording.playPosition)
        guard selectedID == recording.id else { return }
        if player.available, abs(recording.duration - player.duration) > 0.2 {
            var updated = recording; updated.duration = player.duration; save(updated)
        }
    }
    func pickFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.mp3, UTType.mpeg4Audio, UTType.wav, UTType(filenameExtension: "flac") ?? .audio]
        panel.message = "音频仅被引用，原文件不会被复制或修改。"
        guard panel.runModal() == .OK else { return }
        Task { await importFiles(panel.urls) }
    }
    func importFiles(_ urls: [URL]) async {
        guard store != nil else { return }
        guard !importing else { alert = "正在导入上一批音频，请稍后再拖入。"; return }
        importing = true; defer { importing = false }
        var imported = 0, duplicates = 0
        var failures: [String] = []
        for url in urls {
            guard ["mp3", "m4a", "wav", "flac"].contains(url.pathExtension.lowercased()) else {
                failures.append("\(url.lastPathComponent)：暂不支持此格式"); continue
            }
            do {
                let fingerprint = try await Task.detached(priority: .utility) { try FileFingerprint.sha256(url) }.value
                if let existing = recordings.first(where: { $0.fingerprint == fingerprint }) {
                    duplicates += 1
                    if selectedID == nil { await select(existing.id) }
                    continue
                }
                let length = try await AVURLAsset(url: url).load(.duration).seconds
                guard length.isFinite, length > 0 else { throw AudioError.message("无法读取音频时长") }
                let bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
                let recording = Recording(title: url.deletingPathExtension().lastPathComponent, path: url.path,
                                          bookmark: bookmark, fingerprint: fingerprint, duration: length)
                try store?.save(recording); reload(); imported += 1
                if selectedID == nil { await select(recording.id) }
                if ready { enqueue(recording.id) }
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        notice = "已导入 \(imported) 份录音" + (duplicates > 0 ? "，\(duplicates) 份已在资料库中" : "")
        if !failures.isEmpty { alert = failures.joined(separator: "\n") }
        if !ready, imported > 0 { showSettings = true }
    }
    func enqueue(_ id: String, speakersOnly: Bool = false) {
        guard ready else { showSettings = true; return }
        guard activeRecordingID != id, !queue.contains(where: { $0.recordingID == id }), var recording = recordings.first(where: { $0.id == id }) else { return }
        if speakersOnly && recording.activeRun == nil { return }
        queue.append(QueuedJob(recordingID: id, speakersOnly: speakersOnly))
        recording.state = .queued; recording.error = nil; save(recording)
        startNext()
    }
    func enqueuePending() { for recording in recordings where recording.state == .idle { enqueue(recording.id) } }
    private func startNext() {
        guard worker == nil, !queue.isEmpty, ready else { return }
        let job = queue.removeFirst()
        guard let recording = recordings.first(where: { $0.id == job.recordingID }) else { startNext(); return }
        let request = WorkerRequest(recordingID: recording.id, runID: job.speakersOnly ? recording.activeRun! : UUID().uuidString,
                                    source: resolve(recording).path, fingerprint: recording.fingerprint,
                                    toolsDirectory: toolsDirectory.path, modelsDirectory: modelsDirectory.path,
                                    temporaryDirectory: dataDirectory.appendingPathComponent("Temporary").path,
                                    speakerCount: recording.speakerCount, speakersOnly: job.speakersOnly)
        self.request = request; activeJobID = request.jobID; activeRecordingID = recording.id
        cancelledJob = false; progress = nil; phaseMessage = "准备处理"
        do {
            let temporary = dataDirectory.appendingPathComponent("Temporary", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let requestURL = temporary.appendingPathComponent(request.jobID + ".json")
            try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
            let child = Process(), pipe = Pipe()
            let packagedWorker = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AudioWorker")
            let executable = FileManager.default.isExecutableFile(atPath: packagedWorker.path) ? packagedWorker
                : URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("AudioWorker")
            child.executableURL = executable; child.arguments = [requestURL.path]; child.standardOutput = pipe
            let logURL = temporary.appendingPathComponent(request.jobID + ".log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: logURL); logHandle = handle
            child.standardError = handle; child.standardInput = FileHandle.nullDevice
            worker = child; try child.run()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var buffer = Data()
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        if let event = try? JSONDecoder().decode(WorkerEvent.self, from: line) {
                            DispatchQueue.main.async { self?.handle(event, request: request) }
                        }
                    }
                }
                child.waitUntilExit()
                DispatchQueue.main.async { self?.finish(status: child.terminationStatus, requestURL: requestURL, logURL: logURL) }
            }
        } catch {
            worker = nil; activeJobID = nil; activeRecordingID = nil
            var updated = recording; updated.state = .failed; updated.error = error.localizedDescription; save(updated)
            startNext()
        }
    }
    private func handle(_ event: WorkerEvent, request: WorkerRequest) {
        guard event.jobID == activeJobID, var recording = recordings.first(where: { $0.id == request.recordingID }) else { return }
        do {
            switch event.kind {
            case "stage":
                if !cancelledJob, let state = event.state { recording.state = state; try store?.save(recording) }
                if let message = event.message { phaseMessage = message; progress = nil }
                if let value = event.progress { progress = value }
            case "transcript":
                if let segments = event.segments {
                    let activated = try store?.addTranscript(recordingID: recording.id, runID: request.runID, segments: segments, duration: event.duration) ?? false
                    if !activated { notice = "新转写已存为历史版本，当前人工纠错版本保持不变。" }
                }
            case "diarization":
                if let turns = event.turns { try store?.applySpeakers(runID: request.runID, turns: turns) }
            case "done":
                if !cancelledJob { recording.state = .completed; recording.error = nil; try store?.save(recording) }
            case "error":
                if !cancelledJob { recording.state = .failed; recording.error = event.message; try store?.save(recording) }
            default: break
            }
            reload()
        } catch {
            alert = "保存处理结果失败：\(error.localizedDescription)"; cancel(recording.id)
        }
    }
    private func finish(status: Int32, requestURL: URL, logURL: URL) {
        if let id = activeRecordingID, var recording = recordings.first(where: { $0.id == id }), recording.state.isRunning || recording.state == .queued {
            recording.state = cancelledJob ? .cancelled : .failed
            recording.error = cancelledJob ? nil : "后台任务意外退出（\(status)），可重试。"
            save(recording)
        }
        try? logHandle?.close(); logHandle = nil
        try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: logURL)
        worker = nil; request = nil; activeJobID = nil; activeRecordingID = nil; progress = nil; phaseMessage = ""
        startNext()
    }
    func cancel(_ id: String) {
        queue.removeAll { $0.recordingID == id }
        if activeRecordingID == id { cancelledJob = true; worker?.terminate(); phaseMessage = "正在取消并清理临时文件…" }
        if var recording = recordings.first(where: { $0.id == id }) { recording.state = .cancelled; recording.error = nil; save(recording) }
    }
    func changeSpeakerCount(_ count: Int?) { guard var r = selected else { return }; r.speakerCount = count; save(r) }
    func switchRun(_ id: String) { guard var r = selected else { return }; r.activeRun = id; save(r) }
    func editText(_ id: String, text: String) {
        do { try store?.editText(segmentID: id, text: text); loadTranscript(); refreshSearch() } catch { alert = error.localizedDescription }
    }
    func editTexts(_ edits: [String: String]) {
        do { try store?.editTexts(edits); loadTranscript(); refreshSearch() } catch { alert = error.localizedDescription }
    }
    func editUtteranceSpeaker(_ utterance: SpeechUtterance, speaker: Int?) {
        do {
            try store?.editSpeakers(segmentIDs: utterance.segments.map(\.id), speaker: speaker)
            loadTranscript(); refreshSearch()
        } catch { alert = error.localizedDescription }
    }
    func renameRecording(_ id: String, name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var recording = recordings.first(where: { $0.id == id }) else { return }
        recording.title = title; save(recording)
    }
    func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func setReaderFontSize(_ size: Double) { readerFontSize = min(22, max(14, size)); savePreferences() }
    func setPreRoll(_ seconds: Double) { preRoll = min(2, max(0, seconds)); savePreferences() }
    func setReadingPunctuation(_ value: Bool) { readingPunctuation = value; savePreferences(); refreshSearch() }
    func setReadingParagraphBreaks(_ value: Bool) { readingParagraphBreaks = value; savePreferences(); refreshSearch() }
    func readingText(_ utterance: SpeechUtterance) -> String {
        ReadingTranscript(segments: utterance.segments, punctuate: readingPunctuation, paragraphBreaks: readingParagraphBreaks).text
    }
    func readingSentence(_ sentence: TranscriptSegment) -> String {
        guard let groupID = segmentToUtterance[sentence.id], let group = utterances.first(where: { $0.id == groupID }) else { return sentence.text }
        return ReadingTranscript(segments: group.segments, punctuate: readingPunctuation, paragraphBreaks: false).sentenceTexts[sentence.id] ?? sentence.text
    }
    func exportText(srt: Bool) -> String {
        TranscriptExport.render(title: selected?.title ?? "", segments: segments, names: names, srt: srt,
                                punctuate: readingPunctuation, paragraphBreaks: readingParagraphBreaks)
    }
    private func savePreferences() {
        guard store != nil else { return }
        do {
            let preferences = AppPreferences(modelsDirectory: modelsDirectory.path, readerFontSize: readerFontSize,
                                             preRoll: preRoll, lastRecordingID: lastRecordingID,
                                             readingPunctuation: readingPunctuation, readingParagraphBreaks: readingParagraphBreaks)
            try JSONEncoder().encode(preferences).write(to: dataDirectory.appendingPathComponent("settings.json"), options: .atomic)
        } catch { alert = error.localizedDescription }
    }
    func editSpeaker(_ id: String, speaker: Int?) {
        do { try store?.editSpeaker(segmentID: id, speaker: speaker); loadTranscript(); refreshSearch() } catch { alert = error.localizedDescription }
    }
    func renameSpeaker(_ id: Int, name: String) {
        guard let run = selected?.activeRun else { return }
        do { try store?.renameSpeaker(runID: run, speaker: id, name: name); loadTranscript(); refreshSearch() } catch { alert = error.localizedDescription }
    }
    func speakerName(_ id: Int?) -> String { id.flatMap { names[$0] } ?? SpeakerMatcher.defaultName(id) }
    func refreshSearch() {
        searchTask?.cancel()
        guard !searchText.isEmpty else { hits = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            do { hits = try store?.search(searchText, recordingID: searchAll ? nil : selectedID ?? "",
                                         punctuate: readingPunctuation, paragraphBreaks: readingParagraphBreaks) ?? [] }
            catch { alert = error.localizedDescription }
        }
    }
    func openHit(_ hit: SearchHit) async {
        if selectedID != hit.recordingID { await select(hit.recordingID) }
        guard selectedID == hit.recordingID else { return }
        focusSegmentID = hit.segment.id
        focusRequestID = UUID()
        player.seek(max(0, hit.segment.start - preRoll), play: true)
    }
    func playSegment(_ segment: TranscriptSegment) { focusSegmentID = segment.id; focusRequestID = UUID(); player.seek(max(0, segment.start - preRoll), play: true) }
    func locateCurrentSentence() { focusSegmentID = currentSegmentID; focusRequestID = UUID() }
    func focusText(at position: Double) {
        focusSegmentID = (segments.first(where: { $0.end >= position }) ?? segments.last)?.id
        focusRequestID = UUID()
    }
    func relocate() async {
        guard let recording = selected else { return }
        let panel = NSOpenPanel(); panel.message = "选择原录音。程序会校验内容，已有文字和纠错不会丢失。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await Task.detached(priority: .utility) { try FileFingerprint.verify(url, expected: recording.fingerprint) }.value
            var updated = recording; updated.path = url.path
            updated.bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            save(updated); await select(recording.id)
            notice = "已重新定位原音频，转写和纠错均已保留。"
        } catch { alert = error.localizedDescription }
    }
    func remove(_ id: String) {
        guard activeRecordingID != id else { alert = "请先取消当前任务，等待清理完成后再移除。"; return }
        queue.removeAll { $0.recordingID == id }
        do {
            try store?.remove(id)
            if selectedID == id { player.unload(); selectedID = nil }
            reload(); if selectedID == nil, let first = recordings.first { Task { await select(first.id) } }
        } catch { alert = error.localizedDescription }
    }
    func export(srt: Bool) {
        guard let recording = selected, !segments.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: srt ? "srt" : "txt", conformingTo: .plainText) ?? .plainText]
        panel.nameFieldStringValue = recording.title
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportText(srt: srt).write(to: url, atomically: true, encoding: .utf8)
            notice = "已导出 \(url.lastPathComponent)"
        } catch { alert = error.localizedDescription }
    }
    func chooseModelsDirectory() async {
        guard !installer.busy, worker == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "选择包含 Whisper、Silero VAD、语音分段和中文声纹模型的文件夹。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelsDirectory = url
        savePreferences()
        await installer.validate(directory: url)
    }
    func shutdown() {
        savePosition(); installer.cancel()
        for job in queue {
            if var r = recordings.first(where: { $0.id == job.recordingID }) { r.state = .interrupted; try? store?.save(r) }
        }
        queue = []
        if let id = activeRecordingID, var r = recordings.first(where: { $0.id == id }) { r.state = .interrupted; try? store?.save(r) }
        cancelledJob = true; worker?.terminate(); player.pause()
    }
}
