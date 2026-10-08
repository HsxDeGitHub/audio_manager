import Foundation
import AudioCore
import Darwin

final class ProcessRunner {
    private let lock = NSLock()
    private var active: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let process = active; lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw AudioError.message("任务已取消") }
    }
    func run(_ executable: URL, _ arguments: [String], progress: ((String) -> Void)? = nil) throws -> String {
        try checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AudioError.message("运行工具缺失：\(executable.lastPathComponent)。请重新构建应用。")
        }
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = stdout; process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw AudioError.message("任务已取消") }
        active = process
        do { try process.run() } catch { active = nil; lock.unlock(); throw error }
        lock.unlock()
        let group = DispatchGroup(), outputLock = NSLock()
        var output = Data(), diagnostic = Data()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            group.enter()
            DispatchQueue.global().async {
                var pending = ""
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    outputLock.lock()
                    if isError { diagnostic.append(data); if diagnostic.count > 32768 { diagnostic = diagnostic.suffix(32768) } }
                    else { output.append(data); if output.count > 4 * 1024 * 1024 { output = output.suffix(4 * 1024 * 1024) } }
                    outputLock.unlock()
                    if isError, let progress {
                        pending += String(decoding: data, as: UTF8.self)
                        while let end = pending.firstIndex(of: "\n") {
                            progress(String(pending[..<end])); pending.removeSubrange(...end)
                        }
                        if pending.count > 4096 { pending = String(pending.suffix(4096)) }
                    }
                }
                group.leave()
            }
        }
        process.waitUntilExit(); group.wait()
        lock.lock(); active = nil; lock.unlock()
        try checkCancellation()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: diagnostic.suffix(2500), as: UTF8.self)
            throw AudioError.message("\(executable.lastPathComponent) 处理失败（\(process.terminationStatus)）：\n\(detail)")
        }
        return String(decoding: output, as: UTF8.self) + "\n" + String(decoding: diagnostic, as: UTF8.self)
    }
}

final class EventWriter {
    let jobID: String
    private let lock = NSLock()
    init(_ jobID: String) { self.jobID = jobID }
    func emit(_ event: WorkerEvent) {
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(10); lock.lock(); FileHandle.standardOutput.write(data); lock.unlock()
    }
    func stage(_ state: TaskState, message: String? = nil, progress: Double? = nil) {
        emit(WorkerEvent(jobID: jobID, kind: "stage", state: state, progress: progress, message: message))
    }
}

@main
enum WorkerMain {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("用法：AudioWorker request.json\n".utf8)); exit(2)
        }
        let runner = ProcessRunner()
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { runner.cancel() }; source.resume(); return source
        }
        defer { for source in signals { source.cancel() } }
        var writer: EventWriter?
        do {
            let request = try JSONDecoder().decode(WorkerRequest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let events = EventWriter(request.jobID); writer = events
            let workspace = URL(fileURLWithPath: request.temporaryDirectory).appendingPathComponent(request.jobID, isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            let tools = URL(fileURLWithPath: request.toolsDirectory), models = URL(fileURLWithPath: request.modelsDirectory)
            let source = URL(fileURLWithPath: request.source), wave = workspace.appendingPathComponent("audio.wav")
            events.stage(.preprocessing, message: "验证原文件并转换音频")
            try FileFingerprint.verify(source, expected: request.fingerprint)
            try runner.checkCancellation()
            var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
            if let start = request.excerptStart { arguments += ["-ss", String(start)] }
            arguments += ["-i", source.path]
            if let duration = request.excerptDuration { arguments += ["-t", String(duration)] }
            arguments += ["-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wave.path]
            _ = try runner.run(tools.appendingPathComponent("ffmpeg"), arguments)
            let offset = request.excerptStart ?? 0
            if !request.speakersOnly {
                events.stage(.transcribing, message: "Whisper 在本机识别中文")
                let result = workspace.appendingPathComponent("transcript")
                _ = try runner.run(tools.appendingPathComponent("whisper-cli"), [
                    "-m", models.appendingPathComponent("ggml-large-v3.bin").path,
                    "-f", wave.path, "-l", "zh", "-oj", "-of", result.path, "-pp", "-t", "6",
                    "--vad", "-vm", models.appendingPathComponent("ggml-silero-v6.2.0.bin").path,
                    "-vsd", "500", "-vp", "150"
                ]) { line in
                    if line.contains("progress ="), let percent = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""), let number = Double(percent) {
                        events.stage(.transcribing, progress: min(1, max(0, number / 100)))
                    }
                }
                let segments = try BackendParser.whisperJSON(Data(contentsOf: result.appendingPathExtension("json")), offset: offset)
                guard !segments.isEmpty else { throw AudioError.message("未识别到可转写语音，请检查音频内容。") }
                events.emit(WorkerEvent(jobID: request.jobID, kind: "transcript", segments: segments, duration: segments.map(\.end).max()))
                try runner.checkCancellation()
            }
            events.stage(.diarizing, message: "本地区分说话人，文字已保存")
            var diarizationArguments = [
                "--segmentation.pyannote-model=\(models.appendingPathComponent("segmentation.onnx").path)",
                "--embedding.model=\(models.appendingPathComponent("3dspeaker.onnx").path)",
                "--segmentation.num-threads=4", "--embedding.num-threads=4",
                "--segmentation.pyannote-window-shift-ratio=0.5"
            ]
            if let count = request.speakerCount { diarizationArguments.append("--clustering.num-clusters=\(count)") }
            else { diarizationArguments.append("--clustering.cluster-threshold=0.8") }
            diarizationArguments.append(wave.path)
            let text = try runner.run(tools.appendingPathComponent("sherpa/bin/sherpa-onnx-offline-speaker-diarization"), diarizationArguments)
            let turns = try BackendParser.speakerOutput(text, offset: offset)
            events.emit(WorkerEvent(jobID: request.jobID, kind: "diarization", turns: turns))
            events.emit(WorkerEvent(jobID: request.jobID, kind: "done", state: .completed))
        } catch {
            writer?.emit(WorkerEvent(jobID: writer!.jobID, kind: "error", state: .failed, message: error.localizedDescription))
            if writer == nil { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)) }
            exit(1)
        }
    }
}
