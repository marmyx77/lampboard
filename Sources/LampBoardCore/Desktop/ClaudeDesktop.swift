import Foundation

/// The Claude Desktop application, and the one kind of session it runs where we
/// can see anything at all.
///
/// Claude Desktop starts a session in one of two places, and the difference is
/// everything. A **cloud** session runs on Anthropic's servers: nothing of it is
/// on this Mac except the folder it was pointed at, and even the hooks it would
/// have fired are a documented, open gap — the sandbox looks for a
/// `cowork_settings.json` inside itself and the settings on this machine are
/// never mounted (anthropics/claude-code#40495). A **local** session runs
/// *here*, as a child of the application, and writes exactly the file every
/// other Claude Code session writes.
///
/// So this surface is not entered through a hook. It is entered the way the
/// terminal sessions already are: a live session file naming a pid, in a
/// directory nobody thought to look in.
public enum ClaudeDesktop {

    /// What a local session calls itself in its own session file.
    ///
    /// Read rather than assumed: `{"entrypoint":"local-agent","pidDomain":"darwin"}`,
    /// measured on a running one. It travels into the row and is what tells a
    /// click to raise the application rather than an editor window.
    public static let entrypoint = "local-agent"

    /// The other name the same surface goes by. Claude Code 2.1.281, started by
    /// the application, writes `claude-desktop` into `CLAUDE_CODE_ENTRYPOINT` and
    /// into the session file — measured on 25 September 2026, on a session the
    /// application had opened on a node over ssh. The panel knew only the first
    /// spelling, so the click on that row went looking for an editor window and
    /// found none. Both are the application; ask `isEntrypoint`, never `==`.
    public static let hookEntrypoint = "claude-desktop"

    /// `true` when `entrypoint` names this application, under either spelling.
    public static func isEntrypoint(_ entrypoint: String?) -> Bool {
        entrypoint == self.entrypoint || entrypoint == hookEntrypoint
    }

    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    /// Where the application keeps a whole Claude Code home per session.
    ///
    /// One folder per conversation, each with its own `.claude` inside it:
    /// `sessions/<pid>.json`, `projects/<encoded cwd>/<session>.jsonl`. The name
    /// of the directory is historical — it predates the app calling these
    /// "local sessions" — and it is matched as written, never guessed at.
    public static func sessionsRoot(inHome home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
    }

    /// A session's own home is `local_<uuid>`; the index beside it is
    /// `local_<uuid>.json`. Both names are the session's, so one gives the other.
    public static func indexPath(forHome home: URL) -> URL {
        home.deletingLastPathComponent()
            .appendingPathComponent(home.lastPathComponent + ".json")
    }

    /// `true` for the directory shape a session home has.
    public static func isSessionHome(_ name: String) -> Bool {
        name.hasPrefix("local_") && !name.hasSuffix(".json")
    }
}

/// What the application records about one of its sessions, beside the session's
/// own home.
///
/// This file is the surface's **only** durable evidence, and that is a measured
/// fact rather than a design choice. The session file a local session writes —
/// `.claude/sessions/<pid>.json`, the one every terminal session also writes —
/// exists for exactly as long as the agent process does, which for Claude
/// Desktop is **one turn**. The application starts a process to answer, and
/// removes the file when it exits: on this machine, a home whose turn ended at
/// 22:44:38 had an empty `.claude/sessions` directory stamped 22:44.
///
/// Read as liveness, that is a row that appears while the model works and
/// disappears at the very moment there is something to read — the one moment the
/// panel exists for. So presence comes from here, and the session file is
/// demoted to what it honestly is: a witness that a turn is running right now.
public struct DesktopSessionIndex: Sendable, Equatable {
    /// The conversation's own title, as the application derived it.
    public let title: String?
    /// The id of the transcript, which is a Claude Code session id like any
    /// other. Named here so the transcript is found by asking rather than by
    /// rebuilding the folder encoding, which is the application's business.
    public let cliSessionId: String?
    /// The folders the person connected to this conversation.
    public let folders: [String]
    /// Of those, the ones the application itself resolved as living here.
    ///
    /// A conversation can hold a local folder and a remote one at once, so the
    /// row's label is taken from this list rather than from the first folder
    /// somebody happened to pick.
    public let localFolders: [String]
    public let model: String?
    public let isArchived: Bool
    /// When the application last recorded activity, in its own reckoning.
    ///
    /// A fallback for the transcript's last timestamp, not a replacement: the
    /// application writes this file for its own reasons and a rewrite is not a
    /// thing the conversation said.
    public let lastActivityAt: Date?

    /// `true` when at least one folder resolved as living on this machine.
    ///
    /// The application says this itself (`resolvedFolderKinds`), which is worth
    /// more than any inference we could make: it is the one field that tells a
    /// session running here from one running on a server.
    public var hasLocalFolder: Bool { !localFolders.isEmpty }

    public init(
        title: String?, cliSessionId: String? = nil, folders: [String],
        localFolders: [String] = [], model: String?, isArchived: Bool,
        lastActivityAt: Date? = nil
    ) {
        self.title = title?.trimmed.nilIfEmpty
        self.cliSessionId = cliSessionId?.trimmed.nilIfEmpty
        self.folders = folders
        self.localFolders = localFolders
        self.model = model?.trimmed.nilIfEmpty
        self.isArchived = isArchived
        self.lastActivityAt = lastActivityAt
    }

    /// Reads the index, keeping only what a row can honestly use.
    ///
    /// Fails closed on anything it cannot read: nothing here is invented to fill
    /// a gap, and a field that is missing stays missing rather than becoming a
    /// default that reads like an observation.
    public static func parse(_ data: Data) -> DesktopSessionIndex? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // These strings reach a row label and, through it, a click: a folder that
        // is not an absolute path is not a folder.
        let folders = (object["userSelectedFolders"] as? [String] ?? [])
            .map(\.trimmed)
            .filter { $0.hasPrefix("/") }

        // `resolvedFolderKinds` is a list of `{display, kind}`. A folder the
        // application resolved as `local` is one it can reach on this machine.
        let kinds = object["resolvedFolderKinds"] as? [[String: Any]] ?? []
        let localFolders = kinds
            .filter { ($0["kind"] as? String) == "local" }
            .compactMap { ($0["display"] as? String)?.trimmed }
            .filter { $0.hasPrefix("/") }

        return DesktopSessionIndex(
            title: object["title"] as? String,
            cliSessionId: object["cliSessionId"] as? String,
            folders: folders,
            localFolders: localFolders,
            model: object["model"] as? String,
            isArchived: (object["isArchived"] as? Bool) ?? false,
            lastActivityAt: millisecondsToDate(object["lastActivityAt"])
        )
    }

    /// The application writes moments as milliseconds since the epoch. A value
    /// of another shape is no moment, never a moment at zero.
    private static func millisecondsToDate(_ value: Any?) -> Date? {
        guard let milliseconds = value as? Double, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
