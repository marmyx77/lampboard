import Foundation
import LampBoardCore
import SQLite3

/// Every conversation of this Mac, searchable (0.7, M2): the system's SQLite
/// with FTS5, in `~/.lampboard/index.sqlite`, owner-only.
///
/// Built from the transcripts and kept up from them: each file is read from
/// where the last pass stopped, a file that shrank is read again from the
/// start, and a pass has a budget, newest files first, so the first build of a
/// long history spreads over many passes instead of one heavy minute. What it
/// keeps is `IndexRecords`': the person's words and Claude's answers, never
/// context or tool output. It spends no token.
///
/// Every SQLite call runs on one serial queue: a connection is not shared
/// across threads.
final class SearchIndex: @unchecked Sendable {

    struct Hit: Equatable {
        let sessionId: String
        let title: String?
        let cwd: String?
        let lastAt: Date?
        let snippet: String
    }

    /// Transcripts older than this are left out of a first build.
    static let horizon: TimeInterval = 90 * 24 * 3600
    /// The most read of one file in one pass: a transcript of hundreds of
    /// megabytes is read over many passes, never held whole in memory.
    static let chunkLimit = 8 << 20

    private let url: URL
    private let projects: URL
    private let queue = DispatchQueue(label: "lampboard.search-index")
    private var db: OpaquePointer?
    /// Why the last open failed, in SQLite's words.
    private(set) var problem: String?

