import Foundation
import LampBoardCore

/// The rows of this machine and their numbered changes, kept across restarts.
///
/// The rules are the reference source's (`V1MemorySource`), which the
/// conformance suite holds every source to: one event per change, numbered from
/// one in a journal with a name; the journal keeps its last `retention` events,
/// and a client holding a number it no longer reaches gets a whole state. What
/// this adds is the disk: the rows and the events are written as they change, so
/// that a restart of the service — an update, the watchdog's bite — keeps the
/// journal's name and numbers, and a phone that held `seq` 412 asks for what
/// came after 412 and gets exactly that.
///
/// Not thread-safe by itself: `NodeSource` holds the lock.
public final class NodeJournal {

    public private(set) var name: String
    public private(set) var seq = 0
    public private(set) var rows: [String: V1Row] = [:]
    /// `false` until the first look: before it the state says `null`, never an
    /// empty column (D21).
    public private(set) var known = false
    public private(set) var rowsAt: Date?
    public private(set) var lastEventAt: Date?
    private var log: [V1Event] = []
    private let retention: Int
    private let directory: String?
    /// Lines in the events file, to know when to rewrite it shorter.
    private var written = 0

    /// - Parameter directory: where the journal lives; `nil` for one that lives
    ///   only as long as the process (a forced command reading files).
    public init(directory: String?, retention: Int = 1000, newName: () -> String = NodeJournal.freshName) {
        self.directory = directory
        self.retention = max(1, retention)
        self.name = newName()
        if let directory, restore(from: directory) == false {
            name = newName()
            seq = 0
            rows = [:]
            log = []
            try? persistAll()
        }
    }

    public static func freshName() -> String {
        "lampd-" + String(UInt64.random(in: 0...UInt64.max), radix: 36)
    }

    // MARK: - Changes

    public func upsert(_ row: V1Row, at now: Date) {
        known = true
        rows[row.id] = row
        rowsAt = now
        append(.row(row), at: now)
    }

    public func remove(id: String, at now: Date) {
        guard rows.removeValue(forKey: id) != nil else { return }
        rowsAt = now
        append(.gone(id: id), at: now)
    }

    /// The machine was looked at, whether or not anything changed.
    public func confirm(at now: Date) {
        known = true
        rowsAt = now
    }

    /// Writes what is not on disk yet. Called once per look, after its changes.
    public func flush() {
        guard directory != nil else { return }
        try? persistRows()
    }

    // MARK: - Reading

    public func snapshot(source: V1SourceIdentity, at now: Date) -> V1State {
        let ordered = rows.values.sorted { ($0.extras.order ?? Int.max, $0.id) < ($1.extras.order ?? Int.max, $1.id) }
        return V1State(journal: name, seq: seq, source: source, rows: known ? ordered : nil, rowsAt: rowsAt, at: now)
    }

    public func events(after since: Int) -> V1Replay {
        if since >= seq { return .events([]) }
        guard let first = log.first?.seq, since >= first - 1 else { return .unreachable }
        return .events(log.filter { $0.seq > since })
    }

    // MARK: - Inside

    private func append(_ change: V1Event.Change, at now: Date) {
        seq += 1
        let event = V1Event(seq: seq, at: now, change: change)
        log.append(event)
        lastEventAt = now
        if log.count > retention { log.removeFirst(log.count - retention) }
        guard let directory else { return }
        if written >= retention * 4 {
            try? persistAll()
        } else if let line = try? V1Codec.encoder().encode(event) {
            appendLine(line, to: directory + "/journal.jsonl")
            written += 1
        }
    }

    private func appendLine(_ line: Data, to path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line + Data([0x0A]))
    }

    private struct Header: Codable {
        let journal: String
        let seq: Int
        let known: Bool
        let rowsAt: Date?
        let rows: [V1Row]
    }

    private func persistRows() throws {
        guard let directory else { return }
        let header = Header(journal: name, seq: seq, known: known, rowsAt: rowsAt, rows: Array(rows.values))
        try AtomicFile.write(try V1Codec.encoder().encode(header), to: directory + "/rows.json")
    }

    /// The rows, and the events file rewritten with only what the journal keeps.
    private func persistAll() throws {
        guard let directory else { return }
        let lines = try log.map { try V1Codec.encoder().encode($0) + Data([0x0A]) }
        try AtomicFile.write(Data(lines.joined()), to: directory + "/journal.jsonl")
        written = log.count
        try persistRows()
    }

    /// What the last run left, or `false` when it cannot be trusted: a journal
    /// whose rows and events disagree starts again under a new name, and every
    /// client gets a whole state instead of numbers that mean something else.
    private func restore(from directory: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: directory + "/rows.json"),
              let header = try? V1Codec.decoder().decode(Header.self, from: data) else { return false }
        var events: [V1Event] = []
        if let text = FileManager.default.contents(atPath: directory + "/journal.jsonl") {
            for line in text.split(separator: 0x0A) where !line.isEmpty {
                // A line cut by a crash is the last one; anything after it is not trusted.
                guard let event = try? V1Codec.decoder().decode(V1Event.self, from: Data(line)) else { break }
                events.append(event)
            }
        }
        // The rows are written under the same lock as the events they include,
        // before any client can be sent one of them. Events past the rows were
        // appended by a run that died in between: nobody saw them, but their
        // numbers would be given again to other changes, so the journal starts
        // over rather than reuse them.
        let kept = events.filter { $0.seq <= header.seq }
        guard kept.count == events.count else { return false }
        if let last = kept.last, last.seq != header.seq { return false }
        name = header.journal
        seq = header.seq
        known = header.known
        rowsAt = header.rowsAt
        rows = Dictionary(header.rows.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        log = Array(kept.suffix(retention))
        lastEventAt = log.last?.at
        written = events.count
        return true
    }
}
