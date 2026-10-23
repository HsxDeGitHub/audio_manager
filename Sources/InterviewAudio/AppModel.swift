import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import AudioCore

enum LibrarySection { case audio, documents }

private struct QueuedJob { let request: WorkerRequest; var recordingID: String { request.recordingID }; var speakersOnly: Bool { request.speakersOnly } }

@MainActor
final class AppModel: ObservableObject {
    @Published var librarySection: LibrarySection = .audio
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
    let changeHistory = ChangeHistoryModel()
    @Published var showChangeHistory = false
    @Published var historicalSource: BackendSource?
    @Published var showMemories = false
    @Published var showDocuments = false
    @Published var documentSourceID: String?
    @Published var documentSourceLine: Int = 1
    @Published var showToolSettings = false
    @Published var aiSettings = AISettings()
    let aiConnectionClient = AIConnectionClient()
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
    private var deviceReceiptJournal: DeviceReceiptJournal?
    let backendProcess = BackendProcess()
    let assistant = AssistantModel()
    @Published var backendState = "正在连接本地服务…"
    @Published var backendUnavailable = false
    @Published var backendConnecting = false
    private var backendGeneration = UUID()
    private var shuttingDown = false
    private var queue: [QueuedJob] = []
    private var worker: Process?
    private var request: WorkerRequest?
    private var workerEvents: Task<Void, Never>?
    private var logHandle: FileHandle?
    private var cancelledJob = false
    private var lastSavedPosition = Date.distantPast
    private var searchTask: Task<Void, Never>?
    private var segmentToUtterance: [String: String] = [:]
    private var lastRecordingID: String?
    private var prepared = false
    private var loadGeneration = UUID()
    private var pendingEnqueue: Set<String> = []
    private var cancelledEnqueues: Set<String> = []
    private var selectionGeneration = UUID()
    @Published var libraryLoading = false
    @Published var searchLoading = false
    @Published var searchHasMore = false
    private var searchOffset = 0
    var selected: Recording? { recordings.first { $0.id == selectedID } }
    var ready: Bool { installer.ready }
    func queuePosition(_ id: String) -> Int? { queue.firstIndex { $0.recordingID == id }.map { $0 + 1 } }
    var taskCount: Int { queue.count + (worker == nil ? 0 : 1) }
    var currentSegmentID: String? { player.available ? segments.first { $0.start <= player.position && player.position < $0.end }?.id : nil }
    func utteranceID(for segmentID: String?) -> String? { segmentID.flatMap { segmentToUtterance[$0] } }

