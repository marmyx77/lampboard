import LampBoardCore
import Foundation

/// Keeps a `SessionCard` for every conversation LampMaster may look at, read
/// from the transcripts a few bytes at a time.
///
/// Two kinds of conversation, found two ways. The live ones are the panel's
/// rows: their state comes from the hooks, their transcript from the path a
/// hook gave or from where Claude Code files it. The closed ones are only
/// transcripts: the most recent under `~/.claude/projects`, because a session
/// closed an hour ago with work half done is exactly what a person forgets.
///
/// Each file is followed by byte offset, like the chat window does: the first
/// read takes the tail, every later one only what was appended, and a file that
/// shrank is read again. An `actor`, so the reads never land on the thread
/// that draws.
actor LampMasterCards {

    /// A row of the panel, reduced to what a card needs from it.
    struct Live: Sendable {
        let sessionId: String
        let transcriptPath: String?
        let cwd: String
        let liveness: LampMasterSession.Liveness
        let surface: String
        let agent: String
        let repository: String?
        let branch: String?
        let contextWindow: Int?
    }

    /// Closed conversations followed at most: the frame keeps about forty.
    static let closedKept = 60
    /// The first read of a closed transcript: its last prompts and answer are
    /// near the end, and a week of them must not cost a gigabyte.
    static let closedTail: UInt64 = 512 * 1024

    private struct Followed {
        var reader: SessionCardReader
        var offset: UInt64
    }

    private var followed: [String: Followed] = [:]
    private let projects: URL

    init(projects: URL = AppConfig.claudeDirectory.appendingPathComponent("projects", isDirectory: true)) {
        self.projects = projects
    }

    func sessions(live: [Live], now: Date) -> [LampMasterSession] {
        let recent = recentTranscripts(since: now.addingTimeInterval(-LampMasterFrameBuilder.leftAskingWindow))
        let recentPaths = Dictionary(recent.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        let liveIds = Set(live.map(\.sessionId))
        var result: [LampMasterSession] = []
        var paths: Set<String> = []

        for row in live {
            let path = row.transcriptPath
                ?? recentPaths[row.sessionId]
                ?? TranscriptLocator.candidateURL(sessionId: row.sessionId, cwd: row.cwd).path
            paths.insert(path)
            guard let card = card(sessionId: row.sessionId, path: path, tail: UInt64(AppConfig.transcriptInitialWindow)) else { continue }
            result.append(LampMasterSession(
                card: card, liveness: row.liveness, surface: row.surface, agent: row.agent,
                repository: row.repository, branch: row.branch, contextWindow: row.contextWindow
            ))
        }

        let closed = recent.filter { !liveIds.contains($0.id) }
        for (sessionId, path) in closed.prefix(Self.closedKept) {
            paths.insert(path)
            guard let card = card(sessionId: sessionId, path: path, tail: Self.closedTail) else { continue }
            result.append(LampMasterSession(card: card, liveness: .closed))
        }

        followed = followed.filter { paths.contains($0.key) }
        return result
    }

    // MARK: - Internals

    /// The card for one transcript, brought up to date.
    private func card(sessionId: String, path: String, tail: UInt64) -> SessionCard? {
        guard let size = Self.size(of: path) else { return nil }
        var entry = followed[path] ?? Followed(reader: SessionCardReader(sessionId: sessionId), offset: 0)
        if size < entry.offset {
            entry = Followed(reader: SessionCardReader(sessionId: sessionId), offset: 0)
        }
        if size > entry.offset, let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            let start = entry.offset == 0 && size > tail ? size - tail : entry.offset
            if (try? handle.seek(toOffset: start)) != nil, let raw = try? handle.readToEnd() {
                // From the middle of a file the first line is half a record.
                let data = start > 0 && entry.offset == 0 ? TranscriptWindow.trimmedToLineStart(raw) : raw
                entry.reader.consume(String(decoding: data, as: UTF8.self))
                entry.offset = start + UInt64(raw.count)
            }
        }
        followed[path] = entry
        return entry.reader.card
    }

    /// Top-level transcripts written since `date`, newest first, one per
    /// session. Subagents keep their transcripts one folder down and are not
    /// conversations of their own.
    private func recentTranscripts(since date: Date) -> [(id: String, path: String)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return [] }
        var found: [(id: String, path: String, at: Date)] = []
        for folder in folders {
            guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let at = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate, at >= date else { continue }
                found.append((file.deletingPathExtension().lastPathComponent, file.path, at))
            }
        }
        var seen: Set<String> = []
        return found
            .sorted { $0.at > $1.at }
            .filter { seen.insert($0.id).inserted }
            .map { ($0.id, $0.path) }
    }

    private static func size(of path: String) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value
    }
}
