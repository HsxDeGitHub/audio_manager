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
        PRAGMA user_version=1;
        """)
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
                          speakerEdited: int(q, offset + 6) == 1, needsReview: int(q, offset + 7) == 1)
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
        (EXISTS(SELECT 1 FROM segments s WHERE s.run_id=r.id AND (s.edited IS NOT NULL OR s.speaker_edited=1))
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
                try write("INSERT INTO segments VALUES(?,?,?,?,?,?,?,?,?)", [s.id,runID,s.start,s.end,s.original,s.edited,s.speaker,s.speakerEdited ? 1 : 0,s.needsReview ? 1 : 0])
            }
            if !protect { recording.activeRun = runID }
            if let duration { recording.duration = max(recording.duration, duration) }
            try save(recording)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return !protect
    }
    public func segments(runID: String) throws -> [TranscriptSegment] {
        let q = try statement("SELECT id,start,end,original,edited,speaker,speaker_edited,needs_review FROM segments WHERE run_id=? ORDER BY start,id", [runID])
        defer { sqlite3_finalize(q) }
        var result: [TranscriptSegment] = []
        while sqlite3_step(q) == SQLITE_ROW { result.append(segment(q)) }
        return result
    }
    public func editText(segmentID: String, text: String) throws {
        try write("UPDATE segments SET edited=? WHERE id=?", [text,segmentID])
    }
    public func editSpeaker(segmentID: String, speaker: Int?) throws {
        try write("UPDATE segments SET speaker=?,speaker_edited=1,needs_review=0 WHERE id=?", [speaker,segmentID])
    }
    public func editTexts(_ edits: [String: String]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for (id, text) in edits { try editText(segmentID: id, text: text) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func editSpeakers(segmentIDs: [String], speaker: Int?) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for id in segmentIDs { try editSpeaker(segmentID: id, speaker: speaker) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func applySpeakers(runID: String, turns: [SpeakerTurn]) throws {
        let matched = SpeakerMatcher.assign(try segments(runID: runID), turns: turns)
        try execute("BEGIN IMMEDIATE")
        do {
            for s in matched where !s.speakerEdited {
                try write("UPDATE segments SET speaker=?,needs_review=? WHERE id=?", [s.speaker,s.needsReview ? 1 : 0,s.id])
            }
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
        try write("INSERT INTO speakers VALUES(?,?,?) ON CONFLICT(run_id,speaker) DO UPDATE SET name=excluded.name", [runID,speaker,safe])
    }
    public func search(_ term: String, recordingID: String? = nil) throws -> [SearchHit] {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var result: [SearchHit] = []
        for recording in try recordings() where recordingID == nil || recording.id == recordingID {
            guard let run = recording.activeRun else { continue }
            result += TranscriptSearch.find(term, utterances: UtteranceGrouping.make(try segments(runID: run)),
                                            recordingID: recording.id, recordingTitle: recording.title,
                                            names: try speakerNames(runID: run))
        }
        return result
    }
}
