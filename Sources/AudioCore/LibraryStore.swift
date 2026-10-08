import Foundation
import CSQLite

/// Accessed exclusively on the main actor in the application. Workers never open the database.
public final class LibraryStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw AudioError.message("无法打开资料库") }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
        CREATE TABLE IF NOT EXISTS recordings (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, path TEXT NOT NULL, bookmark BLOB,
            fingerprint TEXT NOT NULL, duration REAL NOT NULL, created_at REAL NOT NULL,
            state TEXT NOT NULL, error TEXT, speaker_count INTEGER, play_position REAL NOT NULL,
            active_run TEXT
        );
        CREATE TABLE IF NOT EXISTS runs (
            id TEXT PRIMARY KEY, recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS segments (
            id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
            start REAL NOT NULL, end REAL NOT NULL, original TEXT NOT NULL, edited TEXT,
            speaker INTEGER, speaker_edited INTEGER NOT NULL DEFAULT 0, needs_review INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS segments_run_time ON segments(run_id, start);
        CREATE TABLE IF NOT EXISTS speakers (
            run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, speaker INTEGER NOT NULL,
            name TEXT NOT NULL, PRIMARY KEY(run_id, speaker)
        );
        CREATE TABLE IF NOT EXISTS edit_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
            label TEXT NOT NULL, before_json TEXT NOT NULL, after_json TEXT NOT NULL, applied INTEGER NOT NULL DEFAULT 1
        );
        """)
        let columns = try statement("PRAGMA table_info(segments)")
        var hasReviewed = false
        while sqlite3_step(columns) == SQLITE_ROW { if text(columns, 1) == "reviewed" { hasReviewed = true } }
        sqlite3_finalize(columns)
        if !hasReviewed { try execute("ALTER TABLE segments ADD COLUMN reviewed INTEGER NOT NULL DEFAULT 0") }
        try execute("PRAGMA user_version=2")
        try execute("CREATE TABLE IF NOT EXISTS reading_cache (run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, cache_key TEXT NOT NULL, rendered TEXT NOT NULL, PRIMARY KEY(run_id,cache_key))")
        // Processing cannot continue after an app exit. Keep queued work visible, but never auto-start it.
        try execute("UPDATE recordings SET state='interrupted', error='应用退出前任务未完成，请点击重试。' WHERE state IN ('queued','preprocessing','transcribing','diarizing')")
    }
    deinit { sqlite3_close(db) }
    private func error() -> AudioError { .message(String(cString: sqlite3_errmsg(db))) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func statement(_ sql: String, _ values: [Any?] = []) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else { throw error() }
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            if let value = value as? String { sqlite3_bind_text(query, i, value, -1, transient) }
            else if let value = value as? Data { _ = value.withUnsafeBytes { sqlite3_bind_blob(query, i, $0.baseAddress, Int32(value.count), transient) } }
            else if let value = value as? Double { sqlite3_bind_double(query, i, value) }
            else if let value = value as? Int { sqlite3_bind_int64(query, i, Int64(value)) }
            else { sqlite3_bind_null(query, i) }
        }
        return query
    }
    private func write(_ sql: String, _ values: [Any?] = []) throws {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
    }
    private func text(_ query: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(query, index) else { return nil }
        return String(cString: pointer)
    }
    private func int(_ query: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(query, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(query, index))
    }
    private func segment(_ q: OpaquePointer, offset: Int32 = 0) -> TranscriptSegment {
        TranscriptSegment(id: text(q, offset)!, start: sqlite3_column_double(q, offset + 1),
                          end: sqlite3_column_double(q, offset + 2), original: text(q, offset + 3)!,
                          edited: text(q, offset + 4), speaker: int(q, offset + 5),
                          speakerEdited: int(q, offset + 6) == 1, needsReview: int(q, offset + 7) == 1, reviewed: int(q, offset + 8) == 1)
    }
    public func recordings() throws -> [Recording] {
        let q = try statement("SELECT id,title,path,bookmark,fingerprint,duration,created_at,state,error,speaker_count,play_position,active_run FROM recordings ORDER BY created_at DESC")
        defer { sqlite3_finalize(q) }
        var results: [Recording] = []
        while sqlite3_step(q) == SQLITE_ROW {
            let bookmark = sqlite3_column_blob(q, 3).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(q, 3))) }
            results.append(Recording(id: text(q, 0)!, title: text(q, 1)!, path: text(q, 2)!, bookmark: bookmark,
                                     fingerprint: text(q, 4)!, duration: sqlite3_column_double(q, 5), createdAt: sqlite3_column_double(q, 6),
                                     state: TaskState(rawValue: text(q, 7)!) ?? .idle, error: text(q, 8), speakerCount: int(q, 9),
                                     playPosition: sqlite3_column_double(q, 10), activeRun: text(q, 11)))
        }
        return results
    }
    public func save(_ r: Recording) throws {
        try write("""
        INSERT INTO recordings VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
        title=excluded.title,path=excluded.path,bookmark=excluded.bookmark,fingerprint=excluded.fingerprint,
        duration=excluded.duration,state=excluded.state,error=excluded.error,speaker_count=excluded.speaker_count,
        play_position=excluded.play_position,active_run=excluded.active_run
        """, [r.id,r.title,r.path,r.bookmark,r.fingerprint,r.duration,r.createdAt,r.state.rawValue,r.error,r.speakerCount,r.playPosition,r.activeRun])
    }
    public func remove(_ id: String) throws { try write("DELETE FROM recordings WHERE id=?", [id]) }
    public func runs(recordingID: String) throws -> [TranscriptRun] {
        let q = try statement("""
        SELECT r.id,r.created_at,
        (EXISTS(SELECT 1 FROM segments s WHERE s.run_id=r.id AND (s.edited IS NOT NULL OR s.speaker_edited=1 OR s.reviewed=1))
        OR EXISTS(SELECT 1 FROM speakers p WHERE p.run_id=r.id AND p.name != CASE WHEN p.speaker<26 THEN '说话人 ' || char(65+p.speaker) ELSE '说话人 ' || (p.speaker+1) END))
        FROM runs r WHERE recording_id=? ORDER BY created_at DESC
        """, [recordingID])
        defer { sqlite3_finalize(q) }
        var result: [TranscriptRun] = []
        while sqlite3_step(q) == SQLITE_ROW { result.append(TranscriptRun(id: text(q,0)!, createdAt: sqlite3_column_double(q,1), hasEdits: int(q,2) == 1)) }
        return result
    }
    /// Every transcription is a separate revision. An edited active revision remains active.
    @discardableResult public func addTranscript(recordingID: String, runID: String, segments: [TranscriptSegment], duration: Double?) throws -> Bool {
        guard var recording = try recordings().first(where: { $0.id == recordingID }) else { throw AudioError.message("录音不存在") }
        let protect = try recording.activeRun.map { run in
            try self.segments(runID: run).contains(where: \.manuallyEdited)
                || self.speakerNames(runID: run).contains { $0.value != SpeakerMatcher.defaultName($0.key) }
        } ?? false
        try execute("BEGIN IMMEDIATE")
        do {
            try write("INSERT INTO runs VALUES(?,?,?)", [runID, recordingID, Date().timeIntervalSince1970])
            for s in segments {
                try write("INSERT INTO segments (id,run_id,start,end,original,edited,speaker,speaker_edited,needs_review,reviewed) VALUES(?,?,?,?,?,?,?,?,?,?)", [s.id,runID,s.start,s.end,s.original,s.edited,s.speaker,s.speakerEdited ? 1 : 0,s.needsReview ? 1 : 0,s.reviewed == true ? 1 : 0])
            }
            if !protect { recording.activeRun = runID }
            if let duration { recording.duration = max(recording.duration, duration) }
            try save(recording)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return !protect
    }
    public func segments(runID: String) throws -> [TranscriptSegment] {
        let q = try statement("SELECT id,start,end,original,edited,speaker,speaker_edited,needs_review,reviewed FROM segments WHERE run_id=? ORDER BY start,id", [runID])
        defer { sqlite3_finalize(q) }
        var result: [TranscriptSegment] = []
        while sqlite3_step(q) == SQLITE_ROW { result.append(segment(q)) }
        return result
    }
    private func runForSegments(_ ids: [String]) throws -> String {
        var run: String?
        for id in ids {
            let q = try statement("SELECT run_id FROM segments WHERE id=?", [id])
            let found = sqlite3_step(q) == SQLITE_ROW ? text(q,0) : nil
            sqlite3_finalize(q)
            guard let found, run == nil || found == run else { throw AudioError.message("校对只能修改同一转写版本中存在的句子") }
            run = found
        }
        guard let run else { throw AudioError.message("没有可修改的句子") }; return run
    }
    public func saveCorrection(segmentID: String, text: String?, markReviewed: Bool) throws {
        try recordEdit(runID: runForSegments([segmentID]), label: "校对句子") {
            if let text { try write("UPDATE segments SET edited=? WHERE id=?", [text,segmentID]) }
            if markReviewed { try write("UPDATE segments SET reviewed=1 WHERE id=?", [segmentID]) }
        }
    }
    public func editText(segmentID: String, text: String) throws { try editTexts([segmentID: text]) }
    public func editTexts(_ edits: [String: String]) throws {
        guard !edits.isEmpty else { return }
        try recordEdit(runID: runForSegments(Array(edits.keys)), label: "修改文字") {
            for (id, text) in edits { try write("UPDATE segments SET edited=? WHERE id=?", [text,id]) }
        }
    }
    public func editSpeaker(segmentID: String, speaker: Int?) throws { try editSpeakers(segmentIDs: [segmentID], speaker: speaker) }
    public func editSpeakers(segmentIDs: [String], speaker: Int?) throws {
        guard !segmentIDs.isEmpty else { return }
        try recordEdit(runID: runForSegments(segmentIDs), label: "修改说话人归属") {
            for id in segmentIDs { try write("UPDATE segments SET speaker=?,speaker_edited=1,needs_review=0 WHERE id=?", [speaker,id]) }
        }
    }
    public func markReviewed(segmentIDs: [String], reviewed: Bool) throws {
        guard !segmentIDs.isEmpty else { return }
        try recordEdit(runID: runForSegments(segmentIDs), label: reviewed ? "标记已核对" : "重新标为待核对") {
            for id in segmentIDs { try write("UPDATE segments SET reviewed=?,needs_review=1 WHERE id=?", [reviewed ? 1 : 0,id]) }
        }
    }
    public func mergeSpeakers(runID: String, sources: Set<Int>, target: Int) throws {
        let sources = sources.subtracting([target])
        guard !sources.isEmpty else { return }
        try recordEdit(runID: runID, label: "合并说话人") {
            for source in sources {
                try write("UPDATE segments SET speaker=?,speaker_edited=1 WHERE run_id=? AND speaker=?", [target,runID,source])
                try write("DELETE FROM speakers WHERE run_id=? AND speaker=?", [runID,source])
            }
            try write("INSERT OR IGNORE INTO speakers VALUES(?,?,?)", [runID,target,SpeakerMatcher.defaultName(target)])
        }
    }
    private struct EditSnapshot: Codable, Equatable {
        struct Item: Codable, Equatable {
            var id: String; var edited: String?; var speaker: Int?; var speakerEdited: Bool; var needsReview: Bool; var reviewed: Bool?
        }
        var items: [Item]; var names: [Int: String]
    }
    private func snapshot(_ run: String) throws -> EditSnapshot {
        EditSnapshot(items: try segments(runID: run).map {
            EditSnapshot.Item(id: $0.id, edited: $0.edited, speaker: $0.speaker, speakerEdited: $0.speakerEdited, needsReview: $0.needsReview, reviewed: $0.reviewed)
        }, names: try speakerNames(runID: run))
    }
    private func recordEdit(runID: String, label: String, change: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let before = try snapshot(runID); try change(); let after = try snapshot(runID)
            if before != after {
                try write("DELETE FROM edit_history WHERE run_id=? AND applied=0", [runID])
                let encoder = JSONEncoder()
                try write("INSERT INTO edit_history(run_id,label,before_json,after_json) VALUES(?,?,?,?)", [runID,label,
                    String(decoding: try encoder.encode(before), as: UTF8.self), String(decoding: try encoder.encode(after), as: UTF8.self)])
                try write("DELETE FROM edit_history WHERE run_id=? AND id NOT IN (SELECT id FROM edit_history WHERE run_id=? ORDER BY id DESC LIMIT 50)", [runID,runID])
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func historyLabel(runID: String, redo: Bool = false) throws -> String? {
        let q = try statement("SELECT label FROM edit_history WHERE run_id=? AND applied=? ORDER BY id \(redo ? "ASC" : "DESC") LIMIT 1", [runID,redo ? 0 : 1])
        defer { sqlite3_finalize(q) }; return sqlite3_step(q) == SQLITE_ROW ? text(q,0) : nil
    }
    @discardableResult public func restoreEdit(runID: String, redo: Bool = false) throws -> Bool {
        let q = try statement("SELECT id, \(redo ? "after_json" : "before_json") FROM edit_history WHERE run_id=? AND applied=? ORDER BY id \(redo ? "ASC" : "DESC") LIMIT 1", [runID,redo ? 0 : 1])
        guard sqlite3_step(q) == SQLITE_ROW, let id = int(q,0), let json = text(q,1) else { sqlite3_finalize(q); return false }
        sqlite3_finalize(q)
        let state = try JSONDecoder().decode(EditSnapshot.self, from: Data(json.utf8))
        try execute("BEGIN IMMEDIATE")
        do {
            for item in state.items {
                try write("UPDATE segments SET edited=?,speaker=?,speaker_edited=?,needs_review=?,reviewed=? WHERE id=? AND run_id=?", [item.edited,item.speaker,item.speakerEdited ? 1 : 0,item.needsReview ? 1 : 0,item.reviewed == true ? 1 : 0,item.id,runID])
            }
            try write("DELETE FROM speakers WHERE run_id=?", [runID])
            for (speaker,name) in state.names { try write("INSERT INTO speakers VALUES(?,?,?)", [runID,speaker,name]) }
            try write("UPDATE edit_history SET applied=? WHERE id=?", [redo ? 1 : 0,id])
            try execute("COMMIT"); return true
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func applySpeakers(runID: String, turns: [SpeakerTurn]) throws {
        let matched = SpeakerMatcher.assign(try segments(runID: runID), turns: turns)
        try execute("BEGIN IMMEDIATE")
        do {
            for s in matched where !s.speakerEdited && s.reviewed != true {
                try write("UPDATE segments SET speaker=?,needs_review=? WHERE id=?", [s.speaker,s.needsReview ? 1 : 0,s.id])
            }
            try write("DELETE FROM edit_history WHERE run_id=?", [runID])
            let ids = Set(matched.compactMap(\.speaker))
            for id in ids { try write("INSERT OR IGNORE INTO speakers VALUES(?,?,?)", [runID,id,SpeakerMatcher.defaultName(id)]) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func speakerNames(runID: String) throws -> [Int: String] {
        let q = try statement("SELECT speaker,name FROM speakers WHERE run_id=? ORDER BY speaker", [runID]); defer { sqlite3_finalize(q) }
        var result: [Int: String] = [:]
        while sqlite3_step(q) == SQLITE_ROW { result[int(q,0)!] = text(q,1)! }
        return result
    }
    public func renameSpeaker(runID: String, speaker: Int, name: String) throws {
        let safe = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        guard !safe.isEmpty else { return }
        try recordEdit(runID: runID, label: "重命名说话人") {
            try write("INSERT INTO speakers VALUES(?,?,?) ON CONFLICT(run_id,speaker) DO UPDATE SET name=excluded.name", [runID,speaker,safe])
        }
    }
    public func saveReadingCache(runID: String, key: String, rendered: [String: String]) throws {
        let json = String(decoding: try JSONEncoder().encode(rendered), as: UTF8.self)
        try write("INSERT INTO reading_cache VALUES(?,?,?) ON CONFLICT(run_id,cache_key) DO UPDATE SET rendered=excluded.rendered", [runID,key,json])
        try write("DELETE FROM reading_cache WHERE run_id=? AND rowid NOT IN (SELECT rowid FROM reading_cache WHERE run_id=? ORDER BY rowid DESC LIMIT 1000)", [runID,runID])
    }
    public func readingCache(runID: String) throws -> [String: [String: String]] {
        let q = try statement("SELECT cache_key,rendered FROM reading_cache WHERE run_id=?", [runID]); defer { sqlite3_finalize(q) }
        var values: [String: [String: String]] = [:]
        while sqlite3_step(q) == SQLITE_ROW {
            if let key = text(q,0), let json = text(q,1), let result = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) { values[key] = result }
        }
        return values
    }
    public func search(_ term: String, recordingID: String? = nil, punctuate: Bool = true,
                       paragraphBreaks: Bool = true, density: ReadingDensity = .balanced, smartPunctuation: Bool = false) throws -> [SearchHit] {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var result: [SearchHit] = []
        for recording in try recordings() where recordingID == nil || recording.id == recordingID {
            guard let run = recording.activeRun else { continue }
            let utterances = UtteranceGrouping.make(try segments(runID: run))
            let cache = smartPunctuation ? try readingCache(runID: run) : [:]
            let overrides = utterances.reduce(into: [String: String]()) { result, utterance in
                if let saved = cache[PunctuationProjection.key(utterance.segments)] { result.merge(saved) { _,new in new } }
            }
            result += TranscriptSearch.find(term, utterances: utterances,
                                            recordingID: recording.id, recordingTitle: recording.title,
                                            names: try speakerNames(runID: run), punctuate: punctuate, paragraphBreaks: paragraphBreaks, density: density, overrides: overrides)
        }
        return result
    }
}
