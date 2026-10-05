import LampBoardCore
import Foundation

/// What went wrong talking to another machine, said in words that name the fix.
enum RemoteCommandError: LocalizedError, Equatable {
    /// ssh could not get in: no route, refused key, unknown host key.
    case unreachable(String)
    /// Connected, but the command failed there.
    case remoteFailure(String)
    /// The machine answered something this app cannot read.
    case badAnswer(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            return "ssh could not reach the machine: \(detail)"
        case .remoteFailure(let detail):
            return "the command failed on the machine: \(detail)"
        case .badAnswer(let detail):
            return "the machine answered something unexpected: \(detail)"
        case .timeout:
            return "the machine did not answer in time"
        }
    }

    /// One line for a status field.
    var short: String {
        switch self {
        case .unreachable(let detail):
            if detail.localizedCaseInsensitiveContains("IDENTIFICATION HAS CHANGED") {
                return "host key changed: remove its old line from ~/.ssh/known_hosts"
            }
            if detail.localizedCaseInsensitiveContains("permission denied") {
                return "ssh refused the key (BatchMode: no password prompt is possible)"
            }
            if detail.localizedCaseInsensitiveContains("host key") {
                return "host key not accepted: connect once from a terminal"
            }
            if detail.localizedCaseInsensitiveContains("python3") {
                return "python3 is missing there"
            }
            return "unreachable: \(detail.prefix(80))"
        case .remoteFailure(let detail): return "failed there: \(detail.prefix(80))"
        case .badAnswer(let detail): return "unexpected answer: \(detail.prefix(80))"
        case .timeout: return "no answer in time"
        }
    }
}

/// Runs a Python script on another machine over ssh and returns its stdout.
///
/// One shape for every remote operation — probe, inspect, install, check — so the
/// safety rules live in one place: `BatchMode=yes` (a host wanting a password
/// fails in a second instead of waiting for a prompt nobody will see), a connect
/// timeout, and a hard kill at twice it, so a half-open connection to a sleeping
/// node cannot hold anything. The script goes in on stdin; nothing is installed.
///
/// Blocking, by design: callers run it off the main thread.
enum RemoteCommand {

    /// What every ssh this app starts carries, before anything else.
    ///
    /// The user's `~/.ssh/config` for that host applies to us too, and a dev box
    /// commonly has `ForwardAgent yes`. A compromised node must not get the Mac's
    /// agent, X11, or a `LocalCommand` run here: `-a -x` and the two options say so
    /// explicitly. `ClearAllForwardings` is **not** used — it would also clear the
    /// `-R` the tunnel is made of.
    static let hardening: [String] = [
        "-a", "-x",
        "-o", "ForwardAgent=no",
        "-o", "PermitLocalCommand=no",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
    ]

    /// - Parameter maxOutput: past this many bytes the far side is answering more
    ///   than it was asked, and ssh is stopped: another machine's answer is not
    ///   let fill this one's memory.
    static func runPython(
        on host: String, script: String, timeout: TimeInterval = AppConfig.remoteProbeTimeout, maxOutput: Int? = nil
    ) -> Result<Data, RemoteCommandError> {
        precondition(RemoteHostList.isUsable(host), "host names are validated before they get here")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = hardening + [
            "-o", "ConnectTimeout=\(Int(timeout))",
            host, "python3", "-",
        ]

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // The exit is learnt from a termination handler set before the launch,
        // never from `waitUntilExit()` on the reading thread. That call waits on
        // a run loop the global queue's threads do not turn, and when ssh had
        // already exited by the time it was reached it could wait for good:
        // measured on 29 September 2026, an ssh that finished in one second, with
        // both pipes at end-of-file, was reported as timed out after fifteen —
        // every other time, and more often the larger the answer. The allowance
        // strip lost the node's line that way, silently.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }

        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()

        let deadline = DispatchTime.now() + timeout * 2 + 5
        let done = DispatchGroup()
        done.enter()
        var stdout = Data(), stderr = Data()
        DispatchQueue.global().async {
            if let maxOutput {
                while let chunk = try? output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                    stdout.append(chunk)
                    if stdout.count > maxOutput { process.terminate(); stdout = Data(); break }
                }
            } else {
                stdout = output.fileHandleForReading.readDataToEndOfFile()
            }
            stderr = errors.fileHandleForReading.readDataToEndOfFile()
            exited.wait()
            done.leave()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return .failure(.timeout)
        }

        let errorText = String(decoding: stderr, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("Pseudo-terminal") && !$0.hasPrefix("Warning: Permanently added") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch process.terminationStatus {
        case 0:
            return .success(stdout)
        case 255:
            return .failure(.unreachable(errorText.isEmpty ? "exit 255" : errorText))
        default:
            return .failure(.remoteFailure(errorText.isEmpty ? "exit \(process.terminationStatus)" : errorText))
        }
    }

    /// The same, expecting a JSON object back.
    static func runPythonForObject(
        on host: String, script: String, timeout: TimeInterval = AppConfig.remoteProbeTimeout
    ) -> Result<[String: Any], RemoteCommandError> {
        runPython(on: host, script: script, timeout: timeout).flatMap { data in
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let object = parsed as? [String: Any]
            else {
                return .failure(.badAnswer(String(decoding: data.prefix(120), as: UTF8.self)))
            }
            return .success(object)
        }
    }
}
