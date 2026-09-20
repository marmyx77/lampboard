import Foundation

/// Application configuration constants.
/// No hardcoded values scattered through the code: everything goes through here.
public enum AppConfig {
    // MARK: - Transport

    /// Listening interface. Loopback only: the server must never be reachable from the network.
    public static let listenHost = "127.0.0.1"

    /// Default port of the local HTTP server.
    public static let listenPort: UInt16 = 9877

    /// HTTP path where the Claude Code hooks post their signals.
    public static let signalPath = "/signal"

    /// Answers 200 and nothing else: the cheapest way to ask "is a panel there?".
    /// Named here because the self-test asks it too, and a route spelled out in
    /// two files drifts in one of them.
    public static let healthPath = "/health"

    /// HTTP path returning the column state as JSON. Requires the token.
    public static let sessionsPath = "/sessions"

    /// HTTP path that raises the window of the next awaiting session.
    /// Requires the token: it raises windows, it doesn't just color dots.
    public static let nextPath = "/next"

    /// HTTP path that raises the window in a given slot. The slot number is the
    /// request body. Requires the token, for the same reason as `/next`.
    public static let openPath = "/open"

    /// HTTP path that opens a new conversation in a given slot's project.
    /// Same shape as `/open`, same authentication.
    public static let newConversationPath = "/new"

    /// HTTP path that opens a slot's conversation in a chat window, without
    /// touching the editor. Same shape as `/open`, same authentication.
    public static let chatPath = "/chat"

    /// How many slots a key can address.
    ///
    /// Nine because that is how many number keys a modifier can reach without
    /// reaching, and because a set of shortcuts you have to think about is a set
    /// you stop using. The Codex Micro settles on six physical keys for the same
    /// reason: the limit is what you can address without looking, not what fits.
    public static let maxSlots = 9

    /// Maximum accepted size for an HTTP body (256 KB).
    /// `Stop` carries `last_assistant_message`, which can be long.
    public static let maxRequestBodyBytes = 256 * 1024

    // MARK: - Filesystem

    /// Name of the environment variable that relocates every path the app uses.
    public static let homeOverrideVariable = "LAMPBOARD_HOME"

    /// Root from which every path the app reads and writes descends.
    ///
    /// Normally the user's home directory. `LAMPBOARD_HOME` moves it elsewhere,
    /// and it exists for exactly one reason: to run the end-to-end tests against
    /// a fake home.
    ///
    /// Without this escape hatch an honest e2e test would be impossible — either
    /// it touches the user's real `~/.claude/settings.json`, or it bypasses the
    /// production code path and verifies something other than what actually ships.
    /// That is precisely the mistake that left title matching broken for an entire
    /// session with ten green tests.
    ///
    /// `homeDirectoryForCurrentUser` comes from `getpwuid` and ignores `$HOME`:
    /// rewriting `$HOME` would not be enough, and relying on it would give the
    /// illusion of an isolation that isn't there.
    public static var homeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[homeOverrideVariable],
           !override.trimmed.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `true` when the app is running against a fake home.
    /// Guards against a test accidentally touching real system resources.
    public static var isUsingHomeOverride: Bool {
        ProcessInfo.processInfo.environment[homeOverrideVariable]?.trimmed.isEmpty == false
    }

