import Foundation
import Darwin

struct BackendConnection: Sendable { let baseURL: URL; let token: String }

@MainActor
final class BackendProcess: ObservableObject {
    @Published private(set) var state = "尚未启动本地服务"
    @Published private(set) var diagnostic: String?
    private var child: Process?
    private var lifeline: Pipe?
    private var connection: BackendConnection?

    func start(dataDirectory: URL) async throws -> BackendConnection {
        if let connection, child?.isRunning == true { return connection }
        stop(); state = "正在准备本地资料库…"; diagnostic = nil
        let runtime = dataDirectory.appendingPathComponent("Backend/Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let ready = runtime.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: ready) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundled = (Bundle.main.resourceURL ?? root).appendingPathComponent("Backend/python/bin/python3")
        let interpreter = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : root.appendingPathComponent("backend/.venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: interpreter.path) else {
            state = "本地服务不可用"; diagnostic = "缺少应用内后端运行时，请重新安装完整应用。"
            throw BackendClientError.unavailable
        }
        let token = UUID().uuidString + UUID().uuidString
        let process = Process(), pipe = Pipe()
        process.executableURL = interpreter
        process.arguments = ["-m", "interview_backend", "--data-dir", dataDirectory.path, "serve", "--port", "0", "--ready-file", ready.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        var environment = ProcessInfo.processInfo.environment
        environment["INTERVIEW_AUDIO_BACKEND_TOKEN"] = token
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["LANGCHAIN_TRACING_V2"] = "false"
        environment["LANGSMITH_TRACING"] = "false"
        process.environment = environment
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        child = process; lifeline = pipe
        do {
            try process.run()
            try? pipe.fileHandleForReading.close()
            let deadline = Date().addingTimeInterval(35)
            while process.isRunning && Date() < deadline {
                try Task.checkCancellation()
                if let data = try? Data(contentsOf: ready), let value = try? JSONDecoder().decode([String: String].self, from: data),
                   let raw = value["url"], let url = URL(string: raw) {
                    let client = try BackendClient(baseURL: url, token: token, timeout: 1)
                    if let status = try? await client.status(), status.supports("business_write") {
                        let result = BackendConnection(baseURL: url, token: token)
                        connection = result; state = "本地服务已连接"; return result
                    }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw BackendClientError.unavailable
        } catch {
            stop(); state = "本地服务不可用"
            diagnostic = "服务启动或资料迁移未完成。原资料库保留，请检查运行时、目录权限或其他应用实例，然后重试。"
            throw error
        }
    }

    func stop() {
        connection = nil
        try? lifeline?.fileHandleForWriting.close(); lifeline = nil
        if let process = child, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(-process.processIdentifier, SIGKILL); kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        child = nil; state = "本地服务已停止"
    }
}
