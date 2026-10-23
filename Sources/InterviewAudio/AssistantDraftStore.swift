import Foundation
import Darwin

struct AssistantDraft: Codable, Equatable {
    var input: String
    var allMaterials: Bool
    var quotes: [SelectedQuote]
}
struct AssistantDraftSnapshot: Codable {
    var selectedSession: String?
    var items: [String: AssistantDraft]
}

actor AssistantDraftStore {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> AssistantDraftSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 4_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let snapshot = try JSONDecoder().decode(AssistantDraftSnapshot.self, from: data)
        guard snapshot.items.count <= 100, snapshot.items.values.allSatisfy({
            $0.input.unicodeScalars.count <= 20000 && $0.quotes.count <= 20 &&
            $0.quotes.reduce(0, { $0 + $1.text.unicodeScalars.count }) <= 20000
        }) else { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }
    func save(_ snapshot: AssistantDraftSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard snapshot.items.count <= 100, data.count <= 4_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".assistant-draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
