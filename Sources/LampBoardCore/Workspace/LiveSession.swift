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

    /// Copy with a different activity timestamp.
    public func with(modifiedAt newValue: Date) -> LiveSession {
        LiveSession(
            pid: pid, sessionId: sessionId, cwd: cwd, entrypoint: entrypoint,
            name: name, kind: kind, modifiedAt: newValue, host: host, procStart: procStart,
            context: context
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
        context: ContextReading? = nil
    ) {
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
            procStart: (object["procStart"] as? String) ?? (object["procStart"] as? Int).map(String.init)
        )
    }
}
