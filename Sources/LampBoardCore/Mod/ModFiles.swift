import Foundation

/// The companion mod's files, as the app writes them out to install it.
///
/// The app carries the mod rather than pointing Claude Code at GitHub: the mod
/// installed is then the one this version of the panel reads, word for word,
/// with no network and on a node as on the Mac (D66). The same files sit in the
/// repository under `mod/` and `.claude-plugin/`, which makes the repository a
/// marketplace too; `ModFilesSuite` holds the two copies to the same bytes.
public enum ModFiles {

    /// Bumped with any change to the files: the panel refreshes an installed
    /// mod whose version differs.
    public static let version = "2.0.0"

    /// Path inside the marketplace folder → content, each ending in a newline
    /// as the files in the repository do.
    public static var all: [(path: String, content: String)] {
        [
            (".claude-plugin/marketplace.json", marketplace),
            ("mod/.claude-plugin/plugin.json", plugin),
            ("mod/hooks/hooks.json", hooks),
            ("mod/hooks/register.js", register),
            ("mod/hooks/lamps.js", lamps),
            ("mod/hooks/look.js", look),
            ("mod/hooks/inbox.js", inbox),
            ("mod/hooks/ed25519.js", ed25519),
        ].map { ($0.0, $0.1 + "\n") }
    }

    public static let marketplace = #"""
{
  "name": "lampboard",
  "description": "LampBoard's own plugins, installed by the LampBoard app.",
  "owner": {
    "name": "LampBoard"
  },
  "plugins": [
    {
      "name": "lampboard",
      "source": "./mod",
      "description": "LampBoard's companion mod: context, cost and rate limits of each session, for the LampBoard panel."
    }
  ]
}
"""#

    public static let plugin = #"""
{
  "name": "lampboard",
  "version": "2.0.0",
  "description": "LampBoard's companion: tells the LampBoard panel on this Mac each session's context, cost and rate limits, asks LampMaster with /lampmaster, writes a handoff for another session with /handoff, shows every lamp beside the conversation with /lamps, draws the conversation like Claude Code's VS Code panel where LampBoard says so, answers the panel's side questions without a turn, hands each session the decisions pinned for its repository, and runs a session on the model the panel lowered it to until the window resets. Talks only to 127.0.0.1.",
  "author": { "name": "LampBoard" },
  "homepage": "https://github.com/marmyx77/lampboard",
  "license": "MIT"
}
"""#

    public static let hooks = #"""
{ "modules": ["./register.js"] }
"""#

}
