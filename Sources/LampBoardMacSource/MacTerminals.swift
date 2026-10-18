#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import LampBoardCore

/// What the phone's terminals and named actions run on the Mac, in the app's
/// own context (§2.6): the PATH with Homebrew, the app's permissions, the same
/// commands the Hub runs. Built here from a target or a `NodeAction`, never
/// from text the phone sent.
public struct MacRunner: Sendable {
    /// tmux and the arguments that pick its server: `[path]` for the person's
    /// own, `[path, "-L", name]` for a test's.
    public var tmux: [String]
    /// What every child gets, and nothing else (`LiveLaunch.environment`).
    public var environment: [String: String]
    public var home: String
    /// Whether the person turned on Bypass from the start on this Mac (D169).
    public var bypassAllowed: @Sendable () -> Bool
    /// The Hub's own terminal for a background session, when it has one open:
    /// the bridge shares it rather than starting a second `claude attach` (D130).
    public var hub: MacHubTerminals?
    /// The colours of the Mac's terminal, *Like my VS Code* included, as JSON.
    public var palette: @Sendable () -> [UInt8]
    /// The attaches this process started, by job: never two (counted).
    public let attaches: MacAttachLedger

    public init(tmux: [String], environment: [String: String], home: String,
                bypassAllowed: @escaping @Sendable () -> Bool = { false }, hub: MacHubTerminals? = nil,
                palette: @escaping @Sendable () -> [UInt8] = { Array("{}".utf8) },
                attaches: MacAttachLedger = MacAttachLedger()) {
        self.tmux = tmux
        self.environment = environment
        self.home = home
        self.bypassAllowed = bypassAllowed
        self.hub = hub
        self.palette = palette
        self.attaches = attaches
    }

    var environmentList: [String] { environment.map { "\($0.key)=\($0.value)" }.sorted() }

    // MARK: - Terminals

    /// What a terminal on `target` runs: tmux always with `-u` (S-S: an app
    /// opened from the Dock has no `LANG`, and ❯ would arrive as `_`).
    public func terminalCommand(_ target: MacTerminalTarget) -> Result<[String], MacSourceError> {
        switch target {
        case .tmux(let session):
            guard tmuxSessions().contains(session) else { return .failure(.refused("no tmux session \(session) on this Mac")) }
            return .success(tmuxArguments(["-u", "attach-session", "-t", "=" + session]))
        case .job(let job):
            guard let command = NodeTerminalCommand.background(job: job).command else { return .failure(.refused("not a job")) }
            return .success(["/bin/sh", "-c", command])
        case .shell(let root):
            guard let command = NodeTerminalCommand.shell(root: root).command else { return .failure(.refused("not a project")) }
            return .success(["/bin/sh", "-c", command])
        }
    }

    /// The names of the Mac's tmux sessions, now.
    public func tmuxSessions() -> Set<String> {
        let result = MacProcess.run(tmuxArguments(["list-sessions", "-F", "#{session_name}"]), environment: environmentList)
        guard result.status == 0 else { return [] }
        return Set(result.output.split(separator: "\n").map(String.init))
    }

    /// Q7 through the bridge (E14): the phone goes to the background, and its
    /// own tmux clients — the bridge's children, whose pids are tmux's own
    /// `#{client_pid}` — stop counting for the size and are detached. Never
    /// `resize-window`.
    public func background(clients pids: Set<pid_t>, log: (String) -> Void = { _ in }) -> [String] {
        let listed = MacProcess.run(tmuxArguments(["list-clients", "-F", "#{client_pid}\t#{client_name}"]), environment: environmentList)
        var done: [String] = []
        for line in listed.output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2, let pid = pid_t(fields[0]), pids.contains(pid) else { continue }
            let result = MacProcess.run(tmuxArguments(["refresh-client", "-t", fields[1], "-f", "ignore-size", ";",
                                                       "detach-client", "-t", fields[1]]), environment: environmentList)
            if result.status == 0 { done.append(fields[1]) } else { log("background: tmux said \(result.status): \(result.output)") }
        }
        return done
    }

    /// Always with `-u`: the app opened from the Dock has no `LANG`, and
    /// without it tmux writes a tab, a ❯ or an emoji in a name as `_` (S-S,
    /// the memory of a tmux without a locale) — a name read that way would never match.
    func tmuxArguments(_ arguments: [String]) -> [String] {
        tmux + (arguments.first == "-u" ? arguments : ["-u"] + arguments)
    }

    // MARK: - Named actions

    /// The command of `action` as a node would run it, or why there is none.
    public func command(_ action: NodeAction) -> Result<[String], MacSourceError> {
        switch action.command(bypassAllowed: bypassAllowed()) {
        case .success(let line): return .success(["/bin/sh", "-c", line])
        case .failure(.bypassOff): return .failure(.refused("Bypass from the start is turned off on this Mac"))
        case .failure(.invalid(let why)): return .failure(.refused(why))
        }
    }
}

