import LampBoardCore
import Foundation

/// Reads the lock files the Claude Code VS Code extension drops in
/// `~/.claude/ide/`, one per connected window.
///
/// Locks are not always removed when a window closes, so the list is a hypothesis
/// that has to be confirmed. It is confirmed **against the editor's process**, not
/// against the file's age: a lock is written once when the window connects and
/// never touched again, so its timestamp says how long the window has been open —
/// and windows left open for a fortnight are normal. Filtering on age made five
/// projects vanish from the column on their eighth day.
struct IDEWindowReader {
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL = AppConfig.ideLockDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Windows currently declared by the lock files.
    /// An unreadable lock is skipped: that is no reason to fail everything.
    func readWindows() -> [IDEWindow] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let windows = entries
            .filter { $0.pathExtension == "lock" }
            .compactMap(readWindow)

        // Ask the system which editors are actually running, once, and let the
        // pure rule decide from that.
        let alive = Set(windows.map(\.pid).filter { $0 > 0 && kill(pid_t($0), 0) == 0 })
        let now = Date()
        // Resolved here, where the disk may be touched, and only for the windows
        // that survived: one `realpath` per open folder per read.
        return windows.filter { $0.isUsable(at: now, alivePids: alive) }.map { $0.resolvingLinks() }
    }

    private func readWindow(at url: URL) -> IDEWindow? {
        guard
            let data = try? Data(contentsOf: url),
            let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
            let modifiedAt = attributes.contentModificationDate
        else {
            return nil
        }
        return try? IDELockParser.parse(data: data, modifiedAt: modifiedAt)
    }
}