    init(dataDirectoryOverride: URL? = nil) {
        // 验收副本可在自身签名配置中固定目录，Launch Services 启动也不会丢失隔离。
        let override = (Bundle.main.object(forInfoDictionaryKey: "InterviewAudioDataDirectory") as? String)
            ?? ProcessInfo.processInfo.environment["INTERVIEW_AUDIO_DATA_DIR"]
        precondition(override == nil || override!.hasPrefix("/"), "应用数据目录必须是绝对路径，已停止启动以避免回落到其他资料库。")
        dataDirectory = dataDirectoryOverride ?? override.map { URL(fileURLWithPath: $0, isDirectory: true) }
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
            Task { await self.savePosition(position) }
        }
    }

    func prepare() async {
        guard !prepared else { return }; prepared = true
        await connectBackend()
        async let validation: Void = installer.validate(directory: modelsDirectory)
        let restored = recordings.first(where: { $0.id == lastRecordingID }) ?? recordings.first
        if let restored { await select(restored.id) }
        await validation
        await loadTranscript()
        if !installer.ready { showSettings = true }
    }
    func backendDisconnected(_ message: String) {
        guard !shuttingDown else { return }
        backendUnavailable = true; backendState = message
        store = nil; backendClient = nil; changeHistory.client = nil
        deviceBridge?.stop(); deviceBridge = nil; assistant.disconnected()
    }
    func connectBackend() async {
        guard !backendConnecting, !shuttingDown else { return }
        backendConnecting = true; defer { backendConnecting = false }
        let generation = UUID(); backendGeneration = generation
        backendProcess.onUnavailable = { [weak self] message in self?.backendDisconnected(message) }
        let onFailure: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.backendGeneration == generation else { return }
                self.backendDisconnected("本地服务连接已中断，请重试；未完成任务可在重连后继续。")
            }
        }
        do {
            let connection = try await backendProcess.start(dataDirectory: dataDirectory)
            store = BackendLibraryStore(connection: connection, onTransportFailure: onFailure)
            backendClient = try BackendClient(baseURL: connection.baseURL, token: connection.token, timeout: 30, onTransportFailure: onFailure)
            changeHistory.client = backendClient
            await assistant.bind(self)
            try await assistant.attach(connection, onTransportFailure: onFailure)
            deviceBridge?.stop()
            deviceBridge = nil
            if let backendClient {
                if deviceReceiptJournal == nil { deviceReceiptJournal = try DeviceReceiptJournal(url: dataDirectory.appendingPathComponent("Backend/Device/receipts.json")) }
                let bridge = DeviceBridge(app: self, client: backendClient, journal: deviceReceiptJournal!)
                bridge.start(); deviceBridge = bridge
            }
            backendUnavailable = false; backendState = "本地服务已连接"; await reload()
        } catch {
            backendDisconnected(backendProcess.diagnostic ?? "服务不可用，请重试。")
        }
    }
    func openAssistantSource(_ source: AssistantReference, play: Bool) async {
        do {
            guard let client = assistant.client else { return }
            let resolved = try await client.source(source)
            if resolved.historical == true || resolved.draftID != nil {
                await openReadOnlySource(resolved, play: play)
            } else if source.resourceType == "document" {
                documentSourceID = source.resourceID; documentSourceLine = resolved.line ?? 1; librarySection = .documents
            } else if let recordingID = resolved.recordingID {
                await select(recordingID)
                guard selectedID == recordingID else { return }
                if let run = resolved.runID, selected?.activeRun != run { await switchRun(run) }
                reviewFilter = .all; focusSegmentID = resolved.segmentID; focusRequestID = UUID()
                if play, let start = resolved.start { player.seek(max(0, start - preRoll), play: true) }
            } else { notice = resolved.text }
        } catch { alert = error.localizedDescription }
    }
    func openReadOnlySource(_ source: BackendSource, play: Bool) async {
        historicalSource = source
        if play { await playHistoricalSource(source) }
    }
    func playHistoricalSource(_ source: BackendSource) async {
        do {
            guard let id = source.recordingID, recordings.contains(where: { $0.id == id }), let start = source.start else { throw AudioError.message("历史文字已保留，原音频资料已移除或没有时间位置。") }
            await select(id)
            guard selectedID == id else { throw BackendClientError.conflict }
            _ = try await player.seekVerified(max(0,start-preRoll), play: true)
        } catch { alert = error.localizedDescription }
    }
    func reload() async {
        guard let store else { return }
        let generation = UUID(); loadGeneration = generation
        let selected = selectedID; libraryLoading = true
        defer { if loadGeneration == generation { libraryLoading = false } }
        do {
            let snapshot = try await store.perform { try $0.workspace(recordingID: selected) }
            guard loadGeneration == generation, selectedID == selected, self.store === store else { return }
            recordings = snapshot.recordings
            runs = snapshot.runs.map { TranscriptRun(id: $0.id, createdAt: $0.createdAt, hasEdits: $0.hasEdits) }
            segments = snapshot.segments
            names = Dictionary(uniqueKeysWithValues: snapshot.names.compactMap { k, v in Int(k).map { ($0, v) } })
            undoLabel = snapshot.undo; redoLabel = snapshot.redo
            bulkSelection.formIntersection(Set(segments.map(\.id)))
            utterances = UtteranceGrouping.make(segments)
            segmentToUtterance = Dictionary(uniqueKeysWithValues: utterances.flatMap { group in group.segments.map { ($0.id, group.id) } })
            await preparePunctuation(); refreshSearch()
        } catch is CancellationError { }
        catch { if loadGeneration == generation { alert = error.localizedDescription } }
    }
    /// 界面与助手共用同一业务修改接口；版本冲突由后端统一返回 409。
    func recordingMetadata(_ id: String) async throws -> BackendRecording {
        guard let backendClient else { throw BackendClientError.unavailable }
        return try await backendClient.send("/api/v1/recordings/\(id)")
    }
    func updateRecordingMetadata(_ id: String, fields: [String: Any], revision: Int) async throws {
        guard let backendClient else { throw BackendClientError.unavailable }
        let body = try JSONSerialization.data(withJSONObject: ["operation_id": UUID().uuidString,
                                                               "expected_revision": revision, "fields": fields])
        let receipt: AssistantChange = try await backendClient.send("/api/v1/recordings/\(id)", method: "PATCH", body: body)
        changeHistory.record(receipt); notice = "资料信息已保存，可在修改记录中查看与撤销。"
        await reload()
    }
    private func loadTranscript() async { await reload() }
    func savePosition(_ value: Double? = nil) async {
        guard player.available, var recording = selected else { return }
        recording.playPosition = min(max(0, value ?? player.position), max(recording.duration, player.duration))
        lastSavedPosition = Date()
        do {
            try await store?.perform { try $0.save(recording) }
            if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index] = recording }
            lastSavedPosition = Date()
        } catch { alert = error.localizedDescription }
    }
    private func save(_ recording: Recording) async {
        do { try await store?.perform { try $0.save(recording) }; await reload() } catch { alert = error.localizedDescription }
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
        librarySection = .audio
        let generation = UUID(); selectionGeneration = generation
        // Save the old selection before changing it (selection is kept separately from the List binding).
        if selectedID != id {
            await savePosition()
            guard selectionGeneration == generation else { return }
            selectedID = id; reviewFilter = .all; bulkSelection = []; selectionMode = false; sampleSpeaker = nil
        }
        lastRecordingID = id; savePreferences()
        focusSegmentID = nil; await loadTranscript(); refreshSearch()
        guard selectionGeneration == generation else { return }
        guard let recording = selected else { player.unload(); return }
        await player.load(url: resolve(recording), fingerprint: recording.fingerprint, position: recording.playPosition)
        guard selectedID == recording.id, selectionGeneration == generation else { return }
        if player.available, abs(recording.duration - player.duration) > 0.2 {
            var updated = recording; updated.duration = player.duration; await save(updated)
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
                try await store?.perform { try $0.save(recording) }; await reload(); imported += 1
                if selectedID == nil { await select(recording.id) }
                if ready { await enqueue(recording.id) }
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        notice = "已导入 \(imported) 份录音" + (duplicates > 0 ? "，\(duplicates) 份已在资料库中" : "")
        if !failures.isEmpty { alert = failures.joined(separator: "\n") }
        if !ready, imported > 0 { showSettings = true }
    }
    @discardableResult func enqueue(_ id: String, speakersOnly: Bool = false) async -> String? {
        guard !shuttingDown else { return nil }
        guard ready else { showSettings = true; alert = "处理资源尚未就绪。"; return nil }
        guard !pendingEnqueue.contains(id) else { return nil }
        pendingEnqueue.insert(id); defer { pendingEnqueue.remove(id) }
        cancelledEnqueues.remove(id)
        guard let store, activeRecordingID != id, !queue.contains(where: { $0.recordingID == id }), var recording = recordings.first(where: { $0.id == id }) else { return nil }
        guard !speakersOnly || recording.activeRun != nil else { return nil }
        guard FileManager.default.fileExists(atPath: resolve(recording).path) else { alert = "原音频不可用。"; return nil }
        let request = WorkerRequest(recordingID: recording.id, runID: speakersOnly ? recording.activeRun! : UUID().uuidString,
                                    source: resolve(recording).path, fingerprint: recording.fingerprint,
                                    toolsDirectory: toolsDirectory.path, modelsDirectory: modelsDirectory.path,
                                    temporaryDirectory: dataDirectory.appendingPathComponent("Temporary").path,
                                    speakerCount: recording.speakerCount, speakersOnly: speakersOnly)
        do {
            try await store.perform { try $0.queueWorker(request) }
            recording.state = .queued; recording.error = nil; try await store.perform { try $0.save(recording) }; await reload()
        } catch { try? await store.perform { try $0.stopWorker(request.jobID, state: "failed") }; alert = error.localizedDescription; return nil }
        if shuttingDown || cancelledEnqueues.contains(id) {
            try? await store.perform { try $0.stopWorker(request.jobID, state: "cancelled") }; return nil
        }
        queue.append(QueuedJob(request: request)); await startNext()
        return activeJobID == request.jobID || queue.contains(where: { $0.request.jobID == request.jobID }) ? request.jobID : nil
    }
    func enqueuePending() async { for recording in recordings where recording.state == .idle { await enqueue(recording.id) } }
    private func startNext() async {
        guard !shuttingDown, worker == nil, activeJobID == nil, !queue.isEmpty, ready else { return }
        let job = queue.removeFirst()
        guard let recording = recordings.first(where: { $0.id == job.recordingID }) else { await startNext(); return }
        let request = job.request
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
            try await store?.perform { try $0.startWorker(request) }
            if cancelledJob || shuttingDown {
                try? handle.close(); logHandle = nil
                try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: logURL)
                activeJobID = nil; activeRecordingID = nil; self.request = nil
                await startNext(); return
            }
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
                            DispatchQueue.main.async { self?.scheduleWorkerEvent(event, request: request) }
                        }
                    }
                }
                child.waitUntilExit()
                DispatchQueue.main.async { self?.scheduleWorkerExit(status: child.terminationStatus, requestURL: requestURL, logURL: logURL) }
            }
        } catch {
            try? await store?.perform { try $0.stopWorker(request.jobID, state: "failed") }
            worker = nil; activeJobID = nil; activeRecordingID = nil; self.request = nil
            var updated = recording; updated.state = .failed; updated.error = error.localizedDescription; await save(updated)
            await startNext()
        }
    }
    private func scheduleWorkerEvent(_ event: WorkerEvent, request: WorkerRequest) {
        let previous = workerEvents
        workerEvents = Task { await previous?.value; await handle(event, request: request) }
    }
    private func scheduleWorkerExit(status: Int32, requestURL: URL, logURL: URL) {
        let previous = workerEvents
        workerEvents = Task { await previous?.value; await finish(status: status, requestURL: requestURL, logURL: logURL) }
    }
    private func handle(_ event: WorkerEvent, request: WorkerRequest) async {
        guard event.jobID == activeJobID, let recording = recordings.first(where: { $0.id == request.recordingID }) else { return }
        do {
            let activated = try await store?.perform { try $0.ingestWorker(event, request: request) }
            if activated == false { notice = "新转写已存为历史版本，当前人工纠错版本保持不变。" }
            if event.kind == "stage" {
                if let message = event.message { phaseMessage = message; progress = nil }
                if let value = event.progress { progress = value }
            }
            await reload()
        } catch {
            alert = "保存处理结果失败：\(error.localizedDescription)"; await cancel(recording.id)
        }
    }
    private func finish(status: Int32, requestURL: URL, logURL: URL) async {
        if let id = activeRecordingID, var recording = recordings.first(where: { $0.id == id }), recording.state.isRunning || recording.state == .queued {
            recording.state = cancelledJob ? .cancelled : .failed
            recording.error = cancelledJob ? nil : "后台任务意外退出（\(status)），可重试。"
            await save(recording)
        }
        try? logHandle?.close(); logHandle = nil
        try? FileManager.default.removeItem(at: requestURL); try? FileManager.default.removeItem(at: logURL)
        worker = nil; request = nil; activeJobID = nil; activeRecordingID = nil; progress = nil; phaseMessage = ""
        await startNext()
    }
    func cancelAudioTask(recordingID: String, taskID: String) async -> Bool {
        guard (activeRecordingID == recordingID && activeJobID == taskID) || queue.contains(where: { $0.recordingID == recordingID && $0.request.jobID == taskID }) else { return false }
        await cancel(recordingID); return true
    }
    func cancel(_ id: String) async {
        cancelledEnqueues.insert(id)
        if activeRecordingID == id { cancelledJob = true; worker?.terminate(); phaseMessage = "正在取消并清理临时文件…" }
        for queued in queue where queued.recordingID == id { try? await store?.perform { try $0.stopWorker(queued.request.jobID, state: "cancelled") } }
        queue.removeAll { $0.recordingID == id }
        if activeRecordingID == id { if let job = activeJobID { try? await store?.perform { try $0.stopWorker(job, state: "cancelled") } }; cancelledJob = true; worker?.terminate(); phaseMessage = "正在取消并清理临时文件…" }
        if var recording = recordings.first(where: { $0.id == id }) { recording.state = .cancelled; recording.error = nil; await save(recording) }
    }
    func changeSpeakerCount(_ count: Int?) async { guard var r = selected else { return }; r.speakerCount = count; await save(r) }
    func switchRun(_ id: String) async { guard var r = selected else { return }; r.activeRun = id; await save(r) }
    func setSmartPunctuation(_ value: Bool) async { smartPunctuation = value; savePreferences(); await preparePunctuation(); refreshSearch() }
    func refreshPunctuation() async { await preparePunctuation() }
    private func preparePunctuation() async {
        punctuationTask?.cancel(); punctuationProcessor.cancel(); punctuationBusy = false; readingOverrides = [:]; punctuationMessage = ""
        guard smartPunctuation, let run = selected?.activeRun, let store else { return }
        let cache = (try? await store.perform { try $0.readingCache(runID: run) }) ?? [:]
        guard selected?.activeRun == run, self.store === store else { return }
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
                        try await store.perform { try $0.saveReadingCache(runID: run, key: PunctuationProjection.key(group.segments), rendered: result) }
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
    func undoEdit(redo: Bool = false) async {
        guard let run = selected?.activeRun else { return }
        do { if try await store?.perform({ try $0.restoreEdit(runID: run, redo: redo) }) == true { await loadTranscript(); refreshSearch() } }
        catch { alert = error.localizedDescription }
    }
    func markReviewed(_ ids: [String], reviewed: Bool = true) async {
        do { try await store?.perform { try $0.markReviewed(segmentIDs: ids, reviewed: reviewed) }; await loadTranscript() } catch { alert = error.localizedDescription }
    }
    func mergeSpeakers(_ sources: Set<Int>, into target: Int) async {
        guard let run = selected?.activeRun else { return }
        do { try await store?.perform { try $0.mergeSpeakers(runID: run, sources: sources, target: target) }; await loadTranscript(); refreshSearch(); notice = "已合并说话人，可通过撤销恢复。" }
        catch { alert = error.localizedDescription }
    }
    func setBulkSpeaker(_ speaker: Int?) async {
        let ids = Array(bulkSelection)
        do { try await store?.perform { try $0.editSpeakers(segmentIDs: ids, speaker: speaker) }; await loadTranscript(); refreshSearch(); bulkSelection = [] }
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
    @discardableResult func saveCorrection(_ id: String, text: String?, reviewed: Bool) async -> Bool {
        do { guard let store else { throw BackendClientError.unavailable }; try await store.perform { try $0.saveCorrection(segmentID: id, text: text, markReviewed: reviewed) }; await loadTranscript(); refreshSearch(); return true }
        catch { alert = error.localizedDescription; return false }
    }
    func editText(_ id: String, text: String) async {
        do { try await store?.perform { try $0.editText(segmentID: id, text: text) }; await loadTranscript(); refreshSearch() } catch { alert = error.localizedDescription }
    }
    @discardableResult func editTexts(_ edits: [String: String]) async -> Bool {
        do { guard let store else { throw BackendClientError.unavailable }; try await store.perform { try $0.editTexts(edits) }; await loadTranscript(); refreshSearch(); return true } catch { alert = error.localizedDescription; return false }
    }
    func editUtteranceSpeaker(_ utterance: SpeechUtterance, speaker: Int?) async {
        do {
            try await store?.perform { try $0.editSpeakers(segmentIDs: utterance.segments.map(\.id), speaker: speaker) }
            await loadTranscript(); refreshSearch()
        } catch { alert = error.localizedDescription }
    }
    @discardableResult func renameRecording(_ id: String, name: String) async -> Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var recording = recordings.first(where: { $0.id == id }) else { return false }
        recording.title = title
        do { guard let store else { throw BackendClientError.unavailable }; try await store.perform { try $0.save(recording) }; await reload(); notice = "名称已保存，可在修改记录中查看与撤销。"; return true }
        catch { alert = error.localizedDescription; return false }
    }
    func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func setReaderFontSize(_ size: Double) { readerFontSize = min(22, max(14, size)); savePreferences() }
    func setPreRoll(_ seconds: Double) { preRoll = min(2, max(0, seconds)); savePreferences() }
    func setReadingPunctuation(_ value: Bool) async { readingPunctuation = value; savePreferences(); await preparePunctuation(); refreshSearch() }
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
    func editSpeaker(_ id: String, speaker: Int?) async {
        do { try await store?.perform { try $0.editSpeaker(segmentID: id, speaker: speaker) }; await loadTranscript(); refreshSearch() } catch { alert = error.localizedDescription }
    }
    func renameSpeaker(_ id: Int, name: String) async {
        guard let run = selected?.activeRun else { return }
        do { try await store?.perform { try $0.renameSpeaker(runID: run, speaker: id, name: name) }; await loadTranscript(); refreshSearch() } catch { alert = error.localizedDescription }
    }
    func speakerName(_ id: Int?) -> String { id.flatMap { names[$0] } ?? SpeakerMatcher.defaultName(id) }
    func refreshSearch() {
        searchTask?.cancel()
        let key = searchText + "\u{0}" + (searchAll ? "all" : selectedID ?? "")
        if searchQueryKey != key { hits = []; activeHitID = nil; searchQueryKey = key }
        searchOffset = 0; searchHasMore = false
        if !searchText.isEmpty && !searchSession {
            searchOrigin = SearchOrigin(recordingID: selectedID, position: player.position, focusedID: focusSegmentID, playing: player.playing)
            hasSearchOrigin = searchOrigin?.recordingID != nil; searchSession = true
        }
        guard !searchText.isEmpty else { hits = []; activeHitID = nil; searchSession = false; searchLoading = false; return }
        let term = searchText, recording = searchAll ? nil : selectedID ?? ""
        let punctuate = readingPunctuation, breaks = readingParagraphBreaks, density = readingDensity, smart = smartPunctuation
        searchLoading = true
        searchTask = Task {
            defer { if searchQueryKey == key { searchLoading = false } }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            do {
                guard let store else { throw BackendClientError.unavailable }
                let result = try await store.perform { store in
                    var page = try store.searchPage(term, recordingID: recording, punctuate: punctuate, paragraphBreaks: breaks, density: density, smartPunctuation: smart)
                    while page.hits.isEmpty && page.hasMore {
                        page = try store.searchPage(term, recordingID: recording, offset: page.nextOffset, punctuate: punctuate, paragraphBreaks: breaks, density: density, smartPunctuation: smart)
                    }
                    return page
                }
                guard !Task.isCancelled, searchQueryKey == key else { return }
                hits = result.hits; searchOffset = result.nextOffset; searchHasMore = result.hasMore
            } catch is CancellationError { }
            catch { alert = error.localizedDescription }
        }
    }
    func loadMoreSearch() async {
        guard searchHasMore, !searchLoading, let store else { return }
        let key = searchQueryKey, term = searchText, recording = searchAll ? nil : selectedID ?? "", offset = searchOffset
        let punctuate = readingPunctuation, breaks = readingParagraphBreaks, density = readingDensity, smart = smartPunctuation
        searchLoading = true; defer { if searchQueryKey == key { searchLoading = false } }
        do {
            let page = try await store.perform { try $0.searchPage(term, recordingID: recording, offset: offset, punctuate: punctuate, paragraphBreaks: breaks, density: density, smartPunctuation: smart) }
            guard searchQueryKey == key else { return }
            let existing = Set(hits.map(\.id)); hits += page.hits.filter { !existing.contains($0.id) }
            searchOffset = page.nextOffset; searchHasMore = page.hasMore
        } catch { if searchQueryKey == key { alert = error.localizedDescription } }
    }
    func openHit(_ hit: SearchHit) async {
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
    func locateCurrentSentence() { reviewFilter = .all; focusSegmentID = currentSegmentID; focusRequestID = UUID() }
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
            await save(updated); await select(recording.id)
            notice = "已重新定位原音频，转写和纠错均已保留。"
        } catch { alert = error.localizedDescription }
    }
    func remove(_ id: String) async {
        guard activeRecordingID != id else { alert = "请先取消当前任务，等待清理完成后再移除。"; return }
        queue.removeAll { $0.recordingID == id }
        do {
            try await store?.perform { try $0.remove(id) }
            if selectedID == id { player.unload(); selectedID = nil }
            await reload(); if selectedID == nil, let first = recordings.first { Task { await select(first.id) } }
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
    func shutdown() async {
        shuttingDown = true; backendGeneration = UUID()
        if let job = activeJobID { try? await store?.perform { try $0.stopWorker(job, state: "interrupted") } }
        await savePosition(); installer.cancel(); punctuationTask?.cancel(); punctuationProcessor.cancel()
        for job in queue {
            if var r = recordings.first(where: { $0.id == job.recordingID }) { r.state = .interrupted; try? await store?.perform { try $0.save(r) } }
        }
        queue = []
        if let id = activeRecordingID, var r = recordings.first(where: { $0.id == id }) { r.state = .interrupted; try? await store?.perform { try $0.save(r) } }
        cancelledJob = true; worker?.terminate(); player.pause()
        await assistant.flushDrafts(); assistant.stop(); deviceBridge?.stop(); deviceBridge = nil; store = nil; backendProcess.stop()
    }
}
