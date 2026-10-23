import Foundation
import Combine

/// 编辑窗口只在真实保存成功后关闭，失败时保留窗口和用户输入。
@MainActor
final class EditorSaveState: ObservableObject {
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    func commit(_ operation: () async throws -> Void) async -> Bool {
        guard !saving else { return false }
        saving = true; error = nil
        defer { saving = false }
        do { try await operation(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
