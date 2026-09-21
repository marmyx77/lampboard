import LampBoardCore
import Foundation

/// Reads the live sessions of another machine over ssh.
///
/// **Why reading and not receiving.** The obvious route — install the hook on the
/// node and let it post here — needs `POST /signal` open on the network, and that
/// endpoint carries no token: it would put unauthenticated state injection on the
/// tailnet. Reading needs nothing open, no token to distribute, and no new
/// surface. The cost is that color changes arrive on the next poll instead of
/// instantly, which for a machine you are not looking at is the right trade.
///
/// It also matches what the distributed-brain plan already says out loud:
/// local-first with aggregation, and no single point of failure. A node that is
/// down costs a poll that returns nothing, never a hang.
struct RemoteSessionReader {
    private let host: String
    private let timeout: TimeInterval

    init(host: String, timeout: TimeInterval = AppConfig.remoteProbeTimeout) {
        self.host = host
        self.timeout = timeout
    }

    /// The host's live sessions, or `nil` if the host could not be asked.
    ///
    /// The distinction is the whole point of the signature. `[]` means *asked, and
    /// there is nothing running*; `nil` means *no answer*. Collapsing them into an
    /// empty list is what would let a sleeping node or a dropped VPN erase rows
    /// that are perfectly alive — the same mistake as reading a file's timestamp
    /// and calling it a heartbeat.
    func readLiveSessions() -> [LiveSession]? {
        read()?.sessions
    }

    /// The host's live sessions **and** the editor windows open there, or `nil`
    /// if the host could not be asked. The windows are what a remote row's folder
    /// is resolved against (D51).
    func read() -> RemoteSessionsDecoder.Report? {
        guard let output = run() else { return nil }
        guard let report = try? RemoteSessionsDecoder.report(from: output, host: host, at: Date()) else {
            Diagnostics.log("remote \(host): unparsable answer, \(output.count) bytes")
            return nil
        }
        return report
    }

    // MARK: - Internal

    /// Runs the probe and returns stdout, or `nil` if anything went wrong.
    ///
    /// `BatchMode=yes` so a host that wants a password fails in a second instead
    /// of waiting for a prompt nobody will ever see, and a hard timeout because a
    /// half-open TCP connection to a sleeping node would otherwise hold the poll
    /// open for minutes.
    private func run() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = RemoteCommand.hardening + [
            "-o", "ConnectTimeout=\(Int(timeout))",
            host, "python3", "-",
        ]

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            Diagnostics.log("remote \(host): ssh would not start: \(error.localizedDescription)")
            return nil
        }

        input.fileHandleForWriting.write(Data(RemoteProbeScript.script.utf8))
        input.fileHandleForWriting.closeFile()

        // Read before waiting: a pipe that fills up while we wait deadlocks, and
        // the answer for a node with a dozen sessions is comfortably big enough
        // for that to matter.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()

        guard waitOrKill(process) else { return nil }

        guard process.terminationStatus == 0 else {
            let message = String(data: failure, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Named, not swallowed: a host that stops answering has to be visible
            // in the log, or the rows just quietly stop appearing.
            Diagnostics.log(
                "remote \(host): exit \(process.terminationStatus), \(message.prefix(160))"
            )
            return nil
        }
        return data
    }

    /// Waits for the probe, and kills it if it overstays.
    private func waitOrKill(_ process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(timeout * 2)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        guard !process.isRunning else {
            process.terminate()
            Diagnostics.log("remote \(host): probe killed after \(Int(timeout * 2))s")
            return false
        }
        return true
    }
}
