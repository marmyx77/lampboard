import Foundation

/// The voice (§5.9, D117): a session waiting for a permission, said aloud by
/// the panel to someone near the Mac but not at its keys — on the sofa, at the
/// whiteboard, with the laptop open across the room. A notification there is a
/// banner nobody sees; a sentence is heard. Never to someone typing, who has
/// the banner, and never to a locked screen, which is an empty room or an
/// absence about to be counted (D114).
public enum SpokenAlert {

    /// The longest row name said; past it a name is a path, not a name.
    public static let longestName = 40

    public static func speaks(enabled: Bool, idle: TimeInterval, locked: Bool) -> Bool {
        enabled && !locked && idle >= AppConfig.speakAfterIdle
    }

    /// "docs-site is waiting for you." One plain line, nothing a synthesizer
    /// would read as a control.
    public static func sentence(name: String) -> String {
        let flat = RowActivity.flat(name)
        return flat.isEmpty ? "A session is waiting for you." : "\(flat.prefix(longestName)) is waiting for you."
    }
}
