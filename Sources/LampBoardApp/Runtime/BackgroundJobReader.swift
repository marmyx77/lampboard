import LampBoardCore
import Foundation

/// Reads the Agent View's job files, `~/.claude/jobs/<id>/state.json` (AV2).
///
/// One file per background row, the one its live file names: the folder keeps
/// every job ever run, and listing it on every poll would read hundreds of
/// finished ones to find the few that are alive. An unreadable file is a job not
/// seen, never a job ended — the row's life is its live file's.
struct BackgroundJobReader {
    /// A state file is about two kilobytes; past this it is not one.
    static let maxBytes = 256 * 1024

    private let directory: URL

    init(directory: URL = AppConfig.backgroundJobsDirectory) {
        self.directory = directory
    }

    /// The job filed under `id`, when it is readable and is `sessionId`'s.
    func readJob(id: String, sessionId: String) -> BackgroundJob? {
        let file = directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent("state.json")
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maxBytes,
              let data = try? Data(contentsOf: file),
              let job = BackgroundJobParser.parse(data: data, id: id),
              job.sessionId == sessionId
        else { return nil }
        return job
    }
}

extension StateStore {

    /// Attaches to each background row what its job file says of it, and
    /// clears it from a row whose job is gone.
    func readBackgroundJobs(_ live: [LiveSession], at now: Date) {
        let background = state.sessions.values.filter { $0.origin == .background && $0.workspace.host == nil }
        guard !background.isEmpty else { return }
        let reader = BackgroundJobReader()
        for session in background {
            let jobId = live.first { $0.sessionId == session.id && $0.host == nil }?.jobId
            let job = jobId.flatMap { reader.readJob(id: $0, sessionId: session.id) }
            apply(.jobRead(sessionId: session.id, job: job), now: now)
        }
    }
}
