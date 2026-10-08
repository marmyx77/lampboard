import Foundation

/// «Move to LampBoard» (D135): a conversation open in VS Code goes on in a
/// LampBoard window, as a background session of this Mac, with its memory.
///
/// The editor's process is asked to end, and `claude --bg --resume <id>` takes
/// the same conversation up under Claude Code's supervisor, which refuses a
/// second writer: a message typed later in the editor's old tab is refused
/// there, never forked. Every check that can fail is made before anything ends.
public enum MoveHere {

    /// The entrypoint of Claude Code's VS Code extension, which Cursor and
    /// Windsurf run too.
    public static let editorEntrypoint = "claude-vscode"

    /// Whether the row's session may be offered the move: this Mac's, in the
    /// editor extension, and not already in the background.
    public static func isMovable(_ session: SessionState) -> Bool {
        !session.workspace.isRemote && session.origin != .background && session.entrypoint == editorEntrypoint
    }

    /// Between turns only: a turn under way, or a question waiting for an
    /// answer, would be cut where it stands.
    public static func isBetweenTurns(_ status: SessionStatus) -> Bool {
        switch status {
        case .idle, .ready, .waiting, .failed: return true
        case .working, .awaiting: return false
        }
    }

    /// Claude Code's own settings file: `$CLAUDE_CONFIG_DIR/.claude.json` when
    /// that is set, `~/.claude.json` otherwise.
    public static func configPath(environment: [String: String], home: String) -> String {
        if let directory = environment["CLAUDE_CONFIG_DIR"]?.nilIfEmpty, directory.hasPrefix("/") {
            return (directory as NSString).appendingPathComponent(".claude.json")
        }
        return (home as NSString).appendingPathComponent(".claude.json")
    }

    /// Whether `--bg` will start in `folder`: the folder, or a folder above it,
    /// was trusted once (measured: a trusted parent covers every folder under
    /// it). Checked before the editor's process is ended, because `--bg` does
    /// not ask and the conversation would be left with no process at all.
    public static func isTrusted(folder: String, config: Data?) -> Bool {
        guard folder.hasPrefix("/"), let config,
              let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let projects = object["projects"] as? [String: Any] else { return false }
        // As given and through its links (`/tmp` is `/private/tmp` on a Mac):
        // the settings hold whichever Claude Code saw.
        let spellings = Set([(folder as NSString).standardizingPath, (folder as NSString).resolvingSymlinksInPath])
        return spellings.contains { spelling in
            var path = spelling
            while true {
                if let project = projects[path] as? [String: Any], project["hasTrustDialogAccepted"] as? Bool == true { return true }
                guard path != "/", !path.isEmpty else { return false }
                path = (path as NSString).deletingLastPathComponent
            }
        }
    }

    /// What became of the start after the editor's process ended, said so that
    /// nobody is told to resume a conversation that may already have a process.
    public enum Outcome: Equatable, Sendable {
        /// Running as this job, and its window could not open.
        case started(job: String)
        /// Claude Code answered and refused: nothing runs, the line can be typed.
        case refused(String)
        /// No answer in time, or one that names no job: it may be running.
        case unknown
    }

    public static func message(_ outcome: Outcome, sessionId: String, folder: String) -> String {
        switch outcome {
        case .started(let job):
            return "The conversation goes on as the background session \(job), but its window could not open. "
                + "Open it from its row, or with `claude attach \(job)` in a terminal."
        case .refused(let why):
            return why + "\n\nThe VS Code process has ended, and nothing runs the conversation now. "
                + "To go on in a terminal (copied): \(fallback(sessionId: sessionId, folder: folder))"
        case .unknown:
            return "Claude Code did not say whether the background session started. Look for it in the panel, "
                + "or with `claude agents`, before resuming it anywhere: a second process would fork the conversation."
        }
    }

    /// What to type to take the conversation up by hand, when LampBoard could
    /// end the editor's process but not start the new one.
    public static func fallback(sessionId: String, folder: String) -> String {
        "cd \(NewSession.shellQuoted(folder)) && claude --resume \(sessionId)"
    }
}