    init(url: URL = AppConfig.supportDirectory.appendingPathComponent("index.sqlite"),
         projects: URL = AppConfig.claudeDirectory.appendingPathComponent("projects", isDirectory: true)) {
        self.url = url
        self.projects = projects
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Opening

    /// Opens or creates the index, owner-only. `false` when the disk refuses.
    func open() -> Bool {
        queue.sync {
            if db != nil { return true }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            // The index itself must not be a link; a link higher up — `/var` is
            // one, and some homes are — is the system's business, not ours
            // (`SQLITE_OPEN_NOFOLLOW` refuses any, and with it every temp home).
            var info = stat()
            if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG {
                problem = "\(url.path) is not a regular file"
                return false
            }
            var handle: OpaquePointer?
            // Created owner-only from the start, its `-wal` and `-shm` beside it
            // too: a chmod after would leave a window, and miss those two.
            let mask = umask(0o077)
            defer { umask(mask) }
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
            else {
                problem = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "not opened"
                sqlite3_close(handle)
                return false
            }
            chmod(url.path, 0o600)
            // The command line and the panel can write at once: wait for each other.
            sqlite3_busy_timeout(handle, 5000)
            db = handle
            let made = run("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS conv(sid TEXT PRIMARY KEY, cwd TEXT, title TEXT, first_at REAL, last_at REAL,
                    prompts INTEGER NOT NULL DEFAULT 0, path TEXT NOT NULL, offset INTEGER NOT NULL DEFAULT 0);
                CREATE VIRTUAL TABLE IF NOT EXISTS msg USING fts5(sid UNINDEXED, role UNINDEXED, at UNINDEXED, text,
                    tokenize='unicode61 remove_diacritics 2');
                PRAGMA user_version=1;
                """)
            // Only a connection with its tables is kept: a failed schema is tried again next time.
            guard made else {
                problem = String(cString: sqlite3_errmsg(handle))
                sqlite3_close(handle)
                db = nil
                return false
            }
            // A second copy of every conversation has no business in a backup.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = url
            try? excluded.setResourceValues(values)
            return true
        }
    }

    // MARK: - Keeping up

    /// One pass: the transcripts that grew since the last, newest first, within
    /// a budget of files and bytes. What it read. The queue is taken per file,
    /// so a search or a lookup waits for one file, never for the pass.
    @discardableResult
    func update(files budgetFiles: Int = 200, bytes budgetBytes: Int = 32 << 20) -> (files: Int, messages: Int) {
        guard open() else { return (0, 0) }
        var files = 0, messages = 0, bytes = 0
        for file in transcripts() where files < budgetFiles && bytes < budgetBytes {
            guard let done = queue.sync(execute: { index(file) }) else { continue }
            files += 1; messages += done.messages; bytes += done.bytes
        }
        queue.sync { prune() }
        return (files, messages)
    }

    /// One file's new lines, all of them or none. The offset is read inside the
    /// transaction, so the command line and the panel writing at once never
    /// add the same chunk twice.
    private func index(_ file: Transcript) -> (messages: Int, bytes: Int)? {
        guard run("BEGIN IMMEDIATE") else { return nil }
        let known = stored(file.sid)
        if let known, known.offset == file.size { run("ROLLBACK"); return nil }
        let start = (known.map { $0.offset <= file.size } ?? false) ? known!.offset : 0
        guard let chunk = read(file.url, from: start), !chunk.isEmpty else { run("ROLLBACK"); return nil }
        let lines = String(decoding: chunk, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        let read = IndexRecords.read(lines: lines)
        // A file read again from its start replaces what it had; a new one has nothing to replace.
        var ok = start > 0 || known == nil || delete(file.sid)
        for message in read.messages where ok { ok = insert(file.sid, message) }
        let earlier = start == 0 ? IndexRecords.Facts() : (known?.facts ?? IndexRecords.Facts())
        ok = ok && save(file.sid, read.facts.following(earlier), path: file.url.path, offset: start + chunk.count)
        guard ok, run("COMMIT") else { run("ROLLBACK"); return nil }
        return (read.messages.count, chunk.count)
    }

    /// A conversation whose transcript is gone — Claude Code cleaned it up — is
    /// not found any more. A few each pass.
    private func prune() {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT sid, path FROM conv ORDER BY last_at LIMIT 400", -1, &statement, nil) == SQLITE_OK else { return }
        var gone: [String] = []
        while gone.count < 20, sqlite3_step(statement) == SQLITE_ROW {
            if let path = text(statement, 1), !FileManager.default.fileExists(atPath: path), let sid = text(statement, 0) { gone.append(sid) }
        }
        sqlite3_finalize(statement)
        for sid in gone {
            guard run("BEGIN IMMEDIATE") else { return }
            if delete(sid), execute("DELETE FROM conv WHERE sid = ?", sid), run("COMMIT") { continue }
            run("ROLLBACK")
        }
    }

    /// Takes the index and its side files away: `lampboard search --reset`.
    func reset() -> Bool {
        queue.sync {
            if let db { sqlite3_close(db) }
            db = nil
            return ["", "-wal", "-shm"].allSatisfy { suffix in
                let path = url.path + suffix
                return !FileManager.default.fileExists(atPath: path) || (try? FileManager.default.removeItem(atPath: path)) != nil
            }
        }
    }

    // MARK: - Searching

    /// The conversations that say all of `typed`, the best first, one hit each.
    func search(_ typed: String, limit: Int = 8) -> [Hit] {
        guard let query = IndexQuery.fts(typed), open() else { return [] }
        return queue.sync {
            var statement: OpaquePointer?
            let sql = """
                SELECT msg.sid, snippet(msg, 3, '«', '»', '…', 12), conv.title, conv.cwd, conv.last_at
                FROM msg LEFT JOIN conv ON conv.sid = msg.sid WHERE msg MATCH ? ORDER BY bm25(msg) LIMIT 400
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, query, -1, transient)
            // Grouped here, not with GROUP BY: `bm25()` cannot be used with it
            // (the prototype's first run died on that, §9.5).
            var seen = Set<String>(), hits: [Hit] = []
            while hits.count < limit, sqlite3_step(statement) == SQLITE_ROW {
                let sid = text(statement, 0) ?? ""
                guard seen.insert(sid).inserted else { continue }
                hits.append(Hit(sessionId: sid, title: text(statement, 2), cwd: text(statement, 3),
                                lastAt: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil
                                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                                snippet: RowActivity.flat(text(statement, 1) ?? "")))
            }
            return hits
        }
    }

