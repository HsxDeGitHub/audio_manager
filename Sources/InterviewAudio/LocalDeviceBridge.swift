import Foundation
import AppKit
import UniformTypeIdentifiers
import AudioCore

extension BackendLibraryStore {
    func queueWorker(_ request: WorkerRequest) throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        _ = try self.request("/api/v1/jobs/queue", method: "POST", body: body)
    }
    func startWorker(_ request: WorkerRequest) throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        _ = try self.request("/api/v1/jobs/start", method: "POST", body: body)
    }
    func ingestWorker(_ event: WorkerEvent, request: WorkerRequest) throws -> Bool? {
        let eventObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
        let requestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let response = try self.request("/api/v1/jobs/event", method: "POST", body: ["event": eventObject, "request": requestObject])
        return (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["activated"] as? Bool
    }
    func stopWorker(_ id: String, state: String) throws { _ = try request("/api/v1/jobs/\(id)/stop", method: "POST", body: ["state": state]) }
}

// 设备命令由后端登记；此桥接只在用户可见的界面中执行并回报真实结果。
struct DeviceCommand: Decodable, Identifiable {
    let id: String
    let runID: String?
    let kind: String
    let target: String
    let arguments: [String: BackendJSONValue]
    let state: String
    let owner: String?
    let result: [String: BackendJSONValue]?
    private enum CodingKeys: String, CodingKey { case id, kind, target, arguments, state, owner, result, runID = "run_id" }
}

private struct DeviceCommandPage: Decodable { let items: [DeviceCommand] }
struct DeviceAcknowledgment: Decodable { let id: String; let state: String? }

private enum DeviceBridgeError: Error {
    case cancelled
    case failed(String)
}

extension BackendClient {
    func validateDeviceCommand(_ id: String) async throws {
        let _: DeviceAcknowledgment = try await send("/api/v1/device/commands/\(id)/validate")
    }
}

extension BackendJSONValue {
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var doubleValue: Double? {
        switch self { case .number(let value): return value; case .integer(let value): return Double(value); default: return nil }
    }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var arrayValue: [BackendJSONValue]? { if case .array(let value) = self { return value }; return nil }
    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues { $0.anyValue }
        case .null: return NSNull()
        }
    }
}

@MainActor
final class DeviceBridge {
    private let client: BackendClient
    private weak var app: AppModel?
    private let journal: DeviceReceiptJournal
    private var owner: String { journal.owner }
    private var connected = false
    private var polling: Task<Void, Never>?

    init(app: AppModel, client: BackendClient, journal: DeviceReceiptJournal) { self.app = app; self.client = client; self.journal = journal }

