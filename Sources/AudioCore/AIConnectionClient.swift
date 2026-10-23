import Foundation
import PromptResources

/// 只发送固定测试消息；不发送资料正文或保存服务端错误内容。
public struct AIConnectionClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    private struct Message: Encodable { let role: String; let content: String }
    private struct Request: Encodable {
        let model: String; let messages: [Message]; let stream = false; let max_tokens: Int
    }
    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Content: Decodable { let content: String? }
            let message: Content; let finish_reason: String?
        }
        let choices: [Choice]
    }
    private func complete(settings: AISettings, system: String, input: String, maxTokens: Int? = nil) async throws -> String {
        try settings.validate(); try Task.checkCancellation()
        var request = URLRequest(url: try settings.endpoint()); request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(Request(model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [Message(role: "system", content: system), Message(role: "user", content: input)], max_tokens: maxTokens ?? settings.maxOutputTokens))
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw AudioError.message("请求失败，请检查网络和接口地址；也可能是服务响应超时。")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AudioError.message("接口没有返回有效的 HTTP 响应。") }
        guard (200...299).contains(http.statusCode) else {
            let reason: String
            switch http.statusCode {
            case 401,403: reason = "请检查 API Key 与模型访问权限。"
            case 404: reason = "请检查接口地址和模型名称，接口需支持 chat/completions。"
            case 429: reason = "请求受限，请稍后重试并检查账户额度。"
            case 400,413,422: reason = "请检查模型名称及参数。"
            default: reason = "服务暂时不可用，请稍后重试。"
            }
            // Do not echo provider bodies: they may contain keys or private source text.
            throw AudioError.message("大模型接口返回 HTTP \(http.statusCode)。\(reason)")
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data), let choice = decoded.choices.first else {
            throw AudioError.message("响应不符合 chat/completions 格式，请检查接口协议。")
        }
        if choice.finish_reason == "length" { throw AudioError.message("模型输出被截断。请检查模型设置后重试。") }
        guard choice.finish_reason == nil || choice.finish_reason == "stop" else {
            throw AudioError.message("模型未正常完成文本生成，请检查模型设置后重试。")
        }
        guard let value = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AudioError.message("模型返回了空内容，请检查该模型是否支持文本输出。")
        }
        return value
    }
    public func test(settings: AISettings) async throws {
        let prompts = try ModelPrompts.connectionTest()
        _ = try await complete(settings: settings, system: prompts.system, input: prompts.user, maxTokens: 512)
    }
}
