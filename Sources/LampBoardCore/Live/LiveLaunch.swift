import Foundation

/// What the live view runs (D130): one `claude` command in a terminal of
/// LampBoard's own, never a shell.
///
/// Two commands, and only two. `claude attach <id>` opens a background session:
/// the supervisor keeps it alive, closing the window only detaches, and the
/// session itself refuses a second writer (measured: a headless resume of it is
/// refused, a plain `--resume` turns into an attach). `claude --bg` starts a new
/// one in a folder, and prints the id that is then attached to. An interactive
/// session that lives in an editor or a terminal is never opened here: it has
/// no such protection, and a second writer forks its conversation in two.
public struct LiveCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    /// Where it runs; `nil` for an attach, whose session has its own folder.
    public let directory: String?
    public let environment: [String: String]
}

public enum LiveLaunch {

    /// `claude attach <job>`, or `nil` for an id that is not a job's: it is
    /// passed as an argument, never through a shell, but `--help` would still
    /// be read as an option (D104's rule, kept).
    public static func attach(job: String, claude: String, environment base: [String: String], home: String) -> LiveCommand? {
        guard BackgroundJobParser.isSafe(id: job) else { return nil }
        return LiveCommand(executable: claude, arguments: ["attach", job], directory: nil,
                           environment: environment(base: base, home: home, claude: claude))
    }

    /// `claude --bg [--name <name>]` in `directory`, which must be absolute. A
    /// name that begins with a dash is left out rather than passed: a row's
    /// name comes from a folder or a title, and either could be `--something`.
    public static func start(directory: String, name: String?, claude: String,
                             environment base: [String: String], home: String) -> LiveCommand? {
        guard directory.hasPrefix("/") else { return nil }
        var arguments = ["--bg"]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !name.hasPrefix("-") {
            arguments += ["--name", String(name.prefix(80))]
        }
        return LiveCommand(executable: claude, arguments: arguments, directory: directory,
                           environment: environment(base: base, home: home, claude: claude))
    }