    func start() {
        stop()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    func stop() { polling?.cancel(); polling = nil }

    private func poll() async {
        if !connected {
            do {
                let _: DeviceAcknowledgment = try await client.send("/api/v1/device/reconnect", method: "POST", body: JSONSerialization.data(withJSONObject: ["owner": owner]))
                connected = true
            } catch { return }
        }
        guard await journal.flush(client) else { app?.notice = "设备结果等待确认：\(journal.lastError ?? "请重试连接")"; return }
        guard let page: DeviceCommandPage = try? await client.send("/api/v1/device/commands") else { return }
        for command in page.items where command.state == "pending" {
            await handle(command)
        }
    }

    private func handle(_ command: DeviceCommand) async {
        let claimed: DeviceCommand
        do {
            claimed = try await client.send("/api/v1/device/commands/\(command.id)/claim", method: "POST",
                                            body: try JSONSerialization.data(withJSONObject: ["owner": owner]))
        } catch { return }
        do { try journal.begin(claimed.id) }
        catch {
            try? journal.finish(claimed.id, status: "failed", result: ["message": "无法保存设备执行记录，操作未开始。"])
            _ = await journal.flush(client); return
        }
        let execution = Task { await execute(claimed) }
        let watcher = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    let current: DeviceCommand = try await client.send("/api/v1/device/commands/\(claimed.id)")
                    if current.result?["cancel_requested"]?.boolValue == true { execution.cancel(); return }
                } catch { return }
            }
        }
        let (state, result) = await withTaskCancellationHandler(operation: { await execution.value }, onCancel: { execution.cancel() })
        watcher.cancel()
        do { try journal.finish(command.id, status: state, result: result) }
        catch { app?.alert = "设备结果保存失败，将保留回执等待重试。" }
        _ = await journal.flush(client)
    }

    private func execute(_ command: DeviceCommand) async -> (String, [String: Any]?) {
        guard let app else { return ("failed", ["message": "应用界面不可用。"]) }
        do {
            try Task.checkCancellation()
            try await client.validateDeviceCommand(command.id)
            switch command.kind {
            case "locate":
                guard let recordingID = command.arguments["recording_id"]?.stringValue else {
                    return ("failed", ["message": "缺少资料标识。"])
                }
                await app.select(recordingID)
                guard app.selectedID == recordingID, let runID = command.arguments["run_id"]?.stringValue,
                      app.runs.contains(where: { $0.id == runID }) else { throw DeviceBridgeError.failed("资料或转写版本不存在。") }
                if app.selected?.activeRun != runID { app.switchRun(runID) }
                guard app.selected?.activeRun == runID else { throw DeviceBridgeError.failed("转写版本切换失败。") }
                var position = command.arguments["start"]?.doubleValue
                if let segmentID = command.arguments["segment_id"]?.stringValue {
                    guard let segment = app.segments.first(where: { $0.id == segmentID }) else { throw DeviceBridgeError.failed("片段已不存在。") }
                    app.reviewFilter = .all; app.focusSegmentID = segmentID; app.focusRequestID = UUID()
                    if position == nil { position = segment.start }
                }
                let play = command.arguments["play"]?.boolValue ?? true
                if !play && !app.player.available { return ("completed", ["located": true, "played": false, "message": "文字已定位，原音频不可用。"]) }
                let actual = try await app.player.seekVerified(max(0, (position ?? app.player.position) - app.preRoll), play: play)
                return ("completed", ["located": true, "played": actual.playing, "position": actual.position, "recording_id": recordingID])

            case "clipboard":
                guard let text = command.arguments["text"]?.stringValue else { return ("failed", ["message": "缺少复制文字。"]) }
                app.copyText(text)
                return ("completed", ["characters": text.count])

            case "choose_file":
                let purpose = command.arguments["purpose"]?.stringValue ?? "选择文件"
                let extensions = command.arguments["extensions"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let url = await chooseOpenFile(purpose: purpose, extensions: extensions)
                guard let url else { return ("cancelled", ["message": "用户取消了文件选择。"]) }
                return ("completed", ["path": url.path, "name": url.lastPathComponent])

            case "export":
                return try await export(command)

            case "transcribe":
                guard let recordingID = command.arguments["recording_id"]?.stringValue else { return ("failed", ["message": "缺少资料标识。"]) }
                let taskID = app.enqueue(recordingID)
                let receipt = try DeviceExecutionResult.started(taskID: taskID, state: app.activeRecordingID == recordingID ? "started" : "queued",
                    statusPath: taskID.map { "/api/v1/jobs/\($0)" } ?? "")
                return ("completed", receipt)

            case "cancel":
                guard let recordingID = command.arguments["recording_id"]?.stringValue,
                      let taskID = command.arguments["task_id"]?.stringValue,
                      let taskType = command.arguments["task_type"]?.stringValue else { throw DeviceBridgeError.failed("缺少固定任务标识。") }
                return ("completed", try await app.cancelDeviceTask(recordingID: recordingID, taskID: taskID, taskType: taskType))

            case "organize":
                return ("failed", ["message": "独立整理稿流程已停用，请让听阅助手直接整理正文。", "retry_safe": false])
            default:
                return ("failed", ["message": "不支持的设备命令。"])
            }
        } catch is CancellationError {
            return ("cancelled", ["message": "运行已取消，设备操作已停止。"])
        } catch DeviceBridgeError.cancelled {
            return ("cancelled", ["message": "用户取消了操作。"])
        } catch DeviceBridgeError.failed(let message) {
            return ("failed", ["message": message, "retry_safe": true])
        } catch let error as AudioError {
            return ("failed", ["message": error.localizedDescription, "retry_safe": true])
        } catch {
            return ("unknown", ["message": "设备结果无法确认，不会自动重放。"])
        }
    }

    private func chooseOpenFile(purpose: String, extensions: [String]) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = purpose
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil); return }
                panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
            }
        }, onCancel: { Task { @MainActor in panel.cancel(nil) } })
    }

    private func chooseSaveFile(name: String, extension ext: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name; panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil); return }
                panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
            }
        }, onCancel: { Task { @MainActor in panel.cancel(nil) } })
    }

    private func allSegments(runID: String) async throws -> [BackendSegment] {
        var items: [BackendSegment] = []
        while true {
            let page = try await client.segments(runID: runID, offset: items.count, limit: 200)
            items += page.items
            if items.count >= page.total || page.items.isEmpty { return items }
        }
    }

    private func allSpeakers(runID: String) async throws -> [BackendSpeaker] {
        var items: [BackendSpeaker] = []
        while true {
            let page = try await client.speakers(runID: runID, offset: items.count, limit: 200)
            items += page.items
            if items.count >= page.total || page.items.isEmpty { return items }
        }
    }

    private func export(_ command: DeviceCommand) async throws -> (String, [String: Any]?) {
        let format = command.arguments["format"]?.stringValue ?? "txt"
        let suggested = command.arguments["suggested_name"]?.stringValue
        if let draftID = command.arguments["draft_id"]?.stringValue {
            guard let runID = command.arguments["run_id"]?.stringValue else {
                throw DeviceBridgeError.failed("导出整理稿需要转写版本标识。")
            }
            var drafts: [BackendDraft] = []
            var offset = 0
            while true {
                let page = try await client.drafts(runID: runID, offset: offset, limit: 200)
                drafts += page.items
                if drafts.count >= page.total || page.items.isEmpty { break }
                offset = drafts.count
            }
            guard let draft = drafts.first(where: { $0.id == draftID }) else {
                throw DeviceBridgeError.failed("整理稿不存在或已变化。")
            }
            let data = try JSONSerialization.data(withJSONObject: draft.payload.mapValues { $0.anyValue })
            let parsed = try JSONDecoder().decode(AIDraft.self, from: data)
            let text = parsed.export(markdown: format == "md")
            let ext = format == "md" ? "md" : "txt"
            guard let url = await chooseSaveFile(name: suggested ?? "\(parsed.recordingTitle)-\(parsed.mode.title).\(ext)", extension: ext) else {
                throw DeviceBridgeError.cancelled
            }
            try Task.checkCancellation()
            try await client.validateDeviceCommand(command.id)
            try Task.checkCancellation()
            try text.write(to: url, atomically: true, encoding: .utf8)
            return ("completed", ["path": url.path, "name": url.lastPathComponent])
        }
        guard let recordingID = command.arguments["recording_id"]?.stringValue else {
            throw DeviceBridgeError.failed("缺少导出资料标识。")
        }
        let recording = try await client.recording(id: recordingID)
        let runID = command.arguments["run_id"]?.stringValue
        guard let runID else { throw DeviceBridgeError.failed("当前资料没有可导出的转写。") }
        let segments = try await allSegments(runID: runID)
        let names = Dictionary(uniqueKeysWithValues: try await allSpeakers(runID: runID).map { ($0.speaker, $0.name) })
        let values = segments.map { TranscriptSegment(id: $0.id, start: $0.start, end: $0.end, original: $0.original,
            edited: $0.edited, speaker: $0.speaker, speakerEdited: $0.speakerEdited,
            needsReview: $0.needsReview, reviewed: $0.reviewed) }
        let text = TranscriptExport.render(title: recording.title, segments: values, names: names, srt: format == "srt")
        let ext = format == "srt" ? "srt" : "txt"
        guard let url = await chooseSaveFile(name: suggested ?? recording.title, extension: ext) else {
            throw DeviceBridgeError.cancelled
        }
        try Task.checkCancellation()
        try await client.validateDeviceCommand(command.id)
        try Task.checkCancellation()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return ("completed", ["path": url.path, "name": url.lastPathComponent])
    }
}


