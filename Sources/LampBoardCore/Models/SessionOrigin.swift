import Foundation

/// Where a session's row comes from: which kind of place it lives in.
///
/// A session whose folder an editor window has open is an **editor** row, however
/// it was started. A session whose folder nobody claims is a **terminal** row: its
/// place is the terminal tab hosting its process, and that is what a click has to
/// find. The two are told apart here, once, by whoever resolves the workspace —
/// never inferred from the entrypoint: `claude` typed in the integrated terminal
/// is `cli` and an editor row.
///
/// Not part of `Workspace`, on purpose: that type is the row's identity, and a
/// terminal session and an editor session in the same folder must still group.
public enum SessionOrigin: String, Sendable, Equatable, Codable {
    case editor
    case terminal
    /// Started with `claude --bg` (§5.14): no tab and no window. Its place is
    /// the panel's own Plancia, whatever editor has its folder open.
    case background
}
