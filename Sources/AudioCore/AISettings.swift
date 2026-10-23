import Foundation

public struct AISettings: Codable, Equatable, Sendable {
    public var baseURL = ""
    public var apiKey = ""
    public var model = ""
    public var chunkCharacters = 4500
    public var maxOutputTokens = 8192
    public init() {}
    private enum CodingKeys: String, CodingKey { case baseURL, apiKey, model, chunkCharacters, maxOutputTokens }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        chunkCharacters = try c.decodeIfPresent(Int.self, forKey: .chunkCharacters) ?? 4500
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 8192
    }
    public func endpoint() throws -> URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: raw), let host = parts.host, !host.isEmpty,
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw AudioError.message("请填写有效的接口地址，例如 https://服务地址/v1。") }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.hasSuffix("chat/completions") ? url : url.appendingPathComponent("chat/completions")
    }
    public func validate() throws {
        _ = try endpoint()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AudioError.message("请填写模型名称。") }
        guard (512...32768).contains(maxOutputTokens) else {
            throw AudioError.message("输出上限需为 512–32768 tokens。")
        }
    }
    public static func load(from url: URL) throws -> AISettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AISettings() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