enum DeviceExecutionResult {
    static func started(taskID: String?, state: String, statusPath: String) throws -> [String: Any] {
        guard let taskID, !taskID.isEmpty, !statusPath.isEmpty, ["started", "queued"].contains(state) else {
            throw AudioError.message("处理任务未启动，请检查资源、配置或当前任务状态。")
        }
        return ["state": state, "task_id": taskID, "status_path": statusPath, "message": "任务已登记，尚未完成；请通过任务标识查看进度。"]
    }
}


extension AppModel {
    func cancelDeviceTask(recordingID: String, taskID: String, taskType: String) async throws -> [String: Any] {
        if taskType == "audio", cancelAudioTask(recordingID: recordingID, taskID: taskID) {
            return ["state": "cancelling", "task_id": taskID, "task_type": taskType]
        }
        guard let backendClient else { throw BackendClientError.unavailable }
        struct Status: Decodable { let id: String; let recording_id: String; let state: String }
        let status: Status = try await backendClient.send("/api/v1/device/tasks/\(taskType)/\(taskID)")
        guard status.recording_id == recordingID else { throw BackendClientError.conflict }
        guard !["running", "queued"].contains(status.state) else { throw AudioError.message("该任务不由当前设备持有，未取消其他任务。") }
        return ["state": "already_finished", "task_id": taskID, "task_type": taskType, "task_state": status.state]
    }
}
