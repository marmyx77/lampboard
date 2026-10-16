import Foundation

/// A Claude Code session declared alive by the filesystem.
///
/// Claude Code writes one file per process at `~/.claude/sessions/<pid>.json`.
/// It is the only source that says which sessions **exist right now**: the hooks
/// only report what happens, never what disappeared. Without this source, closing
/// a panel leaves behind a clickable row that leads nowhere.
public struct LiveSession: Sendable, Equatable {
    public let pid: Int
    public let sessionId: String

    /// Working directory, from which the VS Code workspace is derived.
    public let cwd: String

    /// `claude-vscode`, `cli`, … Used to exclude what nobody sits in front of
    /// (`sdk`, `print`), and carried into the row: it decides whether a click
    /// may send the tab deep link.
    public let entrypoint: String?

    /// Readable name Claude Code derives from the project (`event-tracker-64`).
    public let name: String?

    /// `interactive` for sessions with a user in front of them.
    public let kind: String?

    /// Modification date of the file, used to estimate last activity when a
    /// session is discovered without ever having received a hook.
    public let modifiedAt: Date

    /// The machine it runs on, as it answers over ssh. `nil` means this one.
    ///
    /// Carried from here into the session's `Workspace`, because a row has to be
    /// able to say where it is — and because a remote row must not try to bring a
    /// local window to the front.
    public let host: String?

    /// When the process started, as Claude Code wrote it — clock ticks on Linux,
    /// a UTC ctime string on macOS (`ProcStart`). The guard against a pid handed
    /// to another process after this one died.
    public let procStart: String?

    /// How full that session's context was at its last reply, when the machine
    /// it runs on was able to say.
    ///
    /// Carried here rather than fetched later because a transcript on another
    /// machine is not a file on this one: the probe standing in that directory
    /// is the only thing that can read it, and this is where what it read
    /// arrives.
    public let context: ContextReading?
    /// Another machine's session whose transcript there holds anything at all
    /// (D137): what makes it a conversation, whether or not a context can be
    /// read from its tail. A session just resumed has a tail of system records.
    public let hasTranscript: Bool
    /// What Claude Code itself writes as the session's `status` in its file
    /// (D141), one of four words, kept as the word it is.
    public let fileStatus: FileStatus
    /// Whether the tail of the session's own transcript ends inside a turn
    /// (`TranscriptActivity.turnIsOpen`), where a probe sent that tail: `nil`
    /// when nothing says — no tail read, or no turn in it.
    public let turnIsOpen: Bool?

    /// The four words Claude Code writes as a session's `status`, and room for a
    /// fifth. Claude Code 2.1.300 checks the field against exactly these four
    /// and computes them in one place for an interactive session:
    ///
    /// - `waiting` when something waits for the person: a permission prompt, an
    ///   MCP server's question, a proposed goal, a sandbox's network request, a
    ///   worker's request, any other dialog it opened;
    /// - otherwise `busy` while the turn runs or a background agent, teammate or
    ///   workflow is still at work, after the turn too;
    /// - otherwise `shell` while a background shell (`run_in_background`) runs;
    /// - otherwise `idle`.
    ///
    /// Its own list draws `busy` and `shell` as working and `waiting` as blocked.
    /// A session run through the SDK (the Claude app) writes `busy`, `waiting`
    /// (`requires_action`) and `idle`.
    public enum FileStatus: Sendable, Equatable {
        case idle
        case busy
        case shell
        case waiting
        /// A word this build does not know, kept so a log can say it: read as
        /// alive and resting, never as work and never as a reason to drop the
        /// session.
        case unrecognised(String)

        /// The file's word; a file with none is idle, as Claude Code's own
        /// readers take it.
        public init(word: String?) {
            switch word?.trimmed {
            case nil, ""?, "idle"?: self = .idle
            case "busy"?: self = .busy
            case "shell"?: self = .shell
            case "waiting"?: self = .waiting
            case let other?: self = .unrecognised(other)
            }
        }
    }