    /// The variables that reach the session, and nothing else.
    ///
    /// A GUI app's environment is whatever launched it: a terminal's `TMUX`, an
    /// editor's `TERM_PROGRAM`, a `CLAUDECODE` when LampBoard itself was started
    /// from a session, a test's `LAMPBOARD_HOME`, somebody's tokens. Claude Code
    /// reads several of those to decide what terminal it is in, so the live view
    /// passes a short list and says what it is itself.
    public static func environment(base: [String: String], home: String, claude: String? = nil) -> [String: String] {
        var env: [String: String] = [:]
        for key in kept { if let value = base[key] { env[key] = value } }
        for (key, value) in base where key.hasPrefix("LC_") { env[key] = value }
        env["HOME"] = home
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil, env["LC_ALL"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["PATH"] = path(base: base["PATH"], home: home, claude: claude)
        return env
    }

    /// The person's own, and what a session needs to reach Anthropic from
    /// where they are: another config folder (`attach` looks for its jobs
    /// there), a proxy, a company's certificates, a cloud provider. Not an API
    /// key: a key sitting in LampBoard's environment was put there for
    /// something else, and a session signs in on its own.
    static let kept = [
        "USER", "LOGNAME", "SHELL", "LANG", "SSH_AUTH_SOCK", "TMPDIR",
        "CLAUDE_CONFIG_DIR",
        "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy",
        "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR",
        "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "AWS_PROFILE", "AWS_REGION",
        "CLOUD_ML_REGION", "ANTHROPIC_VERTEX_PROJECT_ID",
    ]

    /// The folder `claude` is in first, so a `claude` that is a script finds
    /// the `node` beside it; then where people install it; then the system's
    /// own folders. Each once.
    static func path(base: String?, home: String, claude: String? = nil) -> String {
        let own = claude.map { ($0 as NSString).deletingLastPathComponent }.map { [$0] } ?? []
        let preferred = own + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let system = (base ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (preferred + system).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The id `claude --bg` printed: its `claude attach <id>` hint, or its
    /// `backgrounded · <id> · <name>` line. `nil` when it printed neither, or
    /// an id that is not a job's.
    public static func jobId(fromBackgroundOutput output: String) -> String? {
        let patterns = [#"claude attach ([^\s]+)"#, #"backgrounded\s*·\s*([^\s·]+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output) else { continue }
            let id = String(output[range])
            if BackgroundJobParser.isSafe(id: id) { return id }
        }
        return nil
    }

    /// Why `claude --bg` started nothing, for the window to say.
    public enum StartFailure: Equatable, Sendable {
        /// A folder Claude Code was never told to trust: `--bg` will not ask.
        case untrusted
        case notLoggedIn
        case other(String)

        public var message: String {
            switch self {
            case .untrusted:
                return "Claude Code has not been told to trust this folder yet. Open it once in a terminal with `claude`, answer the trust question, and try again."
            case .notLoggedIn:
                return "Claude Code is not signed in on this Mac. Run `claude` in a terminal and sign in, then try again."
            case .other(let text):
                return text.isEmpty ? "Claude Code started nothing and said nothing." : text
            }
        }
    }

    public static func startFailure(fromOutput output: String) -> StartFailure {
        let lowered = output.lowercased()
        if lowered.contains("not trusted") { return .untrusted }
        if lowered.contains("not logged in") || lowered.contains("/login") { return .notLoggedIn }
        let flat = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(3).joined(separator: " ")
        return .other(String(flat.prefix(300)))
    }
}

/// The processes the live view started (D130), so that the next launch can end
/// the ones a crash left behind.
///
/// Closing a window ends its `claude attach`, and quitting ends them all. A crash
/// does neither, and an attach left running holds a terminal nobody can see. The
/// ledger keeps each pid with its start time, because the system reuses pids: a
/// pid that is alive but started at another time is somebody else's process now.
public enum LiveLedger {

    public struct Entry: Codable, Equatable, Sendable {
        public let pid: Int32
        /// Seconds since 1970, as the system reports the process's start.
        public let startedAt: Double
        public let job: String

        public init(pid: Int32, startedAt: Double, job: String) {
            self.pid = pid
            self.startedAt = startedAt
            self.job = job
        }
    }

    /// Within a second: the system reports start times to the microsecond, the
    /// ledger rounds through JSON.
    static let tolerance: Double = 1

    /// The entries still running as the same process: those may be ended.
    public static func toEnd(_ entries: [Entry], startTime: (Int32) -> Double?) -> [Entry] {
        entries.filter { entry in
            guard let started = startTime(entry.pid) else { return false }
            return abs(started - entry.startedAt) < tolerance
        }
    }

    public static func encode(_ entries: [Entry]) -> Data {
        (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
    }

    /// A ledger that cannot be read is an empty one: ending nothing is the safe
    /// mistake, ending a stranger is not. Nor is a pid of 0 or 1 an entry:
    /// signalled as a group, those reach LampBoard's own processes or all of them.
    public static func decode(_ data: Data) -> [Entry] {
        ((try? JSONDecoder().decode([Entry].self, from: data)) ?? []).filter { $0.pid > 1 }
    }

    /// Each LampBoard keeps a ledger of its own, named after itself, so that a
    /// second one starting (a relaunch during an update, a build beside the
    /// installed app) leaves the first one's attaches alone while it runs.
    public static func fileName(owner pid: Int32, startedAt: Double) -> String {
        "live-\(pid)-\(Int((startedAt * 100).rounded())).json"
    }

    public struct Owner: Equatable, Sendable {
        public let pid: Int32
        public let startedAt: Double
    }

    public static func owner(fromFileName name: String) -> Owner? {
        let parts = name.split(separator: "-")
        guard parts.count == 3, parts[0] == "live", name.hasSuffix(".json"),
              let pid = Int32(parts[1]), let hundredths = Int(parts[2].dropLast(5)) else { return nil }
        return Owner(pid: pid, startedAt: Double(hundredths) / 100)
    }

    /// The LampBoard that kept this ledger is gone: no process with its pid,
    /// or one that started at another time.
    public static func isOrphaned(owner: Owner, startTime: (Int32) -> Double?) -> Bool {
        guard let started = startTime(owner.pid) else { return true }
        return abs(started - owner.startedAt) >= tolerance
    }
}

/// What a live window's header says (D130), read from the state the column draws.
public struct LiveHeading: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let status: SessionStatus?

    /// The session whose background job is `job`: its title or its folder, the
    /// folder and the state in the glossary's words. A job no row knows yet
    /// (just started, or its first signal still on the way) is named by its id.
    public static func of(job: String, in state: TrafficLightState) -> LiveHeading {
        let held = state.sessions.values.filter { $0.backgroundJob?.id == job }.max { $0.updatedAt < $1.updatedAt }
        guard let session = held else { return LiveHeading(title: job, detail: "background session", status: nil) }
        let title = session.title?.nilIfEmpty ?? session.workspace.name
        return LiveHeading(title: title, detail: "\(session.workspace.name) · \(session.status.label)", status: session.status)
    }
}
