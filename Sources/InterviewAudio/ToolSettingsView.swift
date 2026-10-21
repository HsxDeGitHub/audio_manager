import SwiftUI
import Foundation

struct ToolEntry: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String
    let effect: String
    let enabled: Bool
    var effectTitle: String {
        ["read": "读取", "write": "业务修改", "device": "设备操作", "external": "外部操作"][effect] ?? effect
    }
}

private struct ToolPage: Decodable { let items: [ToolEntry] }

struct MCPConnectionInfo: Decodable, Identifiable {
    let id: String
    let transport: String
    let command: String?
    let args: [String]
    let url: String?
    let credentialEnv: String?
    let enabled: Bool
    let connected: Bool
    let error: String?
    let tools: Int
    private enum CodingKeys: String, CodingKey {
        case id, transport, command, args, url, enabled, connected, error, tools
        case credentialEnv = "credential_env"
    }
}

private struct MCPPage: Decodable { let items: [MCPConnectionInfo] }

@MainActor
final class ToolSettingsModel: ObservableObject {
    @Published var tools: [ToolEntry] = []
    @Published var connections: [MCPConnectionInfo] = []
    @Published var loading = false
    @Published var busy = false
    @Published var error: String?
    private let client: BackendClient

    init(client: BackendClient) { self.client = client }

