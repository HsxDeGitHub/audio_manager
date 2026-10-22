import Foundation
import AppKit
import UniformTypeIdentifiers
import AudioCore

extension AppModel {
    var aiConfigurationURL: URL { dataDirectory.appendingPathComponent("llm-settings.json") }
    var selectedAIDraft: AIDraft? { aiDrafts.first { $0.id == selectedAIDraftID } }
    var aiDraftIsStale: Bool {
        guard let draft = selectedAIDraft else { return false }
        return draft.sourceHash != AISource.fingerprint(AISource.snapshot(segments: segments, names: names))
    }
    func loadAIDrafts() {
        do {
            guard let store, let run = selected?.activeRun else { aiDrafts = []; selectedAIDraftID = nil; return }
            aiDrafts = try store.aiDrafts(runID: run).map { saved in
                var draft = saved
                if draft.state == .running && draft.id != aiActiveDraftID {
                    draft.state = .interrupted; try store.saveAIDraft(draft)
                }
                return draft
            }
            if !aiDrafts.contains(where: { $0.id == selectedAIDraftID }) { selectedAIDraftID = aiDrafts.first?.id }
        } catch { alert = "整理稿读取失败：\(error.localizedDescription)" }
    }
    func reloadAISettings() {
        do { aiSettings = try AISettings.load(from: aiConfigurationURL) }
        catch { alert = "无法读取 llm-settings.json，请检查 JSON 格式。" }
    }
    func saveAISettings(_ settings: AISettings) throws {
        try settings.validate(); try settings.save(to: aiConfigurationURL); aiSettings = settings
    }
    func startAI(mode: AIOrganizationMode, instructions: String) {
        guard aiActiveDraftID == nil, let recording = selected, let run = recording.activeRun else { return }
        do {
            // Read the harness-style configuration again so external file edits also take effect.
            let settings = try AISettings.load(from: aiConfigurationURL); try settings.validate(); aiSettings = settings
            let draft = try AIDraft(runID: run, recordingID: recording.id, title: recording.title,
                                    settings: settings, mode: mode, instructions: instructions,
                                    sources: AISource.snapshot(segments: segments, names: names))
            try persistAI(draft); selectedAIDraftID = draft.id; readerShowsAI = true; showAICompose = false
            runAI(draft, settings: settings)
        } catch { alert = "无法开始整理：\(error.localizedDescription)" }
    }
    func resumeAI(_ draft: AIDraft) {
        guard aiActiveDraftID == nil, draft.state != .completed else { return }
        do {
            let settings = try AISettings.load(from: aiConfigurationURL); try settings.validate(); aiSettings = settings
            guard try settings.endpoint().absoluteString == draft.endpoint,
                  settings.model.trimmingCharacters(in: .whitespacesAndNewlines) == draft.model else {
                throw AudioError.message("续跑需使用原接口与模型（\(draft.model)）。更换模型或分块大小后，可点击 AI 整理创建新稿。")
            }
            runAI(draft, settings: settings)
        } catch { alert = error.localizedDescription }
    }
    private func persistAI(_ draft: AIDraft) throws {
        guard let store else { throw AudioError.message("资料库不可用。") }
        try store.saveAIDraft(draft)
        if selected?.activeRun == draft.runID {
            if let i = aiDrafts.firstIndex(where: { $0.id == draft.id }) { aiDrafts[i] = draft }
            else { aiDrafts.insert(draft, at: 0) }
        }
    }
    private func runAI(_ initial: AIDraft, settings: AISettings) {
        aiActiveDraftID = initial.id; aiActiveRecordingID = initial.recordingID; aiWorkingDraft = initial
        aiTask = Task { [weak self] in
            guard let self else { return }
            var draft = initial
            defer {
                aiActiveDraftID = nil; aiActiveRecordingID = nil; aiWorkingDraft = nil; aiTask = nil; aiProgressMessage = ""
            }
            do {
                draft.state = .running; draft.error = nil; aiWorkingDraft = draft; try persistAI(draft)
                for i in draft.chunks.indices where draft.chunks[i].blocks == nil {
                    try Task.checkCancellation()
                    aiProgressMessage = "\(draft.recordingTitle) · 正在整理第 \(i + 1)/\(draft.chunks.count) 块"
                    let blocks = try await aiClient.organize(settings: settings, draft: draft, chunkIndex: i)
                    try Task.checkCancellation()
                    draft.chunks[i].blocks = blocks; aiWorkingDraft = draft; try persistAI(draft)
                }
                try Task.checkCancellation()
                draft.state = .completed; aiWorkingDraft = draft; try persistAI(draft)
                notice = "AI 整理已完成：\(draft.recordingTitle)"
            } catch {
                draft.state = Task.isCancelled || error is CancellationError ? .cancelled : .failed
                draft.error = draft.state == .cancelled ? nil : error.localizedDescription
                aiWorkingDraft = draft
                do { try persistAI(draft) }
                catch { alert = "整理进度保存失败：\(error.localizedDescription)" }
                if draft.state == .failed { notice = "AI 整理失败，已保留完成的分块，可重试。" }
            }
        }
    }
    func cancelAI() { aiTask?.cancel(); aiProgressMessage = "正在取消，已完成的分块会保留…" }
    func stopAIForShutdown() {
        aiTask?.cancel()
        if var draft = aiWorkingDraft { draft.state = .interrupted; try? persistAI(draft) }
    }
    func saveAIBlock(draftID: String, blockID: String, title: String, text: String) {
        guard let draft = aiDrafts.first(where: { $0.id == draftID }), draft.id != aiActiveDraftID, let store else { return }
        do {
            let receipt = try store.editAIDraftBlock(draftID: draftID, blockID: blockID, title: title, text: text)
            changeHistory.record(receipt); loadAIDrafts(); notice = "整理稿已保存，可在修改记录中查看与撤销。"
        } catch { alert = error.localizedDescription }
    }
    func openAISource(_ source: AISource, play: Bool) {
        readerShowsAI = false; reviewFilter = .all
        focusSegmentID = source.id; focusRequestID = UUID()
        if play { player.seek(max(0, source.start - preRoll), play: true) }
    }
    func exportAI(markdown: Bool) {
        guard let draft = selectedAIDraft, !draft.blocks.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: markdown ? "md" : "txt") ?? .plainText]
        panel.nameFieldStringValue = "\(draft.recordingTitle)-\(draft.mode.title).\(markdown ? "md" : "txt")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try draft.export(markdown: markdown).write(to: url, atomically: true, encoding: .utf8)
            notice = "已导出 \(url.lastPathComponent)"
        } catch { alert = error.localizedDescription }
    }
}
