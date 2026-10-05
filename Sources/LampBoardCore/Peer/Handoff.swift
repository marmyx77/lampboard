import Foundation

/// The baton (5.4): one session writes what another needs to carry on — asked
/// as a side question (D82), so it costs the first no turn — and the text waits
/// in the second's composer for the person to read, change and send (D85).
public enum Handoff {

    /// Its name in the bar: `/handoff @from @to`.
    public static let command = "handoff"

    /// What the first session is asked. Within a side question's size.
    public static let question = """
        Another Claude Code session is taking over from you, or depends on your work. Write the handoff it \
        will read before it starts: what you understood, what you decided and why, what is left to do, and \
        the files you touched. Plain text, at most thirty lines, no secret values.
        """

    /// The message proposed to the second session: whose it is, then the text.
    public static func brief(from source: String, text: String) -> String {
        "Handoff from \(LampMasterLookup.clean(source, to: LampMasterLookup.titleLength)), through LampBoard:\n\n\(text.trimmed)"
    }
}