/// The Hub's side of a shared terminal (the app implements it).
public protocol MacHubTerminals: Sendable {
    /// The Hub's open terminal on `job`, shared with the phone; `nil` when the
    /// Hub has none open.
    func share(job: String) -> MacSharedTerminal?
}

/// A terminal the Hub has open, seen from the bridge: its bytes as they come,
/// and the phone's keys into it.
public protocol MacSharedTerminal: AnyObject, Sendable {
    func start(send: @escaping @Sendable ([UInt8]) -> Void, ended: @escaping @Sendable () -> Void)
    func write(_ bytes: [UInt8])
    /// The phone went: the Hub's terminal stays, only the sharing ends.
    func stop()
}

/// Which background sessions have a `claude attach` started by this app, and
/// how many were ever started for each: the gate counts them (D130, «mai un
/// secondo claude attach»).
public final class MacAttachLedger: @unchecked Sendable {
    public enum Holder: String, Sendable { case hub, bridge }

    private let lock = NSLock()
    private var holders: [String: Holder] = [:]
    private var started: [String: Int] = [:]

    public init() {}

    /// Takes `job` for `holder`; `false` when someone holds it already.
    public func take(_ job: String, for holder: Holder) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard holders[job] == nil else { return false }
        holders[job] = holder
        started[job, default: 0] += 1
        return true
    }

    public func release(_ job: String, by holder: Holder) {
        lock.lock()
        defer { lock.unlock() }
        if holders[job] == holder { holders[job] = nil }
    }

    public func holder(of job: String) -> Holder? {
        lock.lock()
        defer { lock.unlock() }
        return holders[job]
    }

    /// How many attaches were started for `job` since the app started.
    public func count(_ job: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return started[job] ?? 0
    }

    /// How many are running now, for every job.
    public var running: Int {
        lock.lock()
        defer { lock.unlock() }
        return holders.count
    }
}

/// A short command and what it printed, bounded in time and size.
///
/// `posix_spawn` and `waitpid`, not `Process`: on Linux, Foundation's `Process`
/// was seen never to learn that a tmux client had ended (it stayed a zombie
/// nobody reaped), and the same code must hold on both systems. Output goes to
/// a file, not a pipe: a command that starts a tmux server leaves the server
/// holding it, and a pipe would never reach its end while that server lives.
public enum MacProcess {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    public static func run(_ argv: [String], environment: [String], directory: String? = nil,
                           deadline: TimeInterval = 10, limit: Int = 1 << 20) -> Result {
        guard let executable = argv.first, executable.hasPrefix("/") else { return Result(status: 127, output: "not an absolute path") }
        let outputPath = NSTemporaryDirectory() + "lampboard-mac-\(getpid())-\(UInt64.random(in: 0...UInt64.max)).out"
        defer { unlink(outputPath) }
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
        let cArguments = argv.map { strdup($0) } + [nil]
        let cEnvironment = environment.map { strdup($0) } + [nil]
        defer {
            cArguments.forEach { free($0) }
            cEnvironment.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, nil, cArguments, cEnvironment)
        guard spawned == 0 else { return Result(status: 127, output: "could not start \(executable): \(spawned)") }
        var status: Int32 = 0
        let stop = Date().addingTimeInterval(deadline)
        var killed = false
        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { break }
            if reaped < 0 && errno != EINTR { status = 0; break }
            if !killed && Date() >= stop {
                kill(pid, SIGTERM)
                killed = true
            }
            usleep(5_000)
        }
        let data = (FileManager.default.contents(atPath: outputPath) ?? Data()).prefix(limit)
        let exited = (status & 0x7f) == 0
        let code: Int32 = killed ? 124 : (exited ? (status >> 8) & 0xff : 128 + (status & 0x7f))
        return Result(status: code, output: String(decoding: data, as: UTF8.self))
    }
}
