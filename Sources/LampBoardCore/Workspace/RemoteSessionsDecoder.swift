import Foundation

/// Turns what a remote machine reports into `LiveSession` values.
///
/// The node runs the two checks that only make sense where the processes are —
/// `kill(pid, 0)` and the transcript's modification time — and emits one JSON
/// array. This is the boundary where that crosses into the domain, so it
/// validates the way `HookPayloadDecoder` does: nothing required is ever inferred
/// or defaulted.
///
/// **One bad record does not lose the others.** The output comes from a machine
/// whose Claude Code version we do not control; a single unparsable entry is not
/// a reason to blank the column for the whole host.
public enum RemoteSessionsDecoder {

    /// Everything one probe of a node said: its live sessions, and the editor
    /// windows open there.
    ///
    /// The windows are what put a remote row in the right folder. A hook's `cwd`
    /// follows every `cd` the session makes, so a session that started in
    /// `simululator` and stepped into `simululator/esperimento` reported the
    /// second — and with nothing to resolve it against, the row took that name
    /// and the click looked for a window nobody had open (D51).
    public struct Report: Equatable, Sendable {
        public let sessions: [LiveSession]
        public let windows: [IDEWindow]

        public init(sessions: [LiveSession], windows: [IDEWindow]) {
            self.sessions = sessions
            self.windows = windows
        }
    }

    /// - Parameters:
    ///   - data: the node's answer — an object with `sessions` and `windows`, or
    ///     the bare array an older probe printed.
    ///   - host: the name it answers to over ssh, carried into each session's
    ///     workspace so a row can say where it is.
    public static func decode(_ data: Data, host: String) throws -> [LiveSession] {
        try report(from: data, host: host, at: Date()).sessions
    }

    /// The whole answer. `at` is the Mac's clock, used only for the age rule on a
    /// lock that carries no usable pid — the same rule the local reader applies.
    public static func report(from data: Data, host: String, at now: Date) throws -> Report {
        guard data.count <= AppConfig.maxRequestBodyBytes else {
            throw HookPayloadError.bodyTooLarge(data.count)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return Report(sessions: [], windows: [])
        }
        if let records = parsed as? [[String: Any]] {
            return Report(sessions: records.compactMap { session(from: $0, host: host) }, windows: [])
        }
        guard let object = parsed as? [String: Any] else { return Report(sessions: [], windows: []) }
        let records = (object["sessions"] as? [[String: Any]]) ?? []
        let locks = (object["windows"] as? [[String: Any]]) ?? []
        return Report(
            sessions: records.compactMap { session(from: $0, host: host) },
            windows: windows(from: locks, at: now)
        )
    }

    /// The node's editor windows, kept by the rule `IDEWindowReader` applies to
    /// this Mac's: a live editor process, or failing a usable pid, a young lock.
    /// The node judged liveness, because the pid means nothing here.
    private static func windows(from locks: [[String: Any]], at now: Date) -> [IDEWindow] {
        var alive: Set<Int> = []
        let candidates = locks.compactMap { lock -> IDEWindow? in
            guard let folders = (lock["workspaceFolders"] as? [Any])?
                    .compactMap({ $0 as? String }).filter({ $0.hasPrefix("/") }),
                  !folders.isEmpty
            else { return nil }
            let pid = (lock["pid"] as? NSNumber)?.intValue ?? 0
            if pid > 0, lock["alive"] as? Bool == true { alive.insert(pid) }
            let epoch = (lock["mtimeEpoch"] as? NSNumber)?.doubleValue ?? 0
            return IDEWindow(
                workspaceFolders: folders,
                ideName: (lock["ideName"] as? String) ?? "",
                pid: pid,
                lockModifiedAt: Date(timeIntervalSince1970: epoch)
            )
        }
        return candidates.filter { $0.isUsable(at: now, alivePids: alive) }
    }

    /// `nil` for a record we cannot use, which is skipped rather than thrown.
    private static func session(from record: [String: Any], host: String) -> LiveSession? {
        guard let sessionId = string(record, "sessionId"),
              let cwd = string(record, "cwd"),
              cwd.hasPrefix("/")
        else {
            // A relative path would mean guessing which root it hangs off, on a
            // filesystem that is not ours to guess about.
            return nil
        }

        let pid = (record["pid"] as? NSNumber)?.intValue ?? 0
        guard pid > 0 else { return nil }

        // The node's clock, not this machine's: the whole point of asking it.
        let epoch = (record["activityEpoch"] as? NSNumber)?.doubleValue ?? 0

        // The same scanner the Mac runs on its own transcripts, over the
        // miniature the probe sent. One rule, one implementation, one set of
        // tests — the alternative was a copy of it in Python on a machine we do
        // not update, which is how two implementations of one rule start
        // disagreeing without anybody noticing.
        let context = (record["contextTail"] as? String)
            .flatMap { $0.isEmpty ? nil : ContextScanner.read(tail: $0) }

        return LiveSession(
            pid: pid,
            sessionId: sessionId,
            cwd: cwd,
            entrypoint: string(record, "entrypoint"),
            name: string(record, "name"),
            kind: string(record, "kind"),
            modifiedAt: Date(timeIntervalSince1970: epoch),
            host: host,
            context: context
        )
    }

    private static func string(_ record: [String: Any], _ key: String) -> String? {
        (record[key] as? String)?.trimmed.nilIfEmpty
    }
}
