import LampBoardCore
import Foundation

/// The governor's plan on disk, `~/.lampboard/governor.json` (G3): which sessions
/// run one model lower until the window resets. Written whole through a 0600 file
/// renamed into place; read by the server's threads when the mod asks, so under a
/// lock, and read again when the file changes, which costs a `stat` per turn.
final class GovernorService: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var plan = GovernorPlan()
    private var readAt: Date?

    init(url: URL = AppConfig.governorFile) {
        self.url = url
    }

    func model(for sessionId: String, now: Date = Date()) -> String? {
        lock.withLock {
            reloadIfChanged()
            return plan.model(for: sessionId, now: now)
        }
    }

    /// The file as it is now, when it moved since it was last read.
    private func reloadIfChanged() {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != readAt else { return }
        readAt = modified
        plan = (try? Data(contentsOf: url)).flatMap { try? GovernorPlan.decode($0) } ?? GovernorPlan()
    }

    func lower(_ sessionId: String, to model: String, until: Date, focused: String?) {
        change { $0.lowering(sessionId, to: model, until: until, focused: focused) }
    }

    func release(_ sessionId: String) {
        change { $0.releasing(sessionId) }
    }

    private func change(_ edit: (GovernorPlan) -> GovernorPlan) {
        lock.withLock {
            reloadIfChanged()
            plan = edit(plan).pruned(now: Date())
            // A write that fails leaves the disk as it was: read it again next time.
            guard let data = try? GovernorPlan.encode(plan) else { readAt = nil; return }
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let staging = directory.appendingPathComponent(".\(url.lastPathComponent).new")
            try? FileManager.default.removeItem(at: staging)
            guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { readAt = nil; return }
            if rename(staging.path, url.path) != 0 { try? FileManager.default.removeItem(at: staging); readAt = nil; return }
            readAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }
}
