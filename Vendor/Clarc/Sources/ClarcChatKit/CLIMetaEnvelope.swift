// From Clarc (https://github.com/ttnear/Clarc), Apache License 2.0.
// Modified for LampBoard: see Vendor/Clarc/VENDORED.md for what changed.

import Foundation


/// Common envelope detection for CLI-internal text wrapped in `<...>` tags
/// (system reminders, slash-command echoes, local-command caveats, background
/// task notifications, custom slash-command expansions). Used by both jsonl
/// summary sniffing and full mapping.
public enum CLIMetaEnvelope {
    public static func isEnvelope(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("<local-command-caveat>")
            || trimmed.hasPrefix("<local-command-stdout>")
            || trimmed.hasPrefix("<command-name>")
            || trimmed.hasPrefix("<command-message>")
            || trimmed.hasPrefix("<command-args>")
            || trimmed.hasPrefix("<system-reminder>")
            || trimmed.hasPrefix("<task-notification>") {
            return true
        }
        // Custom slash-command expansions: CLI wraps a user-defined command's
        // template in <{name}-command>...</{name}-command> when the user runs
        // it. The tag name varies per command, so pattern-match on the suffix.
        if trimmed.hasPrefix("<"),
           let endIdx = trimmed.firstIndex(of: ">") {
            let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<endIdx]
            if !tag.contains(" ") && tag.hasSuffix("-command") {
                return true
            }
        }
        return false
    }

    /// Detect the model's no-op-turn marker — emitted when a turn arrived
    /// without a user prompt (e.g. ScheduleWakeup, hook-driven re-entry).
    /// Renders as a noisy empty bubble in the chat UI; callers strip it.
    public static func isNoResponseRequested(_ trimmed: String) -> Bool {
        trimmed == "No response requested." || trimmed == "No response requested"
    }
}
