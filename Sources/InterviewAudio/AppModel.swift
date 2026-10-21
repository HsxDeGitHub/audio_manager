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
    @Published var smartPunctuation = true
    @Published var punctuationBusy = false
    @Published var punctuationMessage = ""
    @Published var readingOverrides: [String: String] = [:]
    private var punctuationTask: Task<Void, Never>?
    private let punctuationProcessor = PunctuationProcessor()
    @Published var reviewFilter: ReviewFilter = .all
    @Published var bulkSelection: Set<String> = []
    @Published var selectionMode = false
    @Published var undoLabel: String?
    @Published var redoLabel: String?
    @Published var readingDensity: ReadingDensity = .balanced
    @Published var librarySort: LibrarySort = .newest
    @Published var libraryFilter: LibraryFilter = .all
    @Published var libraryTitleFilter = ""
    @Published var activeHitID: String?
    @Published var hasSearchOrigin = false
    @Published var showAbout = false
    @Published var showAISettings = false
    @Published var showAICompose = false
    @Published var showMemories = false
    @Published var showDocuments = false
    @Published var documentSourceID: String?
    @Published var documentSourceLine: Int = 1
    @Published var showToolSettings = false
    @Published var aiSettings = AISettings()
    @Published var aiDrafts: [AIDraft] = []
    @Published var selectedAIDraftID: String?
    @Published var readerShowsAI = false
    @Published var aiActiveDraftID: String?
    @Published var aiActiveRecordingID: String?
    @Published var aiProgressMessage = ""
    var aiTask: Task<Void, Never>?
    var aiWorkingDraft: AIDraft?
    let aiClient = AIClient()
    private struct SearchOrigin { var recordingID: String?; var position: Double; var focusedID: String?; var playing: Bool }
    private var searchOrigin: SearchOrigin?
    private var searchSession = false
    private var searchQueryKey = ""
    private var sampleSpeaker: Int?
    private var sampleIndex = 0
    var visibleRecordings: [Recording] { LibraryOrdering.apply(recordings, sort: librarySort, filter: libraryFilter, title: libraryTitleFilter) }
    var visibleUtterances: [SpeechUtterance] { utterances.filter { reviewFilter.includes($0) } }
    var pendingReviewCount: Int { segments.filter(\.pendingReview).count }
    var activeHitIndex: Int? { hits.firstIndex { $0.id == activeHitID } }
    let installer = ModelInstaller()
    let player = PlayerController()
    let dataDirectory: URL
    let toolsDirectory: URL
    private(set) var store: BackendLibraryStore?
    private(set) var backendClient: BackendClient?
    private var deviceBridge: DeviceBridge?
    let backendProcess = BackendProcess()
    let assistant = AssistantModel()
    @Published var backendState = "正在连接本地服务…"
    @Published var backendUnavailable = false
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
    func queuePosition(_ id: String) -> Int? { queue.firstIndex { $0.recordingID == id }.map { $0 + 1 } }
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
        smartPunctuation = preferences?.smartPunctuation ?? true
        readingDensity = preferences?.readingDensity ?? .balanced
        librarySort = preferences?.librarySort ?? .newest; libraryFilter = preferences?.libraryFilter ?? .all
        do { aiSettings = try AISettings.load(from: dataDirectory.appendingPathComponent("llm-settings.json")) }
        catch { alert = "大模型配置文件无法读取，请在大模型设置中检查。" }
        player.onPosition = { [weak self] position in
            guard let self, Date().timeIntervalSince(self.lastSavedPosition) > 3 else { return }
            self.savePosition(position)
        }
    }

    func prepare() async {
        guard !prepared else { return }; prepared = true
        await connectBackend()
        async let validation: Void = installer.validate(directory: modelsDirectory)
        let restored = recordings.first(where: { $0.id == lastRecordingID }) ?? recordings.first
        if let restored { await select(restored.id) }
        await validation
        loadTranscript()
        if !installer.ready { showSettings = true }
    }
    func connectBackend() async {
        do {
            let connection = try await backendProcess.start(dataDirectory: dataDirectory)
            store = BackendLibraryStore(connection: connection)
            backendClient = try BackendClient(baseURL: connection.baseURL, token: connection.token, timeout: 30)
            await assistant.attach(connection)
            deviceBridge?.stop()
            deviceBridge = nil
            if let backendClient {
                let bridge = DeviceBridge(app: self, client: backendClient)
                bridge.start(); deviceBridge = bridge
            }
            backendUnavailable = false; backendState = "本地服务已连接"; reload()
        } catch {
            store = nil; backendClient = nil; deviceBridge?.stop(); deviceBridge = nil; backendUnavailable = true
            backendState = backendProcess.diagnostic ?? "服务不可用，请重试。"
        }
    }
    func openAssistantSource(_ source: AssistantReference, play: Bool) async {
        do {
            guard let client = assistant.client else { return }
            let resolved = try await client.source(source)
            if source.resourceType == "document" {
                documentSourceID = source.resourceID; documentSourceLine = resolved.line ?? 1; showDocuments = true
            } else if let recordingID = resolved.recordingID {
                await select(recordingID)
                if let run = resolved.runID, selected?.activeRun != run { switchRun(run) }
                readerShowsAI = false; reviewFilter = .all; focusSegmentID = resolved.segmentID; focusRequestID = UUID()
                if play, let start = resolved.start { player.seek(max(0, start - preRoll), play: true) }
            } else { notice = resolved.text }
        } catch { alert = error.localizedDescription }
    }
    func reload() {
        do {
            recordings = try store?.recordings() ?? []
            loadTranscript()
            refreshSearch()
        } catch { alert = error.localizedDescription }
    }
    /// 界面与助手共用同一业务修改接口；版本冲突由后端统一返回 409。
    func recordingMetadata(_ id: String) async throws -> BackendRecording {
        guard let backendClient else { throw BackendClientError.unavailable }
        return try await backendClient.send("/api/v1/recordings/\(id)")
    }
    func updateRecordingMetadata(_ id: String, fields: [String: Any], revision: Int) async throws {
        guard let backendClient else { throw BackendClientError.unavailable }
        struct Receipt: Decodable { let id: String; let state: String; let count: Int }
        let body = try JSONSerialization.data(withJSONObject: ["operation_id": UUID().uuidString,
                                                               "expected_revision": revision, "fields": fields])
        let _: Receipt = try await backendClient.send("/api/v1/recordings/\(id)", method: "PATCH", body: body)
        reload()
    }
    private func loadTranscript() {
        do {
            runs = try selectedID.map { try store?.runs(recordingID: $0) ?? [] } ?? []
            if let run = selected?.activeRun {
                segments = try store?.segments(runID: run) ?? []
                names = try store?.speakerNames(runID: run) ?? [:]
            } else { segments = []; names = [:] }
            undoLabel = try selected?.activeRun.flatMap { try store?.historyLabel(runID: $0) }
            redoLabel = try selected?.activeRun.flatMap { try store?.historyLabel(runID: $0, redo: true) }
            bulkSelection.formIntersection(Set(segments.map(\.id)))
            utterances = UtteranceGrouping.make(segments)
            segmentToUtterance = Dictionary(uniqueKeysWithValues: utterances.flatMap { utterance in
                utterance.segments.map { ($0.id, utterance.id) }
            })
            preparePunctuation()
            loadAIDrafts()
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
        if selectedID != id { savePosition(); selectedID = id; reviewFilter = .all; bulkSelection = []; selectionMode = false; sampleSpeaker = nil; readerShowsAI = false; selectedAIDraftID = nil }
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
            try store?.startWorker(request)
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
        guard event.jobID == activeJobID, let recording = recordings.first(where: { $0.id == request.recordingID }) else { return }
        do {
            let activated = try store?.ingestWorker(event, request: request)
            if activated == false { notice = "新转写已存为历史版本，当前人工纠错版本保持不变。" }
            if event.kind == "stage" {
                if let message = event.message { phaseMessage = message; progress = nil }
                if let value = event.progress { progress = value }
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
        if activeRecordingID == id { if let job = activeJobID { try? store?.stopWorker(job, state: "cancelled") }; cancelledJob = true; worker?.terminate(); phaseMessage = "正在取消并清理临时文件…" }
        if var recording = recordings.first(where: { $0.id == id }) { recording.state = .cancelled; recording.error = nil; save(recording) }
    }
    func changeSpeakerCount(_ count: Int?) { guard var r = selected else { return }; r.speakerCount = count; save(r) }
    func switchRun(_ id: String) { guard var r = selected else { return }; r.activeRun = id; save(r) }
    func setSmartPunctuation(_ value: Bool) { smartPunctuation = value; savePreferences(); preparePunctuation(); refreshSearch() }
    func refreshPunctuation() { preparePunctuation() }
    private func preparePunctuation() {
        punctuationTask?.cancel(); punctuationProcessor.cancel(); punctuationBusy = false; readingOverrides = [:]; punctuationMessage = ""
        guard smartPunctuation, let run = selected?.activeRun, let store else { return }
        let cache = (try? store.readingCache(runID: run)) ?? [:]
        let groups = utterances
        for group in groups {
            if let saved = cache[PunctuationProjection.key(group.segments)] { readingOverrides.merge(saved) { _,new in new } }
        }
        guard readingPunctuation, installer.valid.contains(ModelSpec.punctuation.id) else { return }
        let executable = toolsDirectory.appendingPathComponent("sherpa/bin/sherpa-onnx-offline-punctuation")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { punctuationMessage = "智能标点工具不可用，正在使用规则标点"; return }
        let missing = groups.filter { PunctuationProjection.eligible($0.segments) && cache[PunctuationProjection.key($0.segments)] == nil }
        guard !missing.isEmpty else { return }
        let model = modelsDirectory.appendingPathComponent(ModelSpec.punctuation.id)
        punctuationBusy = true
        punctuationTask = Task {
            defer { if !Task.isCancelled { punctuationBusy = false } }
            try? await Task.sleep(nanoseconds: 250_000_000)
            for group in missing {
                guard !Task.isCancelled, selected?.activeRun == run else { return }
                do {
                    if let result = try await punctuationProcessor.render(group.segments, executable: executable, model: model) {
                        guard !Task.isCancelled, selected?.activeRun == run else { return }
                        try store.saveReadingCache(runID: run, key: PunctuationProjection.key(group.segments), rendered: result)
                        readingOverrides.merge(result) { _,new in new }
                    }
                } catch { punctuationMessage = error.localizedDescription; break }
            }
            if !Task.isCancelled { refreshSearch() }
        }
    }
    func setLibrarySort(_ value: LibrarySort) { librarySort = value; savePreferences() }
    func setLibraryFilter(_ value: LibraryFilter) { libraryFilter = value; savePreferences() }
    func setReadingDensity(_ value: ReadingDensity) { readingDensity = value; savePreferences(); refreshSearch() }
    func undoEdit(redo: Bool = false) {
        guard let run = selected?.activeRun else { return }
        do { if try store?.restoreEdit(runID: run, redo: redo) == true { loadTranscript(); refreshSearch() } }
        catch { alert = error.localizedDescription }
    }
    func markReviewed(_ ids: [String], reviewed: Bool = true) {
        do { try store?.markReviewed(segmentIDs: ids, reviewed: reviewed); loadTranscript() } catch { alert = error.localizedDescription }
    }
    func mergeSpeakers(_ sources: Set<Int>, into target: Int) {
        guard let run = selected?.activeRun else { return }
        do { try store?.mergeSpeakers(runID: run, sources: sources, target: target); loadTranscript(); refreshSearch(); notice = "已合并说话人，可通过撤销恢复。" }
        catch { alert = error.localizedDescription }
    }
    func setBulkSpeaker(_ speaker: Int?) {
        do { try store?.editSpeakers(segmentIDs: Array(bulkSelection), speaker: speaker); loadTranscript(); refreshSearch(); bulkSelection = [] }
        catch { alert = error.localizedDescription }
    }
    func toggleSelection(_ utterance: SpeechUtterance) {
        let ids = Set(utterance.segments.map(\.id))
        if ids.isSubset(of: bulkSelection) { bulkSelection.subtract(ids) } else { bulkSelection.formUnion(ids) }
    }
    func previewSpeaker(_ speaker: Int) {
        reviewFilter = .all
        let samples = SpeakerSamples.select(segments, speaker: speaker)
        guard !samples.isEmpty else { return }
        if sampleSpeaker != speaker { sampleSpeaker = speaker; sampleIndex = 0 }
        let sentence = samples[sampleIndex % samples.count]; sampleIndex += 1
        focusSegmentID = sentence.id; focusRequestID = UUID()
        player.playExcerpt(start: sentence.start, end: min(sentence.end, sentence.start + 8))
        notice = "试听 \(speakerName(speaker)) · 第 \((sampleIndex - 1) % samples.count + 1) / \(samples.count) 段"
    }
    func saveCorrection(_ id: String, text: String?, reviewed: Bool) {
        do { try store?.saveCorrection(segmentID: id, text: text, markReviewed: reviewed); loadTranscript(); refreshSearch() }
        catch { alert = error.localizedDescription }
    }
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
    func setReadingPunctuation(_ value: Bool) { readingPunctuation = value; savePreferences(); preparePunctuation(); refreshSearch() }
    func setReadingParagraphBreaks(_ value: Bool) { readingParagraphBreaks = value; savePreferences(); refreshSearch() }
    func readingText(_ utterance: SpeechUtterance) -> String {
        ReadingTranscript(segments: utterance.segments, punctuate: readingPunctuation, paragraphBreaks: readingParagraphBreaks, density: readingDensity, overrides: readingOverrides).text
    }
    func readingSentence(_ sentence: TranscriptSegment) -> String {
        guard let groupID = segmentToUtterance[sentence.id], let group = utterances.first(where: { $0.id == groupID }) else { return sentence.text }
        return ReadingTranscript(segments: group.segments, punctuate: readingPunctuation, paragraphBreaks: false, density: readingDensity, overrides: readingOverrides).sentenceTexts[sentence.id] ?? sentence.text
    }
    func exportText(srt: Bool, plainDialogue: Bool = false) -> String {
        TranscriptExport.render(title: selected?.title ?? "", segments: segments, names: names, srt: srt,
                                punctuate: readingPunctuation, paragraphBreaks: readingParagraphBreaks, density: readingDensity, overrides: readingOverrides, plainDialogue: plainDialogue)
    }
    private func savePreferences() {
        guard store != nil else { return }
        do {
            let preferences = AppPreferences(modelsDirectory: modelsDirectory.path, readerFontSize: readerFontSize,
                                             preRoll: preRoll, lastRecordingID: lastRecordingID,
                                             readingPunctuation: readingPunctuation, readingParagraphBreaks: readingParagraphBreaks, readingDensity: readingDensity,
                                             librarySort: librarySort, libraryFilter: libraryFilter, smartPunctuation: smartPunctuation)
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
        let key = searchText + "\u{0}" + (searchAll ? "all" : selectedID ?? "")
        if searchQueryKey != key { hits = []; activeHitID = nil; searchQueryKey = key }
        if !searchText.isEmpty && !searchSession {
            searchOrigin = SearchOrigin(recordingID: selectedID, position: player.position, focusedID: focusSegmentID, playing: player.playing)
            hasSearchOrigin = searchOrigin?.recordingID != nil; searchSession = true
        }
        guard !searchText.isEmpty else { hits = []; activeHitID = nil; searchSession = false; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            do { hits = try store?.search(searchText, recordingID: searchAll ? nil : selectedID ?? "",
                                         punctuate: readingPunctuation, paragraphBreaks: readingParagraphBreaks, density: readingDensity, smartPunctuation: smartPunctuation) ?? [] }
            catch { alert = error.localizedDescription }
        }
    }
    func openHit(_ hit: SearchHit) async {
        readerShowsAI = false
        activeHitID = hit.id; reviewFilter = .all
        if selectedID != hit.recordingID { await select(hit.recordingID) }
        guard selectedID == hit.recordingID else { return }
        focusSegmentID = hit.segment.id
        focusRequestID = UUID()
        player.seek(max(0, hit.segment.start - preRoll), play: true)
    }
    func navigateHit(_ direction: Int) {
        guard !hits.isEmpty else { return }
        let index = activeHitIndex.map { ($0 + direction + hits.count) % hits.count } ?? (direction < 0 ? hits.count - 1 : 0)
        let hit = hits[index]; Task { await openHit(hit) }
    }
    func returnFromSearch() async {
        guard let origin = searchOrigin else { return }
        searchText = ""; searchTask?.cancel(); hits = []; activeHitID = nil; searchSession = false; searchOrigin = nil; hasSearchOrigin = false
        if selectedID != origin.recordingID { await select(origin.recordingID) }
        reviewFilter = .all
        player.seek(origin.position, play: origin.playing)
        focusSegmentID = origin.focusedID ?? segments.first(where: { $0.end >= origin.position })?.id; focusRequestID = UUID()
    }
    func playSegment(_ segment: TranscriptSegment) { focusSegmentID = segment.id; focusRequestID = UUID(); player.seek(max(0, segment.start - preRoll), play: true) }
    func locateCurrentSentence() { readerShowsAI = false; reviewFilter = .all; focusSegmentID = currentSegmentID; focusRequestID = UUID() }
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
        guard aiActiveRecordingID != id else { alert = "请先取消该录音的 AI 整理，再移除。"; return }
        queue.removeAll { $0.recordingID == id }
        do {
            try store?.remove(id)
            if selectedID == id { player.unload(); selectedID = nil }
            reload(); if selectedID == nil, let first = recordings.first { Task { await select(first.id) } }
        } catch { alert = error.localizedDescription }
    }
    func export(srt: Bool, plainDialogue: Bool = false) {
        guard let recording = selected, !segments.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: srt ? "srt" : "txt", conformingTo: .plainText) ?? .plainText]
        panel.nameFieldStringValue = recording.title
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportText(srt: srt, plainDialogue: plainDialogue).write(to: url, atomically: true, encoding: .utf8)
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
        stopAIForShutdown()
        if let job = activeJobID { try? store?.stopWorker(job, state: "interrupted") }
        savePosition(); installer.cancel(); punctuationTask?.cancel(); punctuationProcessor.cancel()
        for job in queue {
            if var r = recordings.first(where: { $0.id == job.recordingID }) { r.state = .interrupted; try? store?.save(r) }
        }
        queue = []
        if let id = activeRecordingID, var r = recordings.first(where: { $0.id == id }) { r.state = .interrupted; try? store?.save(r) }
        cancelledJob = true; worker?.terminate(); player.pause()
        assistant.stop(); deviceBridge?.stop(); deviceBridge = nil; store = nil; backendProcess.stop()
    }
}
