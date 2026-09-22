import LampBoardCore
import Foundation

/// `lampboard usage`: what the allowance strip would draw, asked once.
///
/// It exists for the same reason `remote check` prints the node's windows: the
/// strip has one line per account and a hover for the rest, and when it is empty
/// or wrong there is nothing to read the figures against. This prints the whole
/// gathering, the way the card shows it, and says why there is nothing when
/// there is nothing — a token that aged out, a keychain that would not answer.
///
/// It is also the place a person can watch the credential being read without a
/// dialog: the read goes through `/usr/bin/security`, the tool Claude Code writes
/// the item with (D52), and this command is the quickest way to see that macOS
/// asks nothing.
extension CommandLineInterface {

    static func runUsage() -> Int32 {
        let hosts = Preferences().remoteHosts
        print("Asking Anthropic, signed with the token Claude Code keeps in the keychain"
              + (hosts.isEmpty ? "…" : ", and each node on the node…"))

        // The reader is async and the command line is not: wait for it, with the
        // deadline the reader already enforces on every request it makes.
        let finished = DispatchSemaphore(value: 0)
        let box = GatheringBox()
        Task.detached {
            box.gathering = await AccountLimitsReader.readAll(hosts: hosts)
            finished.signal()
        }
        finished.wait()
        guard let gathering = box.gathering else { return 1 }

        if gathering.reports.isEmpty {
            print(gathering.quiet ?? "nothing to draw")
            return 1
        }
        let now = Date()
        for report in gathering.reports {
            print("\n\(report.label)  (read on \(report.machine), "
                  + "\(ShortSpan.label(seconds: now.timeIntervalSince(report.limits.readAt))) ago)")
            for limit in report.limits.limits {
                let reset = limit.resetsAt.map { resetsAt -> String in
                    let remaining = resetsAt.timeIntervalSince(now)
                    return remaining > 0 ? "resets in \(ShortSpan.label(seconds: remaining))" : "resetting"
                } ?? "no reset"
                print("  \(limit.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(String(limit.percent).padding(toLength: 3, withPad: " ", startingAt: 0))%  \(reset)")
            }
        }
        if let quiet = gathering.quiet { print("\n\(quiet)") }
        return 0
    }

    /// Carries the answer across the wait. A class, because the closure runs on
    /// another thread and the semaphore is what orders the two.
    private final class GatheringBox: @unchecked Sendable {
        var gathering: AccountLimitsReader.Gathering?
    }
}
