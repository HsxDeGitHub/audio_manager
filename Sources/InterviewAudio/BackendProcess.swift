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
    private var monitor: Task<Void, Never>?
    private var healthProbe: Task<Bool, Never>?
    private var healthFailures = 0
    private let healthConfiguration: URLSessionConfiguration
    init(healthConfiguration: URLSessionConfiguration = .ephemeral) { self.healthConfiguration = healthConfiguration }
    var onUnavailable: ((String) -> Void)?
    var processIdentifier: Int32? { child?.isRunning == true ? child?.processIdentifier : nil }

    private func becameUnavailable(_ message: String) {
        guard connection != nil else { return }
        connection = nil; monitor?.cancel(); monitor = nil
        state = "本地服务不可用"; diagnostic = message
        onUnavailable?(message)
    }

    func verifyConnection() async {
        guard let connection, let process = child else { return }
        guard process.isRunning else { becameUnavailable("本地服务已退出，请重试。未完成任务已保留。"); return }
        // 多个业务请求同时失败时合并探测；单次超时不能使整个工作区下线。
        if let healthProbe { _ = await healthProbe.value; return }
        let probe = Task { () -> Bool in
            do {
                let client = try BackendClient(baseURL: connection.baseURL, token: connection.token, timeout: 8, configuration: healthConfiguration)
                _ = try await client.health(); return true
            } catch { return false }
        }
        healthProbe = probe
        let healthy = await probe.value
        guard child === process, self.connection?.token == connection.token else { return }
        healthProbe = nil
        healthFailures = healthy ? 0 : healthFailures + 1
        if healthFailures >= 3 {
            becameUnavailable("本地服务持续无响应，请重试连接。未完成任务已保留。")
        }
    }

    private func watch(_ process: Process, connection: BackendConnection) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self, self.child === process, self.connection?.token == connection.token else { return }
                    await self.verifyConnection()
                } catch {
                    return
                }
            }
        }
    }

    func start(dataDirectory: URL) async throws -> BackendConnection {
        if let connection, child?.isRunning == true {
            let client = try BackendClient(baseURL: connection.baseURL, token: connection.token, timeout: 8)
            if (try? await client.health()) != nil { return connection }
            becameUnavailable("本地服务连接已失效，正在重新连接。")
        }
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
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.child === process else { return }
                self.becameUnavailable("本地服务意外退出，请重试。已保存资料仍保留在本机。")
            }
        }
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
                        connection = result; state = "本地服务已连接"; watch(process, connection: result); return result
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
        monitor?.cancel(); monitor = nil
        healthProbe?.cancel(); healthProbe = nil; healthFailures = 0
        connection = nil
        try? lifeline?.fileHandleForWriting.close(); lifeline = nil
        if let process = child, process.isRunning {
            // 先让生命线 EOF 触发服务自身收尾；只有超时才升级为信号。
            let graceful = Date().addingTimeInterval(2)
            while process.isRunning && Date() < graceful { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(4)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            }
            if process.isRunning { kill(-process.processIdentifier, SIGKILL); kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        child = nil; state = "本地服务已停止"
    }
}
