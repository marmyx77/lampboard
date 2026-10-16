import Foundation

/// One look at a machine that does not serve `v1` yet (the Linux machine until
/// its service arrives), over the phone's own ssh (D176): the Mac's probe —
/// `RemoteProbeScript`, the same Python, read back by the same
/// `RemoteSessionsDecoder` — and tmux's sessions, in a single command.
///
/// Read-only by construction: the probe reads Claude Code's files and asks tmux
/// for its panes; `list-sessions` reads; nothing is written, installed or left
/// behind, and no tmux server is started where there is none.
public struct V1ProbeReading: Equatable, Sendable {
    public let report: RemoteSessionsDecoder.Report
    /// tmux's sessions on that machine; `nil` when it has no tmux at all, which
    /// is not the same as none running.
    public let tmuxSessions: [TmuxSessionInfo]?

    public init(report: RemoteSessionsDecoder.Report, tmuxSessions: [TmuxSessionInfo]?) {
        self.report = report
        self.tmuxSessions = tmuxSessions
    }

    /// The line between the probe's answer and tmux's.
    public static let separator = "--lampboard-tmux--"
    /// What the second part says on a machine without tmux.
    public static let noTmux = "--lampboard-no-tmux--"

    static let sessionFormat = "#{session_attached}\t#{session_windows}\t#{session_activity}\t#{session_created}\t#{session_name}"

    /// The one command: one `sh -c`, whatever the login shell, the probe handed
    /// to `python3 -c` as a single quoted word. `-B`: the Python of Apple's
    /// developer tools otherwise fills `~/Library/Caches/com.apple.python` with
    /// bytecode of its own library (measured on the test Mac), a write the look
    /// promised not to make.
    public static func command(server: TmuxSizeRule.Server = .default) -> String {
        let probe = "python3 -B -c " + NewSession.shellQuoted(RemoteProbeScript.script)
        let tmux = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; "
            + "if command -v tmux >/dev/null 2>&1; then \(server.tmux) list-sessions -F '\(sessionFormat)' 2>/dev/null; "
            + "else echo '\(noTmux)'; fi; true"
        return NewSession.posix(probe + "; echo; echo '\(separator)'; " + tmux)
    }

    /// The answer read back; `nil` when it is not one (no Python, a cut
    /// answer): that is a machine that did not answer, never an empty one.
    public static func parse(_ output: String, host: String, at now: Date) -> V1ProbeReading? {
        let lines = output.components(separatedBy: "\n")
        guard let cut = lines.firstIndex(of: separator) else { return nil }
        let probe = Data(lines[..<cut].joined(separator: "\n").utf8)
        guard (try? JSONSerialization.jsonObject(with: probe)) is [String: Any],
              let report = try? RemoteSessionsDecoder.report(from: probe, host: host, at: now)
        else { return nil }
        let rest = lines[(cut + 1)...].filter { !$0.isEmpty }
        if rest.contains(noTmux) { return V1ProbeReading(report: report, tmuxSessions: nil) }
        return V1ProbeReading(report: report, tmuxSessions: rest.compactMap(TmuxSessionInfo.init(line:)))
    }
}

/// One tmux session, as `list-sessions` says: what the phone can open a
/// terminal on.
public struct TmuxSessionInfo: Equatable, Sendable {
    public let name: String
    /// How many clients are attached now.
    public let attachedClients: Int
    public let windows: Int
    public let lastActivity: Date?
    public let created: Date?

    public init(name: String, attachedClients: Int, windows: Int, lastActivity: Date?, created: Date?) {
        self.name = name
        self.attachedClients = attachedClients
        self.windows = windows
        self.lastActivity = lastActivity
        self.created = created
    }

    /// A line of `V1ProbeReading.sessionFormat`; the name last, so that a tab
    /// in it cannot shift the numbers.
    init?(line: String) {
        let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, let attached = Int(fields[0]), let windows = Int(fields[1]),
              TmuxSizeRule.isSessionName(fields[4]) else { return nil }
        self.init(name: fields[4], attachedClients: attached, windows: windows,
                  lastActivity: Double(fields[2]).map(Date.init(timeIntervalSince1970:)),
                  created: Double(fields[3]).map(Date.init(timeIntervalSince1970:)))
    }
}
