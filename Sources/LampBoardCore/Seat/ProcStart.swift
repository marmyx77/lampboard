import Foundation

/// The `procStart` a session file carries, in the two forms Claude Code writes.
///
/// Linux writes the process's start in clock ticks since boot (`"5480393"`); macOS
/// writes a ctime string **in UTC with no zone marker** at second resolution
/// (`"Wed Aug 26 17:07:24 2026"`, for a process `ps -o lstart` shows two hours
/// later in Rome). Parsing that string in local time — the obvious mistake —
/// rejects every live session, or accepts a dead one's reused pid.
///
/// It exists for one question: is the process behind this pid still the one the
/// file was written for?
public enum ProcStart: Sendable, Equatable {
    case date(Date)
    case ticks(Int)

    public static func parse(_ raw: String) -> ProcStart? {
        let text = raw.trimmed
        if let ticks = Int(text) { return .ticks(ticks) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: text.replacingOccurrences(of: "  ", with: " ")).map(ProcStart.date)
    }

    /// Whether the live process behind a session file's pid is still the one
    /// the file was written for.
    ///
    /// Only what can be disproved is: a file without a start (older Claude
    /// Code), one in a form this does not read, or a process whose start could
    /// not be asked, all keep the session. A pid is recycled within minutes on a
    /// busy Mac, and `kill(pid, 0)` alone then keeps a dead session's row alive
    /// for as long as the stranger runs.
    public static func stillHolds(recorded: String?, startedAt: Date?) -> Bool {
        guard let recorded, let start = parse(recorded), let startedAt else { return true }
        // Two seconds, not the one a click allows: here a wrong answer hides a
        // live row, and a recycled pid is minutes away from the original.
        return start.matches(processStartedAt: startedAt, tolerance: 2)
    }

    /// `true` when a process started at `start` can be the one the file names.
    ///
    /// Ticks cannot be checked here — they count from another machine's boot —
    /// and answer `true`: the remote probe checks them where they mean something.
    public func matches(processStartedAt start: Date, tolerance: TimeInterval = 1) -> Bool {
        switch self {
        case .ticks: return true
        case .date(let date): return abs(date.timeIntervalSince(start)) <= tolerance
        }
    }
}
