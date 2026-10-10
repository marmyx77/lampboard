import LampBoardCore
import Foundation

/// Takes in what the companion mod reports and keeps it beside the column.
///
/// Not in `StateStore`: the mod adds figures to rows, it does not make them
/// (D65), and the store is already the largest file in the app. A measure's
/// context goes to the reducer as a reading the transcript cannot override;
/// the rest stays in the ledger for whoever shows it.
@MainActor
final class ModReceiver {

    private(set) var ledger = ModLedger()
    /// Told the default account's newest windows whenever a measure brings
    /// some: the allowance strip draws them (D67).
    var onWindows: ((limits: [ModReport.RateLimit], at: Date)?) -> Void = { _ in }
    private let store: StateStore
    private let clock: () -> Date

    init(store: StateStore, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
    }

    /// Every report, after the ledger has it: the Plancia's activity log.
    var onReport: (ModReport, Date) -> Void = { _, _ in }

    func receive(_ report: ModReport) {
        let now = clock()
        ledger = ledger.applying(report, now: now)
        onReport(report, now)
        // Only under LAMPBOARD_DEBUG: "is my mod talking?" is the first question
        // when a figure does not show, and this is where it is answered.
        Diagnostics.log("mod: \(Self.kind(of: report)) from \(report.session.prefix(8))")
        // A measure for a row the hooks have not announced yet is dropped: the
        // reducer only annotates rows that exist, and the next response brings
        // a fresh one. The mod never creates a row.
        if case .measure(_, let measure) = report, measure.defaultAccount, !measure.rateLimits.isEmpty {
            onWindows(ledger.latestRateLimits)
        }
        if case .tool(let id, _) = report {
            let start = store.state.sessions[id].map { $0.status == .working ? $0.statusSince : now } ?? now
            store.apply(.tooling(sessionId: id, tool: ledger.longestRunning(in: id, since: start)), now: now)
        }
        if case .measure(let id, let measure) = report, let usd = measure.costUSD {
            store.apply(.costed(sessionId: id, usd: usd), now: now)
        }
        guard case .measure(let id, let measure) = report,
              let reading = measure.reading(previous: store.state.sessions[id]?.context, at: now)
        else { return }
        store.apply(.observed(sessionId: id, context: reading), now: now)
    }

    private static func kind(of report: ModReport) -> String {
        switch report {
        case .start(_, let start): return "start (\(start.surface ?? "no surface"))"
        case .measure(_, let measure):
            return "measure (\(measure.tokens.map(String.init) ?? "no") tokens, \(measure.rateLimits.count) windows, "
                + (measure.defaultAccount ? "default account)" : "other or unknown account)")
        case .end(_, let reason): return "end (\(reason.rawValue))"
        case .tool(_, let run): return "tool \(run.finished ? "end" : "start") (\(run.tool))"
        case .answer(_, let answer): return "answer (\(answer.text == nil ? answer.reason ?? "none" : "text"))"
        case .done(_, let done): return "done (\(done.op) \(done.ok ? "ok" : done.error ?? "failed"))"
        }
    }

    /// Writes the port for the mod to find, `0600` like the token beside it.
    ///
    /// The hooks carry the port in their script; the mod is one file for every
    /// Mac and every port, so it reads it here. Written on every launch, since
    /// `--port` can change it between two.
    static func publishPort(_ port: UInt16, at url: URL = AppConfig.portURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            return Diagnostics.log("port file not writable: \(error.localizedDescription)")
        }
        // A fresh name, created exclusively and never through a link: a file
        // planted where the staging name would be cannot redirect the write.
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".port-\(UUID().uuidString.prefix(8))")
        let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return Diagnostics.log("port file not created: errno \(errno)") }
        let bytes = Array("\(port)\n".utf8)
        let written = write(fd, bytes, bytes.count)
        close(fd)
        // rename(2): atomic, and it replaces a file already there.
        guard written == bytes.count, rename(staging.path, url.path) == 0 else {
            unlink(staging.path)
            return Diagnostics.log("port file not moved into place: errno \(errno)")
        }
    }
}