    /// Every prompt the person typed since `from`, with its conversation's
    /// folder and name: what the week's summary counts.
    func prompts(since from: Date) -> [WeekSummary.Prompt] {
        guard open() else { return [] }
        return queue.sync {
            var statement: OpaquePointer?
            let sql = """
                SELECT msg.sid, conv.cwd, conv.title, msg.at FROM msg LEFT JOIN conv ON conv.sid = msg.sid
                WHERE msg.sid IN (SELECT sid FROM conv WHERE last_at >= ?1) AND msg.role = 'user' AND msg.at >= ?1
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
            var prompts: [WeekSummary.Prompt] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                prompts.append(WeekSummary.Prompt(sessionId: text(statement, 0) ?? "", cwd: text(statement, 1),
                                                  title: text(statement, 2),
                                                  at: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
            }
            return prompts
        }
    }

    /// The week in a paragraph, for the person (0.7).
    func week(now: Date = Date()) -> String {
        WeekSummary.text(WeekSummary.summarize(prompts(since: WeekSummary.start(now: now)), now: now))
    }

    /// Where a conversation ran, as its transcript said.
    func cwd(of sessionId: String) -> String? {
        guard open() else { return nil }
        return queue.sync { stored(sessionId)?.facts.cwd }
    }

    // MARK: - Files

    private struct Transcript { let url: URL; let sid: String; let size: Int; let modified: Date }

    /// The transcripts within the horizon, newest first.
    private func transcripts() -> [Transcript] {
        let fileManager = FileManager.default
        let since = Date().addingTimeInterval(-Self.horizon)
        guard let folders = try? fileManager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return [] }
        var found: [Transcript] = []
        for folder in folders {
            // A project folder of Claude Code's own, not a link to somewhere else.
            guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])).map({
                $0.isSymbolicLink != true && $0.isDirectory == true
            }) == true,
                  let files = try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" && ModReport.isSessionId(file.deletingPathExtension().lastPathComponent) {
                // A regular file: a link points elsewhere, a pipe would never end.
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate,
                      modified >= since
                else { continue }
                found.append(Transcript(url: file, sid: file.deletingPathExtension().lastPathComponent, size: size, modified: modified))
            }
        }
        return found.sorted { $0.modified > $1.modified }
    }

    /// From `offset` to the last complete line: the rest waits for its newline.
    private func read(_ url: URL, from offset: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.read(upToCount: Self.chunkLimit)
        else { return Data() }
        guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else {
            // One line longer than a whole chunk is not a message: stepped over.
            return data.count == Self.chunkLimit ? data : Data()
        }
        return Data(data.prefix(through: last))
    }

    // MARK: - Rows

    private func stored(_ sid: String) -> (offset: Int, facts: IndexRecords.Facts)? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT offset, cwd, title, first_at, last_at, prompts FROM conv WHERE sid = ?", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sid, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        var facts = IndexRecords.Facts()
        facts.cwd = text(statement, 1)
        facts.title = text(statement, 2)
        facts.firstAt = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        facts.lastAt = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        facts.prompts = Int(sqlite3_column_int(statement, 5))
        return (Int(sqlite3_column_int64(statement, 0)), facts)
    }

    private func save(_ sid: String, _ facts: IndexRecords.Facts, path: String, offset: Int) -> Bool {
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO conv(sid, cwd, title, first_at, last_at, prompts, path, offset) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(sid) DO UPDATE SET cwd=excluded.cwd, title=excluded.title, first_at=excluded.first_at,
                last_at=excluded.last_at, prompts=excluded.prompts, path=excluded.path, offset=excluded.offset
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sid, -1, transient)
        bind(statement, 2, facts.cwd)
        bind(statement, 3, facts.title)
        bind(statement, 4, facts.firstAt)
        bind(statement, 5, facts.lastAt)
        sqlite3_bind_int(statement, 6, Int32(facts.prompts))
        sqlite3_bind_text(statement, 7, path, -1, transient)
        sqlite3_bind_int64(statement, 8, Int64(offset))
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func insert(_ sid: String, _ message: IndexRecords.Message) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO msg(sid, role, at, text) VALUES(?,?,?,?)", -1, &statement, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sid, -1, transient)
        sqlite3_bind_text(statement, 2, message.role, -1, transient)
        sqlite3_bind_double(statement, 3, message.at.timeIntervalSince1970)
        sqlite3_bind_text(statement, 4, message.text, -1, transient)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func delete(_ sid: String) -> Bool {
        execute("DELETE FROM msg WHERE sid = ?", sid)
    }

    /// One statement with one text bound, done or not.
    private func execute(_ sql: String, _ value: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, value, -1, transient)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    // MARK: - SQLite

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult
    private func run(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(statement, index, value, -1, transient) } else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Date?) {
        if let value { sqlite3_bind_double(statement, index, value.timeIntervalSince1970) } else { sqlite3_bind_null(statement, index) }
    }
}
