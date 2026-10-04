import LampBoardCore
import Darwin
import Foundation

/// Reads the live Claude Code sessions from `~/.claude/sessions/`.
///
/// The directory holds one file per process, but the files survive the death of
/// the process: the name is the PID, and the liveness check is `kill(pid, 0)`.
/// It costs one syscall per file and sends no signal at all — it only asks the
/// kernel whether that process still exists.
struct LiveSessionReader {
    private let directory: URL
    private let fileManager: FileManager

    init(
        directory: URL = AppConfig.liveSessionsDirectory,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Sessions whose process is actually running.
    /// An unreadable file is skipped rather than failing the whole read.
    func readLiveSessions() -> [LiveSession] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap(read)
            .filter { isRunning(pid: $0.pid) && isSameProcess($0) }
    }

    // MARK: - Internal

    private func read(_ url: URL) -> LiveSession? {
        guard
            let data = try? Data(contentsOf: url),
            let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
            let modifiedAt = attributes.contentModificationDate
        else {
            return nil
        }
        guard let session = try? LiveSessionParser.parse(data: data, modifiedAt: modifiedAt) else {
            return nil
        }
        return session.with(modifiedAt: lastActivity(of: session, fallback: modifiedAt))
    }

    /// When this session last did anything.
    ///
    /// **Not** the session file's timestamp, which is what it used to be. That file
    /// is written once, when the session starts, and never touched again: a session
    /// opened a week ago and working right now reports a week of silence. The
    /// column then pruned it as stale, so the traffic light went dark on precisely
    /// the session it exists to show.
    ///
    /// The transcript is the real signal — it grows with every message and every
    /// tool result. Measured on the session that exposed this: transcript 1.3
    /// minutes old, session file 173.6 hours.
    ///
    /// Falls back to the session file when the transcript cannot be found, which
    /// happens for a session running inside a git worktree.
    /// When the conversation last said something.
    ///
    /// From the last **timestamped** record in the transcript, not from the file's
    /// modification date. The comment this replaced said the transcript is the
    /// only file that moves when a session does something, and that was measured
    /// to be false: three projects untouched for days all read as active within
    /// the hour, because tooling around the session had appended `last-prompt` and
    /// `bridge-session` records carrying no timestamp at all. A row that invents
    /// activity is worse than a row that says nothing.
    ///
    /// The mtime stays as the fallback for a tail with nothing timestamped in it,
    /// which is a file being written heavily enough that something is genuinely
    /// happening to it.
    private func lastActivity(of session: LiveSession, fallback: Date) -> Date {
        let candidate = TranscriptLocator.candidateURL(
            sessionId: session.sessionId, cwd: session.cwd
        )
        // Not `max` with the session file's date, and that mattered: those files
        // are rewritten while nothing is said, so taking the later of the two put
        // every one of these rows back where they were. When the transcript says
        // when it last spoke, that **is** the answer, and a file being touched is
        // not a second opinion about it.
        if let spoken = lastSpokenMoment(atPath: candidate.path) { return spoken }
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: candidate.path
        ), let modified = attributes[.modificationDate] as? Date else {
            return fallback
        }
        return max(modified, fallback)
    }

    /// Reads the end of the transcript and asks Core when it last said anything.
    private func lastSpokenMoment(atPath path: String) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = (try? handle.seekToEnd()) else { return nil }

        let slice = UInt64(TranscriptActivity.tailLimit)
        let wholeFile = slice >= size
        guard (try? handle.seek(toOffset: wholeFile ? 0 : size - slice)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return nil }

        return TranscriptActivity.lastTimestamp(
            inTailChunk: String(decoding: data, as: UTF8.self), isWholeFile: wholeFile
        )
    }

    /// The pid's process started when the file says: otherwise the pid was
    /// handed to somebody else after the session died (`ProcStart.stillHolds`).
    private func isSameProcess(_ session: LiveSession) -> Bool {
        ProcStart.stillHolds(
            recorded: session.procStart,
            startedAt: ProcessTree.info(of: pid_t(session.pid))?.startedAt
        )
    }

    /// `kill(pid, 0)` sends nothing: it only checks existence and permissions.
    /// `EPERM` means the process exists but belongs to another user, so it still
    /// counts as alive.
    private func isRunning(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
