import LampBoardCore
import Foundation

/// The panel's end of the mailbox.
///
/// Three jobs, and the third is the one that keeps this honest: opening a
/// conversation for chatting, dropping a message into it, and **cleaning up after
/// listeners that outlived everything**.
///
/// That last one is not housekeeping. The listener is spawned detached by Claude
/// Code, so it survives the CLI *and* it survives us. Without a reaper, every
/// crash of lampboard leaves a process waiting on a conversation nobody is
/// looking at, and they accumulate one per crash per session, silently.
struct MailboxWriter {

    private let fileManager: FileManager
    private let isEnabled: () -> Bool

    /// - Parameter isEnabled: whether the user has turned sending on. Checked on
    ///   every call rather than captured, because the switch can be flipped while
    ///   a window is open.
    init(fileManager: FileManager = .default, isEnabled: @escaping () -> Bool = { false }) {
        self.fileManager = fileManager
        self.isEnabled = isEnabled
    }

    /// `true` when the user has allowed the panel to answer.
    var isSendingEnabled: Bool { isEnabled() }

    // MARK: - Opening and closing

    /// Declares that a chat window is open for this session.
    ///
    /// The marker is the listener's arming condition, so this is what decides
    /// which sessions cost a waiting process. Everything else pays one file test.
    @discardableResult
    func open(sessionId: String) -> Result<Void, MailboxError> {
        guard isEnabled() else { return .failure(.disabled) }
        guard let paths = Mailbox.paths(for: sessionId) else {
            return .failure(.invalidSessionId(sessionId))
        }
        do {
            try Mailbox.ensureDirectory(using: fileManager)
            try Data().write(to: paths.open, options: .atomic)
            try Mailbox.restrict(paths.open, using: fileManager)
            Self.leases.take(sessionId)
            return .success(())
        } catch {
            return .failure(.notDelivered(error.localizedDescription))
        }
    }

    /// Withdraws the marker, **unless a message is still waiting**.
    ///
    /// The armed listener notices the marker is gone within a second and stands
    /// down on its own; killing it here would be a race against a process that is
    /// already leaving.
    ///
    /// An undelivered message keeps the conversation armed. Dropping it would be
    /// discarding something the interface accepted and the user believes is on its
    /// way — and for a dormant session that is the normal case, not a rare one,
    /// because delivery waits for the session's next turn however long that takes.
    ///
    /// - Returns: `true` when the conversation was actually released.
    @discardableResult
    func close(sessionId: String) -> Bool {
        guard let paths = Mailbox.paths(for: sessionId) else { return false }
        // The chat window and the Plancia can hold one session at once: the
        // first to let go must not take the marker from the other (D79).
        guard Self.leases.give(sessionId) == 0 else { return true }
        guard !fileManager.fileExists(atPath: paths.message.path) else { return false }
        try? fileManager.removeItem(at: paths.open)
        return true
    }

    // MARK: - Sending

    /// Leaves a message for the session to pick up at the end of its next turn.
    ///
    /// Written atomically, because the listener polls: a reader that catches a
    /// half-written file would deliver half a sentence, and there is no way to
    /// tell afterwards that it happened.
    ///
    /// Delivery is **not** immediate and the caller must not pretend otherwise.
    /// If the session is working, the message waits on disk until the turn ends —
    /// which is the behavior a chat wants, and the reason this is a file and not
    /// a socket.
    func send(_ text: String, to sessionId: String) -> Result<Void, MailboxError> {
        guard isEnabled() else { return .failure(.disabled) }
        guard let paths = Mailbox.paths(for: sessionId) else {
            return .failure(.invalidSessionId(sessionId))
        }
        guard fileManager.fileExists(atPath: paths.open.path) else {
            return .failure(.notDelivered("no chat window is open for this session"))
        }

        switch Mailbox.validate(text) {
        case .failure(let error):
            return .failure(error)
        case .success(let message):
            do {
                try Data(message.utf8).write(to: paths.message, options: .atomic)
                try Mailbox.restrict(paths.message, using: fileManager)
                return .success(())
            } catch {
                return .failure(.notDelivered(error.localizedDescription))
            }
        }
    }

    /// `true` when a message is still waiting to be picked up.
    func hasPending(sessionId: String) -> Bool {
        guard let paths = Mailbox.paths(for: sessionId) else { return false }
        return fileManager.fileExists(atPath: paths.message.path)
    }

    /// `true` when a listener is currently armed for this session.
    ///
    /// This is the cold-start question, and it decides whether a message will be
    /// delivered in seconds or not at all.
    ///
    /// A listener can only be born at the **end of a turn** — that is the whole
    /// mechanism. So opening a chat window on a session that is doing nothing
    /// arms nothing: the marker is down, but no turn will end to notice it. The
    /// message would sit on disk indefinitely, and the interface would show a
    /// spinner for something that is never going to happen.
    ///
    /// The window therefore asks this and says so plainly, rather than pretending
    /// the message is on its way. It resolves itself the moment anything happens
    /// in that session — including a single prompt typed in VS Code.
    func isListening(sessionId: String) -> Bool {
        guard let paths = Mailbox.paths(for: sessionId),
              let pid = (try? String(contentsOf: paths.pid, encoding: .utf8))?
                  .trimmed.nilIfEmpty,
              let identifier = pid_t(pid)
        else { return false }
        // The file outlives a listener that was killed rather than exiting, so the
        // process is checked rather than trusted.
        return kill(identifier, 0) == 0
    }

    // MARK: - Reaping

    /// Clears what a previous run left behind — but **never an undelivered
    /// message**.
    ///
    /// Called once at startup, when no chat window can be open, so every marker on
    /// disk belongs to a dead process and every listener waiting on one is holding
    /// a process for a window that no longer exists.
    ///
    /// The exception is the whole point of this method's second version. A
    /// conversation with a `.msg` still on disk is one where **the user wrote
    /// something and it has not arrived yet**, because the session was dormant and
    /// no turn has ended since. The first version swept those away with everything
    /// else, so quitting the app — or a crash, or a rebuild — silently destroyed a
    /// message the interface had already accepted. Dictated messages died that way.
    ///
    /// So a pending message **keeps its conversation armed**: the marker stays, the
    /// listener re-arms at that session's next turn, and the message goes. The same
    /// rule the shell already applies when you switch conversation with something
    /// still in flight.
    ///
    /// The pid file always goes: that process died with the app.
    ///
    /// - Returns: how many stale conversations were cleared, for the log.
    @discardableResult
    func reapStale() -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            atPath: Mailbox.directory.path
        ) else { return 0 }

        let verdict = MailboxReaper.verdict(forFileNames: entries)
        for name in verdict.delete {
            try? fileManager.removeItem(at: Mailbox.directory.appendingPathComponent(name))
        }
        if !verdict.keptArmed.isEmpty {
            Diagnostics.log(
                "mailbox: \(verdict.keptArmed.count) conversations kept armed, message undelivered"
            )
        }
        return verdict.cleared
    }

    // MARK: - Leases

    /// How many views hold each session's marker open, across every writer.
    private static let leases = Leases()

    private final class Leases: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func take(_ id: String) {
            lock.lock(); defer { lock.unlock() }
            counts[id, default: 0] += 1
        }

        /// What is left after letting go of one; never below zero.
        func give(_ id: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            let left = max((counts[id] ?? 0) - 1, 0)
            counts[id] = left == 0 ? nil : left
            return left
        }
    }
}
