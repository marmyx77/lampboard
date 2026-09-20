import Foundation

/// The Claude Code lifecycle events we care about.
///
/// Claude Code exposes around thirty of them; we keep only the ones that move a
/// traffic light. An unknown event is not an error — it is simply ignored, so the
/// app doesn't break when Anthropic adds new ones.
public enum HookEventKind: String, Sendable, Equatable, CaseIterable, Codable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"

    /// A tool that **ran and came back with an error**.
    ///
    /// Not a variant of `postToolUse`: Claude Code emits one or the other, never
    /// both. Measured on 20 September 2026 — a permitted `Bash` that exited
    /// non-zero produced `PostToolUseFailure` and **no** `PostToolUse`.
    ///
    /// That makes it load-bearing rather than decorative. `PostToolUse` is
    /// registered for exactly one reason, to prove a permission prompt was
    /// answered; without this one beside it, granting a permission for a tool that
    /// then fails leaves the row amber — the same thirty-three-minute stuck amber
    /// that rule was written to end, surviving in the case nobody tested.
    ///
    /// It carries the same proof, and only that proof: it fires when the tool ran.
    /// A tool the sandbox **blocked** produces neither, which is exactly right —
    /// nothing ran, so nothing was granted.
    case postToolUseFailure = "PostToolUseFailure"
    case notification = "Notification"

    /// Codex is about to ask for an approval. Claude Code has no equivalent it
    /// exposes passively — it announces the same fact through `Notification` —
    /// so this is registered for one harness only. See `Harness.defaultHookEvents`.
    case permissionRequest = "PermissionRequest"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case sessionEnd = "SessionEnd"

    /// A subagent started inside this session's turn.
    case subagentStart = "SubagentStart"

    /// A subagent finished.
    case subagentStop = "SubagentStop"
}

/// `Notification` subtypes relevant to the state machine.
public enum NotificationKind: String, Sendable, Equatable {
    /// Claude is asking permission to run a tool: the most urgent state.
    case permissionPrompt = "permission_prompt"

    /// The session has been sitting idle waiting for input for a while.
    case idlePrompt = "idle_prompt"

    /// An agent completed its work.
    case agentCompleted = "agent_completed"

    /// An agent needs input.
    case agentNeedsInput = "agent_needs_input"

    /// An MCP server opened a dialog and is waiting for an answer: it blocks the
    /// session exactly like a permission request.
    case elicitationDialog = "elicitation_dialog"
}
