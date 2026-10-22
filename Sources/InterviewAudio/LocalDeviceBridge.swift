import Foundation
import AppKit
import UniformTypeIdentifiers
import AudioCore

extension BackendLibraryStore {
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
    private enum CodingKeys: String, CodingKey { case id, kind, target, arguments, state, owner, runID = "run_id" }
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
    private let owner = UUID().uuidString
    private var polling: Task<Void, Never>?

    init(app: AppModel, client: BackendClient) { self.app = app; self.client = client }

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
        let (state, result) = await execute(claimed)
        var body: [String: Any] = ["owner": owner, "state": state]
        if let result { body["result"] = result }
        do {
            let _: DeviceAcknowledgment = try await client.send("/api/v1/device/commands/\(command.id)/result", method: "POST",
                                                                body: try JSONSerialization.data(withJSONObject: body))
        } catch { /* 保留后端状态；下轮查询不会重复领取已结束命令。 */ }
    }

    private func execute(_ command: DeviceCommand) async -> (String, [String: Any]?) {
        guard let app else { return ("failed", ["message": "应用界面不可用。"]) }
        do {
            try await client.validateDeviceCommand(command.id)
            switch command.kind {
            case "locate":
                guard let recordingID = command.arguments["recording_id"]?.stringValue else {
                    return ("failed", ["message": "缺少资料标识。"])
                }
                await app.select(recordingID)
                if let runID = command.arguments["run_id"]?.stringValue, app.selected?.activeRun != runID { app.switchRun(runID) }
                if let segmentID = command.arguments["segment_id"]?.stringValue {
                    app.readerShowsAI = false; app.reviewFilter = .all
                    app.focusSegmentID = segmentID; app.focusRequestID = UUID()
                }
                var position = command.arguments["start"]?.doubleValue
                if position == nil, let segmentID = command.arguments["segment_id"]?.stringValue,
                   let segment = app.segments.first(where: { $0.id == segmentID }) { position = segment.start }
                if let position { app.player.seek(max(0, position - app.preRoll), play: command.arguments["play"]?.boolValue ?? true) }
                else if command.arguments["play"]?.boolValue == true { app.player.seek(app.player.position, play: true) }
                return ("completed", ["recording_id": recordingID,
                                      "segment_id": command.arguments["segment_id"]?.stringValue ?? "",
                                      "position": position ?? app.player.position])

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
                app.enqueue(recordingID)
                return ("completed", ["state": "started", "recording_id": recordingID,
                                      "message": "已加入后台转写队列，完成情况以任务事件为准。"])

            case "cancel":
                guard let recordingID = command.arguments["recording_id"]?.stringValue else { return ("failed", ["message": "缺少资料标识。"]) }
                app.cancel(recordingID)
                return ("completed", ["state": "cancelling", "recording_id": recordingID])

            case "organize":
                guard let recordingID = command.arguments["recording_id"]?.stringValue,
                      let rawMode = command.arguments["mode"]?.stringValue,
                      let mode = AIOrganizationMode(rawValue: rawMode) else { return ("failed", ["message": "整理参数不正确。"]) }
                if app.aiActiveDraftID != nil { return ("failed", ["message": "已有整理任务在进行。"]) }
                await app.select(recordingID)
                if let runID = command.arguments["run_id"]?.stringValue, app.selected?.activeRun != runID { app.switchRun(runID) }
                let instructions = command.arguments["instructions"]?.stringValue ?? ""
                app.startAI(mode: mode, instructions: instructions)
                return ("completed", ["state": "started", "recording_id": recordingID,
                                      "message": "已开始整理，已完成的分块会持续保存。"])
            default:
                return ("failed", ["message": "不支持的设备命令。"])
            }
        } catch DeviceBridgeError.cancelled {
            return ("cancelled", ["message": "用户取消了操作。"])
        } catch DeviceBridgeError.failed(let message) {
            return ("failed", ["message": message])
        } catch {
            return ("failed", ["message": "设备操作失败，未修改内容。"])
        }
    }

    private func chooseOpenFile(purpose: String, extensions: [String]) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.message = purpose
            let types = extensions.compactMap { UTType(filenameExtension: $0) }
            if !types.isEmpty { panel.allowedContentTypes = types }
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }

    private func chooseSaveFile(name: String, extension ext: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.isExtensionHidden = false
            if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
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
            try await client.validateDeviceCommand(command.id)
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
        try await client.validateDeviceCommand(command.id)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return ("completed", ["path": url.path, "name": url.lastPathComponent])
    }
}
