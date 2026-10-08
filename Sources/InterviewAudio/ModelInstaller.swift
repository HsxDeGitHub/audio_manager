import Foundation
import AppKit
import AudioCore

struct ModelSpec: Identifiable {
    let id: String
    let title: String
    let url: String
    let sha256: String
    let size: Int64
    let archive: Bool
    static let all = [
        ModelSpec(id: "ggml-large-v3.bin", title: "Whisper large-v3 · 中文转写", url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin", sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2", size: 3095033483, archive: false),
        ModelSpec(id: "ggml-silero-v6.2.0.bin", title: "Silero VAD · 过滤非语音片段", url: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin", sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987", size: 885000, archive: false),
        ModelSpec(id: "segmentation.onnx", title: "语音分段模型 · 说话人区分", url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2", sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079", size: 6958545, archive: true),
        ModelSpec(id: "3dspeaker.onnx", title: "中文声纹模型 · 说话人区分", url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx", sha256: "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b", size: 39900000, archive: false)
    ]
}

@MainActor
final class ModelInstaller: ObservableObject {
    @Published var valid: Set<String> = []
    @Published var busy = false
    @Published var message = ""
    @Published var progress: Double?
    @Published var error: String?
    private var process: Process?
    private var cancelled = false
    var ready: Bool { !busy && valid.count == ModelSpec.all.count }

    func validate(directory: URL) async {
        guard !busy else { return }
        busy = true; valid = []; message = "正在校验本地模型…"; error = nil
        var result: Set<String> = []
        for spec in ModelSpec.all {
            let file = directory.appendingPathComponent(spec.id)
            let hash = await Task.detached(priority: .utility) { try? FileFingerprint.sha256(file) }.value
            if hash == spec.sha256 { result.insert(spec.id) }
        }
        valid = result; busy = false; message = ready ? "模型已就绪，可以离线处理" : "首次使用需要下载或导入模型"
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("interview-model-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log); process = nil }
        child.standardError = handle; child.standardOutput = FileHandle.nullDevice; child.standardInput = FileHandle.nullDevice
        process = child
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            child.terminationHandler = { value in continuation.resume(returning: value.terminationStatus) }
            do { try child.run() } catch { child.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        if cancelled { throw AudioError.message("模型下载已取消，可稍后继续") }
        if status != 0 {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw AudioError.message("下载或解压失败：\(detail.suffix(1200))")
        }
    }

    func download(directory: URL) async {
        guard !busy else { return }
        busy = true; cancelled = false; error = nil
        defer { busy = false; progress = nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for spec in ModelSpec.all where !valid.contains(spec.id) {
                if cancelled { throw AudioError.message("模型下载已取消") }
                message = "下载 \(spec.title)"
                let partial = directory.appendingPathComponent(spec.id + ".download")
                let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    Task { @MainActor in self?.progress = min(0.99, Double(size) / Double(spec.size)) }
                }
                do { try await run("/usr/bin/curl", ["--http1.1", "-L", "--fail", "--retry", "3", "--retry-all-errors", "--connect-timeout", "30", "--continue-at", "-", "-o", partial.path, spec.url]) }
                catch { timer.invalidate(); throw error }
                timer.invalidate(); progress = nil
                var candidate = partial
                var staging: URL?
                if spec.archive {
                    let folder = directory.appendingPathComponent("extract-\(UUID().uuidString)")
                    staging = folder; try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    do { try await run("/usr/bin/tar", ["-xjf", partial.path, "-C", folder.path]) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                    candidate = folder.appendingPathComponent("sherpa-onnx-pyannote-segmentation-3-0/model.onnx")
                }
                defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
                message = "校验 \(spec.title)"
                let file = candidate
                let hash = try await Task.detached(priority: .utility) { try FileFingerprint.sha256(file) }.value
                guard hash == spec.sha256 else {
                    try? FileManager.default.removeItem(at: partial)
                    throw AudioError.message("模型校验不通过，请重新下载：\(spec.title)")
                }
                if cancelled { throw AudioError.message("模型下载已取消") }
                let target = directory.appendingPathComponent(spec.id)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: candidate, to: target)
                if spec.archive { try? FileManager.default.removeItem(at: partial) }
                valid.insert(spec.id)
            }
            message = "模型已就绪，可以离线处理"
        } catch { self.error = error.localizedDescription; message = "模型准备未完成" }
    }
    func cancel() { cancelled = true; process?.terminate() }

    func importFile(spec: ModelSpec, directory: URL) async {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择 \(spec.title) 文件。语音分段模型应选择 model.onnx。"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        busy = true; message = "正在校验导入的模型…"; error = nil
        defer { busy = false }
        do {
            let hash = try await Task.detached(priority: .utility) { try FileFingerprint.sha256(source) }.value
            guard hash == spec.sha256 else { throw AudioError.message("这个文件不是当前方案使用的模型，或下载不完整。请选择官方的 \(spec.title)。") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(spec.id)
            if source.standardizedFileURL != target.standardizedFileURL {
                let staged = directory.appendingPathComponent(UUID().uuidString + ".import")
                try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: source, to: staged) }.value
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: staged, to: target)
            }
            valid.insert(spec.id); message = ready ? "模型已就绪，可以离线处理" : "模型已导入"
        } catch { self.error = error.localizedDescription }
    }
}
