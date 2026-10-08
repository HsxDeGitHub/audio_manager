import Foundation
import AudioCore

/// Uses the bundled local CLI only; its output is accepted after lossless alignment.
@MainActor
final class PunctuationProcessor {
    private var child: Process?
    func cancel() { if child?.isRunning == true { child?.terminate() }; child = nil }
    func render(_ segments: [TranscriptSegment], executable: URL, model: URL) async throws -> [String: String]? {
        guard !Task.isCancelled, PunctuationProjection.eligible(segments) else { return nil }
        let process = Process(), pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--print-args=false", "--num-threads=2", "--ct-transformer=" + model.path, JoinedTranscript(segments: segments).text]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        child = process
        defer { if child === process { child = nil } }
        try process.run()
        let output = await Task.detached(priority: .utility) {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (data, process.terminationStatus)
        }.value
        guard !Task.isCancelled else { return nil }
        guard output.1 == 0 else { throw AudioError.message("本地智能标点处理失败，已使用规则标点") }
        return PunctuationProjection.project(String(decoding: output.0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), onto: segments)
    }
}
