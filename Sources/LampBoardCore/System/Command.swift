import Foundation

/// Runs a command line tool with a deadline, and reads it without deadlocking.
///
/// WHY THIS EXISTS
/// The obvious three lines —
///
///     try process.run()
///     let data = pipe.fileHandleForReading.readDataToEndOfFile()
///     process.waitUntilExit()
///
/// — have two failure modes, and both of them are silence rather than an error.
///
/// The first is the deadline that is not there. `waitUntilExit` waits forever,
/// so a tool that hangs takes the caller with it: the updater sat on `spctl`
/// with no way to tell a slow signature check from a stuck one, and nothing was
/// ever going to appear on screen. A failure that reports nothing is worse than
/// a failure that reports the wrong thing, because there is no thread to pull.
///
/// The second is the pipe. A pipe holds about 64 KB; a tool that writes more
/// than that blocks in `write` until somebody drains it, and a caller that waits
/// for the process before reading waits for a process that is waiting for the
/// caller. Neither side is broken and neither side moves. Reading on another
/// thread, as this does, is what makes the deadline the only thing that can stop
/// the wait — which is the point.
///
/// It lives in Core rather than next to its caller so that both failures can be
/// demonstrated by a test instead of argued about: `CommandSuite` runs a tool
/// that sleeps and one that writes two hundred kilobytes.
public enum Command {

    /// What a finished command left behind.
    public struct Result: Equatable, Sendable {
        public let status: Int32
        /// Standard output and standard error, interleaved as they arrived.
        ///
        /// Together on purpose: the tools this runs put the sentence explaining
        /// a refusal on one or the other with no discernible rule, and reading
        /// only the first loses the reason precisely when it is needed.
        public let output: String

        public init(status: Int32, output: String) {
            self.status = status
            self.output = output
        }

        public var succeeded: Bool { status == 0 }
    }

    public enum Failure: Error, Equatable {
        /// The tool could not be started at all — usually it is not there.
        case couldNotStart(tool: String, reason: String)
        /// It started, and was still running when the deadline passed.
        case timedOut(tool: String, seconds: Int)

        public var explanation: String {
            switch self {
            case .couldNotStart(let tool, let reason):
                return "\(tool) could not be run: \(reason)"
            case .timedOut(let tool, let seconds):
                return "\(tool) did not answer within \(seconds) seconds"
            }
        }
    }

    /// Somewhere for the reading thread to put what it read.
    ///
    /// The semaphore below is the handoff: nothing touches `bytes` until the
    /// thread that fills it has signalled, and nothing writes it afterwards.
    private final class Buffer: @unchecked Sendable {
        var bytes = Data()
    }

    /// How long to let a killed process finish dying before insisting.
    private static let graceAfterTerminate: TimeInterval = 2

    /// Runs the tool and returns what it said.
    ///
    /// - Parameters:
    ///   - tool: absolute path. No shell is involved, so an argument containing
    ///     a space or a quote is an argument and never a command.
    ///   - arguments: passed as a vector, for the same reason.
    ///   - deadline: seconds. On expiry the process is asked to stop, then made
    ///     to, and `Failure.timedOut` is thrown.
    ///   - capturingStandardError: `false` sends it to `/dev/null`. Off only
    ///     where the output is **parsed** — `tmux list-panes`, `lsof`, `ssh -G`
    ///     — because a warning printed on the error stream would arrive
    ///     interleaved with the data and be read as a record. Everywhere else it
    ///     stays on: that is where a tool puts the sentence explaining a refusal.
    ///   - input: written to the tool's standard input, then closed. For what
    ///     must not be an argument: arguments are readable by any process on the
    ///     Mac with `ps`, standard input is not.
    ///   - directory: the tool's working directory.
    ///   - environment: variables set over the inherited ones; `nil` takes one away.
    ///   - launched: told the process id once the tool is running, so a caller
    ///     that is itself shutting down can stop it instead of leaving it behind.
    public static func run(
        _ tool: String,
        _ arguments: [String] = [],
        deadline: TimeInterval,
        capturingStandardError: Bool = true,
        input: Data? = nil,
        directory: URL? = nil,
        environment: [String: String?] = [:],
        launched: ((pid_t) -> Void)? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            environment.forEach { merged[$0.key] = $0.value }
            process.environment = merged
        }
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = capturingStandardError ? pipe : FileHandle.nullDevice

        let buffer = Buffer()
        let finished = DispatchSemaphore(value: 0)

        // The exit is learnt from a handler set before the launch. The pipe's
        // end-of-file was once thought to make `waitUntilExit()` safe here; the
        // same pattern in the ssh runner hung for fifteen seconds on a process
        // that had exited, pipes closed (29 September 2026, see `RemoteCommand`).
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // Started before the process, so that a tool which floods its output
        // immediately never finds nobody at the other end of the pipe.
        DispatchQueue.global(qos: .userInitiated).async {
            buffer.bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            // The reading thread is parked on a pipe nobody will ever write to;
            // closing this end sends it the end-of-file it is waiting for.
            try? pipe.fileHandleForWriting.close()
            throw Failure.couldNotStart(tool: tool, reason: error.localizedDescription)
        }

        launched?(process.processIdentifier)
        if let input, let inputPipe { feed(input, into: inputPipe.fileHandleForWriting) }

        if finished.wait(timeout: .now() + deadline) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + graceAfterTerminate) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + graceAfterTerminate)
            }
            throw Failure.timedOut(tool: tool, seconds: Int(deadline.rounded()))
        }

        // The pipe reached end-of-file, so the process has let go of it and is
        // exiting or has exited; the handler says which, within the grace.
        if exited.wait(timeout: .now() + graceAfterTerminate) == .timedOut {
            throw Failure.timedOut(tool: tool, seconds: Int(deadline.rounded()))
        }

        return Result(
            status: process.terminationStatus,
            output: String(decoding: buffer.bytes, as: UTF8.self)
        )
    }

    /// Writes the input on its own thread, for the same reason the output is
    /// read on one: past what a pipe holds, a write waits for a reader, and the
    /// tool may be waiting for us. A tool that exits without reading closes its
    /// end, and writing into a closed pipe sends `SIGPIPE`, whose default is to
    /// end the process that wrote — this app. `F_SETNOSIGPIPE` turns that into
    /// an error on this one write, which is all it deserves.
    private static func feed(_ input: Data, into handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: input)
            try? handle.close()
        }
    }
}
