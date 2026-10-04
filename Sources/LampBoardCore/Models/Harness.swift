import Foundation

/// Which coding agent a session belongs to.
///
/// The panel shows one row shape for every harness, and that is deliberate: a
/// row is a row, the dot means the same thing everywhere, and the ring always
/// means how full the context window is. What differs between harnesses is not
/// how a row *looks* — it is what a row is **able to promise**, and the whole
/// point of this type is to make those limits something the app states rather
/// than something the user discovers.
///
/// The rule that follows from it, and the reason the type is not just a label:
/// **an absence is declared, never inferred.** Codex publishes no error event of
/// any kind, so a failed turn simply stops emitting hooks. Reading that silence
/// as a failure would mean painting a row red because a model was thinking for
/// a long time. So a Codex row never turns red, and the card says why, which is
/// worth more than a red dot that is right two thirds of the time.
public enum Harness: String, Sendable, Equatable, CaseIterable, Codable {

    /// Anthropic's Claude Code, in any of its surfaces: the CLI, the VS Code
    /// extension, and the copy the desktop app carries. All three share
    /// `~/.claude`, so all three are this.
    case claudeCode = "claude"

    /// OpenAI's Codex, likewise across its surfaces: the terminal CLI, the VS
    /// Code extension, and the copy inside the ChatGPT desktop app. Measured, not
    /// assumed — the rollouts of all three land in `~/.codex/sessions` and name
    /// themselves in an `originator` field.
    case codex = "codex"

    /// Not an agent: a command run under `lampboard watch` (D70). A build, a
    /// test suite, a deploy becomes a row — yellow while it runs, green when it
    /// exits 0, red otherwise — beside the sessions of the same folder.
    case command = "command"

    /// The name to show a person.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .command: return "Command"
        }
    }

    /// Where this harness keeps its session transcripts.
    ///
    /// The transcript path arrives inside a payload on the one route that has no
    /// token, so it is checked against this root before anything opens it — see
    /// `TranscriptPathPolicy`. One root per harness, and nothing outside them.
    public var transcriptRoot: URL {
        switch self {
        case .claudeCode: return AppConfig.claudeDirectory
        case .codex: return AppConfig.codexDirectory
        // No transcript: nothing under this root is ever read for a command.
        case .command: return AppConfig.supportDirectory.appendingPathComponent("watch", isDirectory: true)
        }
    }

    /// Statuses this harness has no way to report, whatever happens.
    ///
    /// Not a list of features nobody got round to: a list of events the harness
    /// does not publish, checked against its own documentation and confirmed by
    /// running it. Every consumer that would otherwise infer one of these from
    /// silence has to consult this first, and the hover card prints it, so the
    /// user is told the limit instead of meeting it.
    public var cannotReport: [SessionStatus] {
        switch self {
        case .claudeCode:
            return []
        case .codex:
            // One thing only, and it is checked against the published event list
            // rather than assumed: there is no error event of any kind — no
            // `StopFailure`, no `Error`, no `TurnFailed`. A turn that fails stops
            // emitting, and silence does not distinguish a crash from a long
            // thought, so a Codex row never turns red.
            //
            // `waiting` was on this list for an hour and should not have been.
            // Codex publishes `SubagentStart` and `SubagentStop` like Claude Code
            // does; the blue state works there too. Guessing a limit is the same
            // mistake as guessing a capability, and it costs a real feature.
            return [.failed]
        case .command:
            // It runs or it has ended: nobody can be waited on, and it has no
            // subagents.
            return [.awaiting, .waiting]
        }
    }

    /// One sentence naming what this harness cannot tell us, for the hover card.
    /// `nil` when it can tell us everything.
    public var limitation: String? {
        switch self {
        case .claudeCode:
            return nil
        case .codex:
            return "Codex reports no failures: a turn that fails stops speaking"
        case .command:
            return "a command run with lampboard watch: green when it exits 0, red otherwise, and no window to open"
        }
    }

    /// Whether a reading of this harness's context is exact by declaration.
    ///
    /// Claude Code states no window anywhere a reader can see, so ours is
    /// measured — against 236 real compactions — and carries a confidence.
    /// Codex writes `model_context_window` into the same record as the token
    /// count, which is a better position to be in and deserves to be visible as
    /// one rather than quietly folded into `exact`.
    public var declaresContextWindow: Bool {
        switch self {
        case .claudeCode: return false
        case .codex: return true
        case .command: return false
        }
    }

    /// The hook events worth registering for this harness.
    ///
    /// Not the same list twice with a word changed: the two agents publish
    /// different events and the difference decides what a row can show.
    ///
    /// The one that matters is `PermissionRequest`. Claude Code announces a
    /// pending approval through `Notification`, which is a passive event, so the
    /// amber state costs nothing and this project declines to sit in the approval
    /// path at all. **Codex has no `Notification`.** Without `PermissionRequest`
    /// a Codex session blocked on an approval is indistinguishable from one that
    /// is thinking — the panel would lose the single state it exists to show. So
    /// it is registered there and not here, and the divergence is the point
    /// rather than an inconsistency.
    ///
    /// The hook writes nothing to stdout, which Codex's own documentation defines
    /// as declining to decide: the ordinary approval prompt proceeds exactly as
    /// it would have. It reads; it does not answer.
    public var defaultHookEvents: [String] {
        switch self {
        case .claudeCode:
            return HookConfigMerger.defaultEvents
        case .codex:
            return [
                "SessionStart",
                "UserPromptSubmit",
                "PermissionRequest",
                "Stop",
                "SessionEnd",
                "SubagentStart",
                "SubagentStop",
                // Same job as on the Claude side: the only registered event that
                // can prove an approval was answered, so an amber row stops
                // flashing at somebody who has already replied.
                "PostToolUse",
            ]
        case .command:
            return []
        }
    }

    /// The harness a hook payload came from, named by the script that sent it.
    ///
    /// Declared rather than sniffed. The hook scripts are ours and one is
    /// installed per harness, so the sender knows the answer for certain; a
    /// receiver guessing from the shape of a payload would be wrong the first
    /// time either vendor changed a field. An unknown or missing name means
    /// Claude Code, which is what every script written before this existed sends.
    public static func named(_ raw: String?) -> Harness {
        // `command` is never a hook's: its rows come only through `/watch`, behind
        // the token, so a header cannot make one.
        guard let raw = raw?.trimmed.lowercased(), let harness = Harness(rawValue: raw), harness != .command else {
            return .claudeCode
        }
        return harness
    }
}