    func load() async {
        loading = true; defer { loading = false }
        do {
            let page: ToolPage = try await client.send("/api/v1/tools?include_disabled=true")
            tools = page.items
            let mcp: MCPPage = try await client.send("/api/v1/mcp/connections")
            connections = mcp.items
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func toggle(_ tool: ToolEntry) async {
        busy = true; defer { busy = false }
        do {
            struct Receipt: Decodable { let id: String; let enabled: Bool }
            let _: Receipt = try await client.send("/api/v1/tools/\(tool.id)/enabled", method: "POST",
                body: try JSONSerialization.data(withJSONObject: ["enabled": !tool.enabled]))
            await load()
        } catch { self.error = error.localizedDescription; await load() }
    }

    func save(id: String, transport: String, command: String, args: [String], url: String,
              credentialEnv: String, enabled: Bool) async {
        busy = true; defer { busy = false }
        do {
            var body: [String: Any] = ["id": id, "transport": transport, "args": args, "environment": [:], "enabled": enabled]
            if transport == "stdio" { body["command"] = command } else { body["url"] = url }
            if !credentialEnv.isEmpty { body["credential_env"] = credentialEnv }
            let _: MCPPage = try await client.send("/api/v1/mcp/connections", method: "POST",
                                                    body: try JSONSerialization.data(withJSONObject: body))
            await load()
        } catch { self.error = error.localizedDescription }
    }

    func refresh(_ id: String) async {
        busy = true; defer { busy = false }
        do {
            let _: MCPPage = try await client.send("/api/v1/mcp/connections/\(id)/refresh", method: "POST")
            await load()
        } catch { self.error = error.localizedDescription; await load() }
    }

    func refreshAll() async {
        busy = true; defer { busy = false }
        do {
            let _: MCPPage = try await client.send("/api/v1/mcp/refresh", method: "POST")
            await load()
        } catch { self.error = error.localizedDescription; await load() }
    }

    func remove(_ id: String) async {
        busy = true; defer { busy = false }
        do {
            let _: MCPPage = try await client.send("/api/v1/mcp/connections/\(id)", method: "DELETE")
            await load()
        } catch { self.error = error.localizedDescription; await load() }
    }
}

struct ToolSettingsView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: ToolSettingsModel
    @UIState private var id = ""
    @UIState private var transport = "stdio"
    @UIState private var command = ""
    @UIState private var arguments = ""
    @UIState private var url = ""
    @UIState private var credentialEnv = ""
    @UIState private var enabled = true
    @UIState private var deleting: MCPConnectionInfo?
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, client: BackendClient) {
        self.app = app
        _model = StateObject(wrappedValue: ToolSettingsModel(client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "wrench.and.screwdriver").font(.title).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("工具与 MCP").font(.title2.weight(.semibold))
                    Text("同一业务能力在原生、助手和 MCP 三个入口共用参数、结果与业务规则。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新全部") { Task { await model.refreshAll() } }.disabled(model.busy)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    toolSection(model)
                    Divider()
                    connectionSection(model)
                }.padding(.trailing, 6)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("凭据只填写环境变量名，不在这里保存密钥。外部工具的只读或幂等声明仅作提示。")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(minWidth: 760, minHeight: 600)
        .task { await model.load() }
        .confirmationDialog("删除这个外部 MCP 连接？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除连接", role: .destructive) {
                if let item = deleting { Task { await model.remove(item.id) } }
                deleting = nil
            }
        }
    }

    private func toolSection(_ model: ToolSettingsModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工具目录").font(.headline)
            Text("停用后不进入模型可见目录，直接调用也会被拒绝。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.tools) { tool in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(tool.title).font(.system(size: 13, weight: .medium))
                            Text(tool.effectTitle).font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(tool.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { tool.enabled }, set: { _ in Task { await model.toggle(tool) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(model.busy)
                }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.tools.isEmpty && !model.loading { Text("没有工具目录。").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func connectionSection(_ model: ToolSettingsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("外部 MCP 连接").font(.headline)
            Text("未配置时不启动外部进程。工具按服务器命名空间暴露，连接失败会从当前目录移除。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.connections) { connection in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: connection.connected ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(connection.connected ? accent : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(connection.id).font(.system(size: 13, weight: .medium))
                            Text(connection.transport).font(.caption2).foregroundStyle(.secondary)
                            Text(connection.enabled ? "已启用" : "已停用").font(.caption2).foregroundStyle(.secondary)
                            if connection.connected { Text("\(connection.tools) 个工具").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(connection.transport == "stdio" ? (connection.command ?? "") + " " + connection.args.joined(separator: " ") : (connection.url ?? ""))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        if let error = connection.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    Button("编辑") { loadForm(connection) }.font(.caption)
                    Button("重连") { Task { await model.refresh(connection.id) } }.font(.caption).disabled(model.busy)
                    Button("删除…", role: .destructive) { deleting = connection }.font(.caption).disabled(model.busy)
                }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("新增 / 编辑连接").font(.caption.weight(.semibold)).padding(.top, 4)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("标识").font(.caption); TextField("小写服务器标识", text: $id).textFieldStyle(.roundedBorder) }
                GridRow {
                    Text("传输").font(.caption)
                    Picker("传输", selection: $transport) {
                        Text("stdio").tag("stdio"); Text("Streamable HTTP").tag("streamable_http")
                    }.labelsHidden().frame(width: 180)
                }
                if transport == "stdio" {
                    GridRow { Text("命令").font(.caption); TextField("可执行文件路径", text: $command).textFieldStyle(.roundedBorder) }
                    GridRow { Text("参数").font(.caption); TextField("以空格分隔", text: $arguments).textFieldStyle(.roundedBorder) }
                } else {
                    GridRow { Text("地址").font(.caption); TextField("http://127.0.0.1:…", text: $url).textFieldStyle(.roundedBorder) }
                }
                GridRow { Text("凭据变量").font(.caption); TextField("可选，如 MCP_TOKEN", text: $credentialEnv).textFieldStyle(.roundedBorder) }
                GridRow {
                    Text("启用").font(.caption)
                    Toggle("连接外部服务器", isOn: $enabled).labelsHidden()
                }
            }
            HStack {
                Text("保存后会立即尝试连接；失败不会注册任何工具，也不会影响本地助手。")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("清空") { loadForm(nil) }.font(.caption)
                Button("保存并连接") { Task { await save(model) } }
                    .buttonStyle(.borderedProminent).disabled(model.busy || id.isEmpty)
            }
        }
    }

    private func loadForm(_ connection: MCPConnectionInfo?) {
        id = connection?.id ?? ""; transport = connection?.transport ?? "stdio"
        command = connection?.command ?? ""; arguments = connection?.args.joined(separator: " ") ?? ""
        url = connection?.url ?? ""; credentialEnv = connection?.credentialEnv ?? ""; enabled = connection?.enabled ?? true
    }

    private func save(_ model: ToolSettingsModel) async {
        await model.save(id: id, transport: transport, command: command,
                         args: arguments.split(separator: " ").map(String.init),
                         url: url, credentialEnv: credentialEnv, enabled: enabled)
        await model.load()
    }
}
