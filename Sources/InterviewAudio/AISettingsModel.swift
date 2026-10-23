import Foundation
import AudioCore

extension AppModel {
    var aiConfigurationURL: URL { dataDirectory.appendingPathComponent("llm-settings.json") }
    func reloadAISettings() {
        do { aiSettings = try AISettings.load(from: aiConfigurationURL) }
        catch { alert = "无法读取 llm-settings.json，请检查 JSON 格式。" }
    }
    func saveAISettings(_ settings: AISettings) throws {
        try settings.validate(); try settings.save(to: aiConfigurationURL); aiSettings = settings
    }
}