    /// The state the file and the tail tell together, for a row nobody announced.
    ///
    /// - `waiting`: something waits for the person in the session's terminal or
    ///   window — **amber**, `awaiting`. No question travels with it: the file
    ///   says only that one waits, and what kind;
    /// - `shell`: the turn is over and a background shell runs, which will wake
    ///   the session — the Mac's blue, `waiting`, which its hooks give the same
    ///   session (a `Stop` with a shell registered). Claude Code writes it only
    ///   when its turn is not running, so a tail that still looks open does not
    ///   change it. Measured on the always-on machine: five minutes of `shell`
    ///   while a background `sleep` ran, the tail ending in `turn_duration`;
    /// - `busy` with the turn closed: background agents are at work and will wake
    ///   the session — blue as well. Measured there: a session whose turn had
    ///   ended, its agents at work, read `busy` for hours; blue on the Mac, it was
    ///   yellow on the phone, then (build 2) resting;
    /// - `busy` with the turn open, or nothing known of it: working (D141);
    /// - `idle`, or a word not known yet: idle.
    public var statusFromFile: SessionStatus {
        switch fileStatus {
        case .waiting: return .awaiting
        case .shell: return .waiting
        case .busy: return turnIsOpen == false ? .waiting : .working
        case .idle, .unrecognised: return .idle
        }
    }

    /// The same reading for a row its hooks keep from here on (the Mac's): amber
    /// is left to the hooks. They carry the question, and the way back from it.
    /// A dialog the person closes fires no hook, so an amber taken from the file
    /// would stay lit on a row nothing re-reads; the phone re-reads the file at
    /// every look, and takes `statusFromFile` whole.
    public var statusForAHeardRow: SessionStatus {
        statusFromFile == .awaiting ? .idle : statusFromFile
    }

    /// The same session as `status` says it: what one row of two processes
    /// holding a conversation takes from the busier of them.
    public func with(statusFromFile status: SessionStatus) -> LiveSession {
        guard status != statusFromFile else { return self }
        let word: FileStatus
        switch status {
        case .awaiting: word = .waiting
        case .working, .waiting: word = .busy
        case .idle, .ready, .failed: word = .idle
        }
        return LiveSession(
            pid: pid, sessionId: sessionId, cwd: cwd, entrypoint: entrypoint,
            name: name, kind: kind, modifiedAt: modifiedAt, host: host, procStart: procStart,
            context: context, jobId: jobId, tmux: tmux, hasTranscript: hasTranscript,
            fileStatus: word, turnIsOpen: status == .waiting ? false : status == .working ? true : turnIsOpen
        )
    }

    /// For a background session, the Agent View's id for it: the folder under
    /// `~/.claude/jobs/` and what `claude attach` takes (AV2). Kept only when it
    /// is fit for a shell — see `BackgroundJobParser.isSafe`.
    public let jobId: String?
    /// Where it runs in tmux, on a machine whose probe could say (D132).
    public let tmux: TmuxPlace?

    /// Copy with a different activity timestamp.
    public func with(modifiedAt newValue: Date) -> LiveSession {
        LiveSession(
            pid: pid, sessionId: sessionId, cwd: cwd, entrypoint: entrypoint,
            name: name, kind: kind, modifiedAt: newValue, host: host, procStart: procStart,
            context: context, jobId: jobId, tmux: tmux, hasTranscript: hasTranscript, fileStatus: fileStatus,
            turnIsOpen: turnIsOpen
        )
    }

