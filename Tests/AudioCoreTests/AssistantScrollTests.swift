import AppKit
import SwiftUI
import Testing
@testable import InterviewAudio

@Suite(.serialized) struct AssistantScrollTests {
    @MainActor @Test(arguments: [CGFloat(320), 380, 760], [false, true])
    func longOutputCollapsingToResultKeepsViewportInsideContent(width: CGFloat, dark: Bool) async throws {
        let app = AppModel(dataDirectoryOverride: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let assistant = AssistantModel()
        assistant.activate("synthetic-scroll")
        let suite = "tingyue.scroll-test." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: AssistantView(model: app, assistant: assistant)
            .defaultAppStorage(preferences).environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: width, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close(); assistant.stop() }
        try await settle(host)

        assistant.runs = [AssistantRun(id: "synthetic-run", state: "running", result: nil)]
        assistant.consume(.init(id: 1, kind: "answer_reset", data: Data(#"{"attempt_id":"synthetic"}"#.utf8)), run: "synthetic-run", session: "synthetic-scroll")
        let text = (1...180).map { "第\($0)批合成结果\n需要保留的上下文和待核对内容。这是一段用于复现长回答布局的合成文字。" }.joined(separator: "\n\n")
        let delta = try JSONSerialization.data(withJSONObject: ["attempt_id": "synthetic", "block_id": "answer", "text": text])
        assistant.consume(.init(id: 2, kind: "answer_delta", data: delta), run: "synthetic-run", session: "synthetic-scroll")
        try await settle(host)
        let scroll = try #require(scrollViews(in: host).max(by: { $0.frame.height < $1.frame.height }))
        let document = try #require(scroll.documentView)
        #expect(document.bounds.height > scroll.contentView.bounds.height * 10)
        let suffix = "\(Int(width))-\(dark ? "dark" : "light")"
        try snapshot(host, name: "streaming-" + suffix)

        // 用户上翻时保留阅读位置，回到底部后恢复自动跟随。
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        try await settle(host)
        let readingPosition = scroll.contentView.bounds.minY
        let more = try JSONSerialization.data(withJSONObject: ["attempt_id": "synthetic", "block_id": "answer", "text": text])
        assistant.consume(.init(id: 3, kind: "answer_delta", data: more), run: "synthetic-run", session: "synthetic-scroll")
        try await settle(host)
        #expect(abs(scroll.contentView.bounds.minY - readingPosition) < 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try await settle(host)

        assistant.runs = [try JSONDecoder().decode(AssistantRun.self, from: Data(#"{"id":"synthetic-run","state":"completed","result":{"answer":"已完成合成校对。","changeset":{"id":"synthetic-change","state":"committed","count":404,"items":[]},"partial_results":[{"answer":"合成批次说明"}]}}"#.utf8))]
        try await settle(host)
        try snapshot(host, name: "completed-" + suffix)
        #expect(document.bounds.height < 1500)
        #expect(scroll.contentView.bounds.intersects(document.bounds))
        #expect(scroll.contentView.bounds.maxY <= max(document.bounds.maxY, scroll.contentView.bounds.height) + 1)

        // 普通回答完成后切换为 Markdown，也应停在真实正文底部。
        let finalAnswer = (1...100).map { "## 合成结论 \($0)\n\n保留具体事实与待核对项。\n\n- 合成来源说明" }.joined(separator: "\n\n")
        assistant.runs.append(AssistantRun(id: "plain-run", state: "running", result: nil))
        assistant.consume(.init(id: 1, kind: "answer_reset", data: Data(#"{"attempt_id":"plain"}"#.utf8)), run: "plain-run", session: "synthetic-scroll")
        let answerDelta = try JSONSerialization.data(withJSONObject: ["attempt_id": "plain", "block_id": "answer", "text": finalAnswer])
        assistant.consume(.init(id: 2, kind: "answer_delta", data: answerDelta), run: "plain-run", session: "synthetic-scroll")
        try await settle(host)
        let completed = try JSONSerialization.data(withJSONObject: ["id": "plain-run", "state": "completed", "result": ["answer": finalAnswer, "claims": []]])
        assistant.runs[1] = try JSONDecoder().decode(AssistantRun.self, from: completed)
        try await settle(host)
        // 底部锚点外还有 16 点内容留白。
        #expect(abs(document.bounds.maxY - scroll.contentView.bounds.maxY) <= 17)
        try snapshot(host, name: "markdown-" + suffix)
    }

    @MainActor private func settle(_ host: NSView) async throws {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor @Test func enhancedAssistantPanelsUseSyntheticChangesAndIndependentPreferences() async throws {
        guard ProcessInfo.processInfo.environment["INTERVIEW_UI_SNAPSHOT_DIR"] != nil else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppModel(dataDirectoryOverride: folder)
        let assistant = AssistantModel()
        assistant.activate("synthetic-panels")
        assistant.sessions = [.init(id: "synthetic-panels", title: "合成校对与问答")]
        let suite = "tingyue.panels-test." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); assistant.stop() }
        let items: [[String: Any]] = (0..<12).map { index in
            let original = "合成转写 \(index)"
            let edited = index % 3 == 0 ? "修正后的合成转写 \(index)" : index % 3 == 1 ? "合成，转写 \(index)。" : original
            return ["resource_type": "segment", "resource_id": "synthetic-\(index)", "after_revision": 2,
                "source_location": ["start": index * 10],
                "before": ["original": original, "edited": NSNull(), "speaker": 0, "needs_review": true, "reviewed": false],
                "after": ["original": original, "edited": edited, "speaker": index % 3 == 2 ? 1 : 0, "needs_review": index % 4 == 0, "reviewed": index % 4 != 0]]
        }
        let changeData = try JSONSerialization.data(withJSONObject: ["id": "synthetic-change", "state": "committed", "count": items.count, "items": items])
        let change = try JSONDecoder().decode(AssistantChange.self, from: changeData)
        let answer = "## 校对已完成\n\n已处理文字、标点和发言归属，待核对内容保留了标记。\n\n可以在修改面板逐项查看具体差异。\n\n```go\nfmt.Println(\"合成示例\")\n```"
        let runData = try JSONSerialization.data(withJSONObject: ["id": "synthetic-result", "state": "completed",
            "context": ["scope_title": "合成访谈", "task_intent": ["reading": "full"]],
            "result": ["answer": answer, "changeset": try JSONSerialization.jsonObject(with: changeData)]])
        assistant.runs = [AssistantRun(id: "older", state: "cancelled", result: nil), try JSONDecoder().decode(AssistantRun.self, from: runData)]
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            for width in [320, 380, 760] {
                try await capture(AssistantView(model: app, assistant: assistant).defaultAppStorage(preferences)
                    .environment(\.colorScheme, dark ? .dark : .light), width: CGFloat(width), height: 900,
                    name: "enhanced-overview-\(width)-\(appearance)", dark: dark)
            }
            try await capture(AssistantChangeReviewView(model: app, assistant: assistant, change: change)
                .environment(\.colorScheme, dark ? .dark : .light), width: 960, height: 660, name: "enhanced-review-\(appearance)", dark: dark)
            preferences.set(18.0, forKey: "assistant.fontSize")
            try await capture(AssistantAnswerReader(text: answer).defaultAppStorage(preferences)
                .environment(\.colorScheme, dark ? .dark : .light), width: 900, height: 680, name: "enhanced-reader-\(appearance)", dark: dark)
            preferences.set(14.0, forKey: "assistant.fontSize")
        }
        assistant.runs.append(AssistantRun(id: "streaming", state: "running", result: nil))
        assistant.consume(.init(id: 1, kind: "answer_reset", data: Data(#"{"attempt_id":"a"}"#.utf8)), run: "streaming", session: "synthetic-panels")
        for (eventID, blockID, text) in [(2, "previous", String(repeating: "已保留的合成批次说明。\n", count: 2000)), (3, "current", "正在整理当前批次，保存前仍需校验。") ] {
            let data = try JSONSerialization.data(withJSONObject: ["attempt_id": "a", "block_id": blockID, "text": text])
            assistant.consume(.init(id: eventID, kind: "answer_delta", data: data), run: "streaming", session: "synthetic-panels")
        }
        try await capture(AssistantView(model: app, assistant: assistant).defaultAppStorage(preferences), width: 380, height: 900, name: "enhanced-streaming")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor private func capture<Content: View>(_ content: Content, width: CGFloat, height: CGFloat, name: String, dark: Bool = false) async throws {
        let host = NSHostingView(rootView: content.background(ReaderTheme.canvas).frame(width: width, height: height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await settle(host)
        #expect(host.bounds.width == width && host.bounds.height == height)
        try snapshot(host, name: name)
    }

    @MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    @MainActor private func snapshot(_ host: NSView, name: String) throws {
        guard let destination = ProcessInfo.processInfo.environment["INTERVIEW_UI_SNAPSHOT_DIR"] else { return }
        let folder = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("assistant-scroll-\(name).png"))
    }
}
