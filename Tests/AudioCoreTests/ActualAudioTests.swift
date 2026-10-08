import Foundation
import Testing
import AudioCore

/// Opt-in acceptance checks; private recordings and outputs remain outside source control.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["INTERVIEW_ACTUAL_TEST_DIR"] != nil))
struct ActualAudioTests {
    private var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["INTERVIEW_ACTUAL_TEST_DIR"]!) }
    @Test func testActualAudioPipelineAndOriginalTimeline() throws {
        var excerpts: [TranscriptSegment] = []
        for prefix in ["actual-middle", "actual-end"] {
            let request = try JSONDecoder().decode(WorkerRequest.self, from: Data(contentsOf: root.appendingPathComponent(prefix + "-request.json")))
            try FileFingerprint.verify(URL(fileURLWithPath: request.source), expected: request.fingerprint)
            let events = try String(contentsOf: root.appendingPathComponent(prefix + "-events.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONDecoder().decode(WorkerEvent.self, from: Data($0.utf8)) }
            #expect(events.last?.kind == "done")
            let transcript = try #require(events.first(where: { $0.kind == "transcript" })?.segments)
            #expect(!transcript.isEmpty)
            let start = try #require(request.excerptStart), duration = try #require(request.excerptDuration)
            for segment in transcript {
                #expect(segment.start >= start - 0.01)
                #expect(segment.end <= start + duration + 0.25)
                #expect(segment.end >= segment.start)
                #expect(!segment.text.contains("请使用简体中文"))
            }
            excerpts += transcript
        }
        let beginning = try BackendParser.whisperJSON(Data(contentsOf: root.appendingPathComponent("actual-vad-sample.json")))
        #expect(!beginning.isEmpty)
        #expect(!beginning.contains { $0.text.contains("请使用简体中文") })
        excerpts += beginning
        let turns = try BackendParser.speakerOutput(String(contentsOf: root.appendingPathComponent("actual-speakers-balanced.log"), encoding: .utf8))
        let matched = SpeakerMatcher.assign(excerpts, turns: turns)
        let source = try JSONDecoder().decode(WorkerRequest.self, from: Data(contentsOf: root.appendingPathComponent("actual-middle-request.json")))
        let temporary = root.appendingPathComponent("acceptance-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let database = try LibraryStore(url: temporary.appendingPathComponent("library.sqlite"))
        let recording = Recording(title: "真实面试测试摘录（非完整转写）", path: source.source, fingerprint: source.fingerprint, duration: 2657.088)
        try database.save(recording)
        try database.addTranscript(recordingID: recording.id, runID: "actual-run", segments: matched, duration: nil)
        try database.applySpeakers(runID: "actual-run", turns: turns)
        let saved = try database.segments(runID: "actual-run")
        let names = try database.speakerNames(runID: "actual-run")
        let example = try #require(saved.first(where: { $0.start > 1320 && $0.text.count > 3 }))
        let term = String(example.text.prefix(3))
        let hits = try database.search(term)
        #expect(hits.contains { $0.segment.id == example.id && $0.recordingID == recording.id })
        let text = TranscriptExport.render(title: recording.title, segments: saved, names: names, srt: false)
        let srt = TranscriptExport.render(title: recording.title, segments: saved, names: names, srt: true)
        #expect(srt.contains("00:43:"))
        try text.write(to: root.appendingPathComponent("面试测试摘录.txt"), atomically: true, encoding: .utf8)
        try srt.write(to: root.appendingPathComponent("面试测试摘录.srt"), atomically: true, encoding: .utf8)
        let summary: [String: Any] = [
            "sourceUnchanged": true, "sourceDurationSeconds": 2657.088,
            "excerptSegmentCount": saved.count, "fullDiarizationTurns": turns.count,
            "estimatedSpeakerCount": Set(turns.map(\.speaker)).count,
            "reviewSegmentCount": saved.filter(\.needsReview).count,
            "testedExcerptStarts": [0,1320,2600], "fullTranscriptionCompleted": false
        ]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("actual-validation.json"), options: .atomic)
    }
}