    public init(
        pid: Int,
        sessionId: String,
        cwd: String,
        entrypoint: String?,
        name: String?,
        kind: String? = nil,
        modifiedAt: Date,
        host: String? = nil,
        procStart: String? = nil,
        context: ContextReading? = nil,
        jobId: String? = nil,
        tmux: TmuxPlace? = nil,
        hasTranscript: Bool = false,
        fileStatus: FileStatus = .idle,
        turnIsOpen: Bool? = nil
    ) {
        self.turnIsOpen = turnIsOpen
        self.hasTranscript = hasTranscript
        self.fileStatus = fileStatus
        self.tmux = tmux
        self.jobId = jobId.flatMap { BackgroundJobParser.isSafe(id: $0) ? $0 : nil }
        self.context = context
        self.host = host?.trimmed.nilIfEmpty
        self.procStart = procStart?.trimmed.nilIfEmpty
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = PathNormalizer.normalize(cwd)
        self.entrypoint = entrypoint
        self.name = name
        self.kind = kind
        self.modifiedAt = modifiedAt
    }

    /// Started with `claude --bg`: no terminal tab and no window, its place is
    /// the Agent View — and here a row of its own (AV1).
    public var isBackground: Bool { kind == AppConfig.backgroundSessionKind }

    /// `true` when the session deserves a row in the column.
    ///
    /// As with hook signals, the criterion is *where* it runs — which the
    /// workspace resolver decides — and not which command started it. What remains
    /// here is only the exclusion of what isn't interactive.
    ///
    /// `kind` is the most reliable source because Claude Code writes it itself;
    /// when it is missing we fall back to the entrypoint. A file declaring neither
    /// is kept: the risk of one row too many is smaller than the risk of a session
    /// you can't see.
    public var deservesTrafficLight: Bool {
        // **Both**, and this used to be an `if` that returned on the first one.
        // A session can declare `kind: interactive` and still have been started by
        // the SDK — claude-mem's observer does exactly that, hundreds of times a
        // day — and the early return meant the entrypoint was never looked at.
        //
        // It stayed invisible locally for an unrelated reason: no editor window
        // claims `~/.claude-mem/observer-sessions`, so the workspace resolver
        // dropped it. Reading another machine removed that accidental filter and
        // the observer turned up in the column, which is how this was found.
        // A background session (`claude --bg`) is somebody's session too: it
        // works unseen, and that is when a lamp is worth the most (§5.14).
        if let kind, !kind.isEmpty, kind != AppConfig.interactiveSessionKind, kind != AppConfig.backgroundSessionKind {
            return false
        }
        guard let entrypoint, !entrypoint.isEmpty else { return true }
        return !AppConfig.nonInteractiveEntrypoints.contains(entrypoint)
    }
}

public enum LiveSessionError: Error, Equatable {
    case invalidJSON
    case missingField(String)
}

/// Decodes a file from `~/.claude/sessions/`.
public enum LiveSessionParser {
    public static func parse(data: Data, modifiedAt: Date) throws -> LiveSession {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
            let object = parsed as? [String: Any]
        else {
            throw LiveSessionError.invalidJSON
        }

        guard
            let sessionId = (object["sessionId"] as? String)?.trimmed, !sessionId.isEmpty
        else {
            throw LiveSessionError.missingField("sessionId")
        }

        guard
            let cwd = (object["cwd"] as? String)?.trimmed, cwd.hasPrefix("/")
        else {
            throw LiveSessionError.missingField("cwd")
        }

        return LiveSession(
            pid: (object["pid"] as? Int) ?? 0,
            sessionId: sessionId,
            cwd: cwd,
            entrypoint: (object["entrypoint"] as? String)?.trimmed.nilIfEmpty,
            name: (object["name"] as? String)?.trimmed.nilIfEmpty,
            kind: (object["kind"] as? String)?.trimmed.nilIfEmpty,
            modifiedAt: modifiedAt,
            procStart: (object["procStart"] as? String) ?? (object["procStart"] as? Int).map(String.init),
            jobId: (object["jobId"] as? String)?.trimmed.nilIfEmpty,
            fileStatus: LiveSession.FileStatus(word: object["status"] as? String)
        )
    }
}