    /// Everything Claude Code keeps on disk: settings, sessions, transcripts.
    ///
    /// Named once because it is also a **boundary**, not only a location: a
    /// transcript path arriving in a hook payload is accepted only when it falls
    /// inside here (`TranscriptPathPolicy`), and `POST /signal` carries no token.
    public static var claudeDirectory: URL {
        homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Codex's home, holding both its hook configuration and its session
    /// rollouts. Honours `CODEX_HOME` the way Codex itself does — a machine that
    /// moved it would otherwise get an app that watches an empty directory and
    /// says, truthfully and uselessly, that there is nothing there.
    public static var codexDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmed.nilIfEmpty, override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Where Codex writes one rollout per session, under `YYYY/MM/DD/`.
    public static var codexSessionsDirectory: URL {
        codexDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Directory where the Claude Code VS Code plugin drops one lock file per window.
    public static var ideLockDirectory: URL {
        claudeDirectory.appendingPathComponent("ide", isDirectory: true)
    }

    /// Directory where Claude Code drops one file per live process,
    /// named after the PID.
    public static var liveSessionsDirectory: URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// How often the column is realigned against the live processes.
    /// Often enough that a row disappears right after you close a panel,
    /// rarely enough not to cost anything: one directory listing and one
    /// syscall per file.
    public static let liveSessionPollInterval: TimeInterval = 5

    /// How often an open chat window looks for new lines in its transcript.
    ///
    /// Faster than the column's realignment because you are reading it: a reply
    /// that lands five seconds late is a reply you watched not arrive. The cost is
    /// one `stat` per open window, and the reader returns immediately when the
    /// file hasn't grown.
    public static let transcriptPollInterval: TimeInterval = 1

    /// How many entries a chat window keeps in memory.
    ///
    /// A transcript reaches tens of thousands of lines and SwiftUI draws what it is
    /// given. This is the tail — the part of a conversation anybody scrolls back
    /// through — and the file stays the record of the rest.
    public static let chatHistoryLimit = 300

    /// How much of a transcript's tail a chat window reads when it opens.
    ///
    /// Enough for `chatHistoryLimit` entries several times over — a record with
    /// a big tool result runs to a hundred kilobytes — and small enough that a
    /// half-gigabyte transcript opens in the time a small one does. The head is
    /// read separately for the title.
    public static let transcriptInitialWindow = 8 * 1024 * 1024

    // MARK: - Waiting for a permission

    /// How often the app re-asks the system whether a permission has arrived.
    ///
    /// The check is a single function call, so the interval is set by how long a
    /// person is willing to look at an unchanged panel after flipping a switch —
    /// not by cost.
    public static let permissionWatchInterval: TimeInterval = 1.5

    // MARK: - The account's allowance

    /// Asking Anthropic how much of the allowance is gone. Short, and shorter than
    /// the update check: nobody is waiting for this one, and a request still open
    /// when the next one is due is a request that should have been abandoned.
    public static let usageRequestTimeout: TimeInterval = 5

    /// How often the allowance is asked, while the switch is on.
    ///
    /// Measured before being chosen: the five-hour figure moved from 9% to 12% in a
    /// quarter of an hour of ordinary work, so a strip refreshed every few minutes
    /// is telling the truth and one refreshed every half hour is not. Two and a
    /// half minutes is about twenty-five requests an hour — nothing, against the
    /// thousands of hook posts a working day already makes locally.
    public static let usagePollInterval: TimeInterval = 150

    // MARK: - Updates

    /// Asking GitHub which release is the latest. Short: it happens because
    /// somebody chose a menu entry and is waiting for an answer.
    public static let updateCheckTimeout: TimeInterval = 10

    /// Downloading the disk image. Long, because it is a few megabytes over
    /// whatever connection the user has, and giving up early on a slow line
    /// would look like a broken update rather than a slow one.
    public static let updateDownloadTimeout: TimeInterval = 300

    /// How long any one command the updater runs may take before it is killed.
    ///
    /// `spctl`, `codesign`, `hdiutil` and `ditto` are all local and quick, but
    /// two of them talk to Apple when a signature has never been seen on this
    /// Mac, and `hdiutil attach` on a damaged image can sit there indefinitely.
    /// Without a deadline the update simply never returns: no error, no menu, no
    /// way to tell a slow verification from a hung one — the worst shape a
    /// failure can take, because there is nothing to report.
    ///
    /// Ninety seconds is far beyond any honest run of these tools and far short
    /// of a person's patience.
    public static let updateToolTimeout: TimeInterval = 90

    /// How long a tool consulted while raising a window may take.
    ///
    /// The click runs on the thread that draws the panel, so every second spent
    /// here is a second the column is frozen. Measured on a healthy machine:
    /// `lsof` 0.06s, `ps` 0.07s, `open -b` 0.75s — five seconds is seventy times
    /// the cost of the slowest probe and still short enough that a person reads
    /// it as "it failed" rather than "it is broken".
    ///
    /// The risk being bounded is not hypothetical for two of them: `lsof` stats
    /// every open descriptor, so a network mount whose server has gone away
    /// stops it indefinitely, and `tmux`, `wezterm` and `kitten` all talk to a
    /// server over a socket that can stop answering. Before this, either one
    /// froze the panel until the app was killed.
    public static let focusProbeTimeout: TimeInterval = 5

    /// The same, for `open` — which may have to start an application that is not
    /// running yet, and that is legitimately slower than a probe.
    public static let focusActivationTimeout: TimeInterval = 15

    /// How long Ghostty is given to read a title written to a tty and report it.
    ///
    /// Measured with a real surface: the round trip through the emulator and
    /// back out through its dictionary settles well inside this. It is spent
    /// only when two surfaces are genuinely alike, never on an ordinary click.
    public static let ghosttyProbeSettle: TimeInterval = 0.08

    /// How many times the probe looks before giving up. Three, plus the last
    /// look that exists to undo a marker rather than to find one.
    public static let ghosttyProbeAttempts = 3

    /// How long that watch stays up before giving in.
    ///
    /// Long enough to find the pane, read the sentence and authenticate; short
    /// enough that walking away does not leave a timer running for the rest of
    /// the day. The click is not lost when it expires — it is simply made again.
    public static let permissionWatchWindow: TimeInterval = 180

    /// The app's support directory (panel position, preferences).
    public static var supportDirectory: URL {
        homeDirectory
            .appendingPathComponent(".lampboard", isDirectory: true)
    }

    /// Where the hook scripts lived before the project was renamed.
    ///
    /// The entries in `~/.claude/settings.json` name a **path**, and every
    /// session already running holds the one it was started with. Installing the
    /// new path without removing the old would leave two registrations per
    /// event: one that works and one that spawns a `curl` at a script that is no
    /// longer there, on every turn, forever. Claude Code would not complain —
    /// a hook that fails is not an error — so nothing would ever say so.
    ///
    /// Used only to *remove*. Nothing is ever written here again.
    public static var legacySupportDirectory: URL {
        homeDirectory
            .appendingPathComponent(".clawd-light", isDirectory: true)
    }

    /// File holding the token for the read endpoint.
    /// Mode `0600`: its contents authorize reading workspace names.
    public static var tokenURL: URL {
        supportDirectory.appendingPathComponent("token")
    }

    /// Hook script installed at `~/.lampboard/hook.sh` and referenced from `~/.claude/settings.json`.
    public static var hookScriptURL: URL {
        supportDirectory.appendingPathComponent("hook.sh")
    }

    /// Message listener installed at `~/.lampboard/rewake.sh`.
    ///
    /// A separate file from `hook.sh`, and not an option inside it, because the
    /// two have opposite obligations: the traffic light hook must return in
    /// milliseconds or it delays every turn, and this one waits for minutes.
    public static var rewakeScriptURL: URL {
        supportDirectory.appendingPathComponent("rewake.sh")
    }

    /// Claude Code's global configuration file, where the hooks are registered.
    /// The hook script for a harness that is not Claude Code.
    ///
    /// A separate file rather than one script branching on an environment
    /// variable: the two differ in what they send and in how long they may take,
    /// and a script that has to work out which agent invoked it is a script that
    /// can get it wrong on the one turn that mattered.
    public static var codexHookScriptURL: URL {
        supportDirectory.appendingPathComponent("codex-hook.sh")
    }

    /// Codex's hook configuration. One of four places Codex reads hooks from —
    /// all of them additive, none overriding the others — and the only one this
    /// app writes.
    public static var codexHooksURL: URL {
        codexDirectory.appendingPathComponent("hooks.json")
    }

    /// Codex's own configuration, which is also where it records **which hooks
    /// it has been told to trust**.
    ///
    /// Read only, and only for that. Codex refuses to run a hook it has not been
    /// approved for and says nothing when it declines, so a row can be silent
    /// with everything correctly registered — see `CodexTrust`.
    public static var codexConfigURL: URL {
        codexDirectory.appendingPathComponent("config.toml")
    }

    public static var claudeSettingsURL: URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Claude Code's own configuration, beside the home rather than inside
    /// `.claude`. Read only for the signed-in account's address and uuid, which are
    /// not secrets; the credential lives elsewhere.
    public static var claudeConfigURL: URL {
        homeDirectory.appendingPathComponent(".claude.json")
    }

    /// Presence file read by Claude Code to suppress phone push notifications
    /// while you are sitting at the Mac (`CLAUDE_CLIENT_PRESENCE_FILE`).
    public static var presenceFileURL: URL {
        supportDirectory.appendingPathComponent("presence")
    }

    // MARK: - State semantics

    /// Entrypoints of sessions nobody is watching.
    ///
    /// This is a list of **exclusions**, not of admissions, and that difference is
    /// the whole correction: an allow-list has to be updated for every new Claude
    /// Code entrypoint, and until it is, those sessions are invisible. A deny-list,
    /// when it is wrong, shows one row too many — a mistake you can see and fix,
    /// rather than one that stays silent.
    ///
    /// `sdk` and `print` are non-interactive sessions: they run inside scripts and
    /// finish without anyone needing to answer.
    ///
    /// `sdk-cli` was added after a contract probe: it is what `claude -p` really
    /// reports, and the list had been written from the documentation rather than
    /// from an observation. It is exactly the failure the deny-list shape is meant
    /// to survive — the gap showed one row too many instead of hiding one — but a
    /// gap it was. See `Contracts/assumptions.md`, entry `entrypoint.values`.
    public static let nonInteractiveEntrypoints: Set<String> = [
        "sdk", "sdk-cli", "sdk-ts", "sdk-py", "print",
    ]

    // MARK: - Background work

    /// Entries of `background_tasks` that are **not** work the user is waiting on.
    ///
    /// Claude Code's own "active tasks" view starts from the very predicate that
    /// builds the hook payload and then removes exactly these two types — read in
    /// the binary: `.filter(bL).filter(t => t.type !== "remote_agent" && t.type
    /// !== "dream")`. `dream` is its background memory consolidation: it runs on
    /// an idle session, writes nothing to the transcript, and never wakes the
    /// session when it ends. Counting it as work held a row yellow for a day
    /// after the answer had been sitting there since one second after `Stop`.
    ///
    /// The payload carries display names, not registry names: `remote_agent` is
    /// written as `cloud session`.
    public static let backgroundTaskTypesThatAreNotWork: Set<String> = ["dream", "cloud session"]

    /// Entries that keep an ear open without producing anything of their own.
    ///
    /// A `monitor` watches for a condition. Until that condition trips it emits
    /// nothing, changes nothing, and the answer the session already wrote is
    /// sitting there unread — so painting the row blue says "more is coming"
    /// about something that may never come, and buries a green underneath it.
    /// Measured on a real session: two monitors registered at 06:38 held a row
    /// blue for an hour while the reply above them had been finished the whole
    /// time.
    ///
    /// So a listener does not make the row blue. It draws a ring around whatever
    /// colour the row would have had anyway, which is the honest shape of the
    /// fact: the turn ended, *and* something is still listening.
    ///
    /// Deliberately a short list, and everything unrecognised counts as work.
    /// The expensive mistake here is one-directional: calling real work a
    /// listener shows green over a session that is still busy, which is the lie
    /// this whole state exists to prevent.
    public static let backgroundTaskTypesThatOnlyListen: Set<String> = ["monitor"]

    // MARK: - Remote hosts

    /// Hosts to read sessions from, one name per line, `#` for comments.
    ///
    /// A file and not a compiled list: the machines a person works across are
    /// theirs, not ours. Absent or empty means the feature is off, which is the
    /// default — reading another machine is an outbound connection, and this
    /// project does not start those unless asked.
    public static var remoteHostsFile: URL {
        homeDirectory.appendingPathComponent(".lampboard/remotes")
    }

    /// How long to give ssh before giving up on a host.
    ///
    /// Short on purpose. A node that is asleep must cost one poll, not a stall:
    /// the column has to keep telling the truth about this machine even when the
    /// other one is unreachable.
    public static let remoteProbeTimeout: TimeInterval = 5

    /// Header a hook adds when it runs on another machine and reaches this one
    /// through the tunnel: the name the host was configured under. Without it a
    /// signal from the node would be indistinguishable from a local one, and its
    /// `cwd` would be looked up among local editor windows that cannot claim it.
    public static let remoteHostHeader = "X-LampBoard-Host"

    /// The name this header had before the project was renamed.
    ///
    /// A header is not a label, it is a contract with scripts that already sit on
    /// machines this app cannot reach synchronously: a node behind ssh keeps
    /// sending the name it was installed with until somebody runs the installer
    /// there again. Renaming without reading both would silently demote every
    /// remote session to a local one, whose `cwd` is then looked up among local
    /// editor windows that cannot claim it — and the row would simply not appear.
    ///
    /// It is read, never written. `remote install` writes the new name, so a node
    /// stops needing this the moment it is reinstalled; the line goes when every
    /// node has been.
    public static let legacyRemoteHostHeader = "X-Clawd-Host"

    /// Header a hook adds naming the coding agent it belongs to.
    ///
    /// Declared by the sender rather than deduced by the receiver, because the
    /// sender knows: one hook script is installed per harness and each is written
    /// by this app. Sniffing the payload instead would work today — Codex carries
    /// `model` where Claude Code does not — and would break silently the first
    /// time either vendor added a field to match the other. Absent means Claude
    /// Code, which is what every script written before this existed sends.
    public static let harnessHeader = "X-LampBoard-Harness"

    /// Header naming the surface a Claude Code session was started from.
    ///
    /// Not ours — it carries Claude Code's own `CLAUDE_CODE_ENTRYPOINT`, which the
    /// workspace resolver trusts to tell a VS Code session from a terminal one. It
    /// is named here because two senders now have to agree on it: the hook script,
    /// which interpolates the variable in a shell, and the native `http` hook,
    /// which interpolates it through `allowedEnvVars`. Measured on 20 September
    /// 2026: the two produce the same value in every case — `claude-vscode`, `cli`,
    /// `sdk-cli`, and a planted sentinel.
    public static let entrypointHeader = "X-Claude-Entrypoint"

    /// The session's git identity, resolved by the hook script rather than here.
    ///
    /// Three headers and not one field in the payload, because they are added by
    /// the sender: the app must never read under a session's working directory.
    /// macOS gates Desktop, Documents, Downloads and network volumes as separate
    /// grants, so a `<cwd>/.git/HEAD` read from here pops a folder-access prompt
    /// the first time a session appears under any category not yet granted. The
    /// script runs in the user's own shell, under the terminal's grants, and ships
    /// the answer.
    public static let repoHeader = "X-LampBoard-Repo"
    /// The branch checked out when the session started. Not followed afterwards: a
    /// `git checkout` mid-session would need a hook on every turn, which is a
    /// process per turn for a fact that changes a handful of times a day.
    public static let branchHeader = "X-LampBoard-Branch"
    /// Present only when the session is in a **linked worktree**, where the row is
    /// named after the main repository rather than the worktree folder.
    public static let worktreeHeader = "X-LampBoard-Worktree"

    /// Backoff for a tunnel that exits: the first retry after this many seconds…
    public static let remoteTunnelRetryMin: TimeInterval = 5
    /// …doubling up to this.
    public static let remoteTunnelRetryMax: TimeInterval = 60

    /// Where the hook script goes on a remote machine, relative to its home.
    public static let remoteHookScriptRelativePath = ".lampboard/hook.sh"
    /// The far end of the tunnel on a remote machine: a loopback port **derived
    /// from the user's uid**, so two accounts on one machine never share it.
    ///
    /// A Unix socket in the user's home was tried first — owner-only by
    /// construction, immune to `GatewayPorts`. It failed on measurement: the
    /// machine at hand runs Tailscale SSH, whose daemon does the forwarding as
    /// root and created the socket `root:root 0600`, which the user cannot open.
    /// A port it is, then — verified after every connect to be bound to loopback
    /// and to nothing else (`RemoteInstallScripts.checkTunnel`).
    public static func remotePort(forUID uid: Int) -> UInt16 {
        UInt16(30_000 + max(uid, 0) % 20_000)
    }
    /// Claude Code's settings on a remote machine, relative to its home.
    public static let remoteClaudeSettingsRelativePath = ".claude/settings.json"

    /// How often the remote hosts are asked. Far slower than the local poll,
    /// because each one is a process spawn and an ssh handshake.
    public static let remotePollInterval: TimeInterval = 20

    /// Value of the `kind` field marking a session with a user in front of it.
    /// Present in the files under `~/.claude/sessions/`.
    public static let interactiveSessionKind = "interactive"

    /// A lock file older than this interval is considered orphaned.
    /// Locks are not always removed when the window closes.
    public static let ideLockMaxAge: TimeInterval = 60 * 60 * 24 * 7

    /// A session with no signals for longer than this interval is dropped from the column.
    public static let sessionStaleAfter: TimeInterval = 60 * 60 * 12

    // MARK: - Interface

    /// Maximum number of traffic lights shown at once before scrolling.
    /// How long a session must have been waiting before it is worth a
    /// notification.
    ///
    /// A permission a person has to answer stays amber until they answer it. One
    /// the agent approves itself is amber for a few hundred milliseconds, and
    /// Codex publishes `PermissionRequest` for **every** tool call, approved or
    /// not. Without this the first Codex session working through a task fired a
    /// burst of "waiting for your answer" while nothing was waiting for anybody:
    /// reported within minutes of Codex rows first appearing.
    ///
    /// Four seconds costs a real prompt four seconds of delay, which nobody
    /// notices, and costs an automatic one the entire notification, which is the
    /// point. The dot is amber immediately either way: this is about what
    /// interrupts you in another application.
    public static let awaitingNotificationDelay: TimeInterval = 4

    public static let maxVisibleRows = 12

    /// Blink period for the "awaiting permission" state, in seconds.
    public static let blinkPeriod: TimeInterval = 0.7


    // MARK: - Presence and attention

    /// How many seconds without touching keyboard or mouse before you stop
    /// counting as being at the Mac.
    ///
    /// Two minutes: long enough to cover a read or a short phone call, short
    /// enough not to keep push notifications suppressed while you're elsewhere.
    public static let presenceIdleThreshold: TimeInterval = 120

    /// How often user presence is re-evaluated.
    public static let presencePollInterval: TimeInterval = 20
}
