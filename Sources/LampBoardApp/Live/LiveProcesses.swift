import Darwin
import Foundation
import LampBoardCore

/// The processes the live view started, kept on disk (D130).
///
/// Closing a window ends its `claude attach` and quitting ends them all, but a
/// crash does neither: the attach goes on holding a terminal nobody can see.
/// The next launch reads the ledgers of LampBoards that are gone and ends what is
/// still running as the same process, telling a recycled pid apart by its start
/// time (`LiveLedger`).
@MainActor
enum LiveProcesses {

    /// One ledger per LampBoard, named after it (pid and start time), so that
    /// a second one starting never ends the first one's attaches.
    static var folder: URL { AppConfig.supportDirectory.appendingPathComponent("live", isDirectory: true) }
    private static let mine = LiveLedger.fileName(owner: getpid(), startedAt: startTime(of: getpid()) ?? 0)
    static var file: URL { folder.appendingPathComponent(mine) }

    static func record(pid: pid_t, job: String) {
        guard pid > 1, let started = startTime(of: pid) else { return }
        write(read().filter { $0.pid != pid } + [LiveLedger.Entry(pid: pid, startedAt: started, job: job)])
    }

    static func forget(pid: pid_t) {
        write(read().filter { $0.pid != pid })
    }

    /// At launch, before any window: what a LampBoard that is gone left
    /// running. The ledgers of one that still runs are not touched.
    static func endLeftovers() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name != mine {
            guard let owner = LiveLedger.owner(fromFileName: name),
                  LiveLedger.isOrphaned(owner: owner, startTime: startTime(of:)) else { continue }
            let ledger = folder.appendingPathComponent(name)
            let entries = (try? Data(contentsOf: ledger)).map(LiveLedger.decode) ?? []
            for entry in LiveLedger.toEnd(entries, startTime: startTime(of:)) {
                Diagnostics.log("live: ending \(entry.pid) (\(entry.job)), left by an earlier run")
                LiveSignals.hangUp(entry.pid, startedAt: entry.startedAt)
            }
            try? FileManager.default.removeItem(at: ledger)
        }
    }

    /// A few hundred file descriptors is the default for an app, and every
    /// terminal holds a pty and its pipes: AgentHub measured spawns failing after
    /// a few hours at 256. Raised once, as far as the hard limit allows.
    static func raiseFileLimit(to wanted: rlim_t = 10_240) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < wanted else { return }
        limit.rlim_cur = min(wanted, limit.rlim_max)
        _ = setrlimit(RLIMIT_NOFILE, &limit)
    }

    /// When the system says `pid` started, in seconds since 1970; `nil` when
    /// there is no such process. Asked in-process: no `ps` to spawn.
    nonisolated static func startTime(of pid: pid_t) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }

    private static func read() -> [LiveLedger.Entry] {
        (try? Data(contentsOf: file)).map(LiveLedger.decode) ?? []
    }

    private static func write(_ entries: [LiveLedger.Entry]) {
        if entries.isEmpty { try? FileManager.default.removeItem(at: file); return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? LiveLedger.encode(entries).write(to: file, options: .atomic)
    }
}
