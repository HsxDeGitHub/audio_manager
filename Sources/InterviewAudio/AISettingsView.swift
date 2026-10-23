import SwiftUI
import AppKit
import AudioCore

struct AISettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @UIState private var settings = AISettings()
    @UIState private var showKey = false
    @UIState private var testing = false
    @UIState private var message = ""
    @UIState private var testTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("大模型配置").font(.title2.weight(.semibold))
            Text("连接支持 chat/completions 的文本接口，供听阅助手提问和修订正文使用。").font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow { Text("接口地址"); TextField("https://服务地址/v1", text: $settings.baseURL) }
                GridRow { Text("模型名称"); TextField("填写服务提供的模型 ID", text: $settings.model) }
                GridRow {
                    Text("API Key")
                    HStack {
                        if showKey { TextField("本地免认证服务可留空", text: $settings.apiKey) }
                        else { SecureField("本地免认证服务可留空", text: $settings.apiKey) }
                        Toggle("显示", isOn: $showKey).toggleStyle(.checkbox)
                    }
                }
                GridRow { Text("输出 token 上限"); TextField("8192", value: $settings.maxOutputTokens, format: .number).frame(width: 110) }
            }.textFieldStyle(.roundedBorder).disabled(testing)
            Text("助手自动按范围处理文字。接口地址也可填写完整的 /chat/completions 地址。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("配置（含 API Key）直接保存在本机 llm-settings.json，可手动编辑，文件仅当前用户可读写。").font(.caption).foregroundStyle(.secondary)
            Text(model.aiConfigurationURL.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            Button("打开配置目录") { NSWorkspace.shared.open(model.dataDirectory) }.font(.caption)
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Button(testing ? "测试中…" : "测试连接") { testConnection() }.disabled(testing)
                if testing { ProgressView().controlSize(.small); Button("取消测试") { testTask?.cancel() } }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try model.saveAISettings(settings); dismiss() }
                    catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(testing).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 660)
        .onAppear { model.reloadAISettings(); settings = model.aiSettings }
        .onDisappear { testTask?.cancel() }
    }
    private func testConnection() {
        testing = true; message = "仅发送一条连接测试消息。"
        let configuration = settings
        testTask = Task {
            defer { testing = false }
            do { try await model.aiConnectionClient.test(settings: configuration); message = "连接成功，可以保存配置。" }
            catch { message = Task.isCancelled ? "已取消测试。" : error.localizedDescription }
        }
    }
}
