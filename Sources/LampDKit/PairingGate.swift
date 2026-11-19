import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Who may run `lampd devices add` (V-25 of the node's security review,
/// 19 November 2026).
///
/// WHY. "Never `lampd devices add` without Marco" was only a sentence in
/// `~/AGENTS.md`: one command, no question asked, and a phone's action key — a
/// shell of the machine's owner, reachable from the tailnet — is written into
/// `authorized_keys`. The probable caller that is not the owner is an agent of
/// this machine following an instruction it read somewhere: a Claude Code
/// session, Hermes' terminal. Neither has a terminal on its standard input.
///
/// THE TWO WAYS IN. The owner at a terminal (gesture 17), and the Mac's carry
/// (W5, §2.4): after the person's yes on the Mac, `ssh <node> python3 -` runs
/// `lampd devices add` through `subprocess`, with no terminal. So a pipe is not
/// enough to refuse: what is refused is a pipe with no ssh session right in
/// front of it, through at most `maxCarriers` shells or Pythons. An agent in
/// tmux has a tmux server there and no sshd; an agent started in an ssh session
/// has its own runtime (`claude`, `node`, `codex`) between; a service has
/// systemd.
///
/// WHAT IT IS NOT. A process of the owner can still give itself a terminal, or
/// open an ssh session to this machine; it can also write `authorized_keys`
/// without lampd. This is a brake on the probable case and a line in lampd's
/// log for every case, not a lock: the lock is the review of the keys (the
/// Quadro's, package 9 of the review).
public enum PairingGate {

    public enum Verdict: Equatable, Sendable {
        /// The standard input is a terminal: the owner typing.
        case terminal
        /// No terminal, but an ssh session right in front: the Mac's carry.
        case sshSession
        /// Neither: refused, with the reason said to the caller.
        case refused(String)

        public var allowed: Bool {
            if case .refused = self { return false }
            return true
        }
    }

    /// Processes that may stand between lampd and the ssh session: the shell
    /// sshd starts, and the Python the Mac's carry runs.
    public static let maxCarriers = 3

    /// The verdict for a caller whose ancestry, nearest first, is `ancestry`
    /// (the `comm` of each process, as `/proc/<pid>/comm` gives it).
    public static func verdict(stdinIsTerminal: Bool, ancestry: [String]) -> Verdict {
        if stdinIsTerminal { return .terminal }
        var carriers = 0
        for name in ancestry {
            if isSSHSession(name) { return .sshSession }
            guard isCarrier(name), carriers < maxCarriers else { break }
            carriers += 1
        }
        let chain = ancestry.prefix(6).joined(separator: " < ")
        return .refused("pairing a phone needs a terminal (the owner) or the Mac's ssh (its carry); "
                        + "this caller has neither: \(chain.isEmpty ? "no parent seen" : chain)")
    }

    static func isSSHSession(_ name: String) -> Bool {
        name == "sshd" || name == "sshd-session" || name.hasPrefix("sshd:")
    }

    static func isCarrier(_ name: String) -> Bool {
        ["sh", "bash", "dash", "zsh"].contains(name) || name.hasPrefix("python")
    }

    /// The parent's pid from a line of `/proc/<pid>/stat`. The name sits in
    /// parentheses and may hold spaces and parentheses itself, so the fields are
    /// read after the last `)`.
    public static func parentPid(statLine: String) -> Int32? {
        guard let close = statLine.lastIndex(of: ")") else { return nil }
        let fields = statLine[statLine.index(after: close)...].split(separator: " ")
        guard fields.count >= 2, let ppid = Int32(fields[1]) else { return nil }
        return ppid
    }

    /// The names of this process's ancestors, nearest first, read from `/proc`.
    /// Empty where there is no `/proc` (the Mac): then only a terminal pairs.
    public static func ancestry(from start: Int32 = getppid(), limit: Int = 12,
                                proc: String = "/proc") -> [String] {
        var names: [String] = []
        var pid = start
        while pid > 1, names.count < limit {
            guard let comm = try? String(contentsOfFile: "\(proc)/\(pid)/comm", encoding: .utf8),
                  let stat = try? String(contentsOfFile: "\(proc)/\(pid)/stat", encoding: .utf8) else { break }
            names.append(comm.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let parent = parentPid(statLine: stat), parent != pid else { break }
            pid = parent
        }
        return names
    }

    /// The line lampd's log keeps for every request, allowed or not: who asked,
    /// from where, and through what.
    public static func logLine(id: String, name: String, verdict: Verdict, ancestry: [String],
                               environment: [String: String], uid: UInt32 = getuid()) -> String {
        let outcome: String
        switch verdict {
        case .terminal: outcome = "allowed (a terminal)"
        case .sshSession: outcome = "allowed (an ssh session, the Mac's carry)"
        case .refused: outcome = "refused"
        }
        let ssh = environment["SSH_CONNECTION"].flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        let user = environment["USER"] ?? environment["LOGNAME"] ?? "?"
        return "devices add \(id) (\(name)): \(outcome); uid \(uid) \(user), ssh \(ssh), "
            + "parents \(ancestry.prefix(6).joined(separator: " < "))"
    }
}
