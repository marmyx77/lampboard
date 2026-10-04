import LampBoardCore
import Foundation

/// Runs LampMaster's `claude`, for a round or for a question.
enum LampMasterRunner {

    /// Where `claude` is. A GUI application's `PATH` is four system folders,
    /// none of them where anybody installs it, so the usual places come first.
    /// Under `LAMPBOARD_HOME` only the fake home's own is looked at: a test that
    /// forgot its fake `claude` must fail, not spend the real one.
    static func executable() -> String? {
        let own = AppConfig.homeDirectory.appendingPathComponent(".local/bin/claude").path
        let candidates = AppConfig.isUsingHomeOverride ? [own] : [own, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The `claude` processes in flight: a round and a question can run at once.
    static let running = RunningProcesses()

    /// The run, and what `claude` printed: kept with a round's frame, and where
    /// a question's answer is read from.
    static func run(
        message: String, model: String, system: String, schema: String, directory: URL, timeout: TimeInterval
    ) -> (LampMasterRun, String) {
        guard let tool = executable() else { return (.failed(.notLaunched), "") }
        let started = Date()
        let launched = LaunchedPid()
        defer { launched.pid.map(running.release) }
        do {
            let result = try Command.run(
                tool, LampMasterCommand.arguments(model: model, system: system, schema: schema), deadline: timeout,
                capturingStandardError: false, input: Data(message.utf8), directory: directory,
                launched: { launched.pid = $0; running.hold($0) }
            )
            let run = LampMasterRun.read(Data(result.output.utf8))
            let seconds = run.seconds ?? Date().timeIntervalSince(started)
            return (LampMasterRun(advice: run.advice, failure: run.failure, inputTokens: run.inputTokens,
                                  outputTokens: run.outputTokens, costUSD: run.costUSD, seconds: seconds), result.output)
        } catch Command.Failure.timedOut {
            return (.failed(.timedOut, seconds: Date().timeIntervalSince(started)), "")
        } catch {
            return (.failed(.notLaunched), "")
        }
    }

    /// Where the launch hands its pid to the cleanup, across the closure.
    private final class LaunchedPid: @unchecked Sendable {
        var pid: pid_t?
    }
}

/// The process ids of running tools, held only while they run: a pid kept
/// after its process ended could name somebody else's by the time it is used.
final class RunningProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    func hold(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pids.insert(pid)
    }

    func release(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pids.remove(pid)
    }

    /// `SIGTERM` to each, the way `Command` asks first.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        for pid in pids { kill(pid, SIGTERM) }
        pids.removeAll()
    }
}

/// LampMaster's state for the server's queue, the way `SnapshotBox` holds the
/// rows: deposited when it changes, collected when asked, nobody waiting.
final class LampMasterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data("{}".utf8)

    func replace(with data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stored = data
    }

    func current() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
