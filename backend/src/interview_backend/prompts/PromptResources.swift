import Foundation

/// 与 Python 后端共用的固定模型提示词资源。
public enum ModelPrompts {
    public static func connectionTest() throws -> (system: String, user: String) {
        (try text("text-system"), try text("text-user"))
    }

    private static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "connection") else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "缺少模型提示词资源：\(name)"])
        }
        var value = try String(contentsOf: url, encoding: .utf8)
        if value.hasSuffix("\n") { value.removeLast() }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "模型提示词资源为空：\(name)"])
        }
        return value
    }
}
