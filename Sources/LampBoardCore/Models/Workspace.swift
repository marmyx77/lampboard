import Foundation

/// A working folder a session is running in.
///
/// Locally that means a folder open in a VS Code window. On another machine it
/// means the session's own folder: asking whether a VS Code window claims it is
/// meaningless for a session in a tmux pane on a headless node, and applying the
/// local criterion there is what kept those rows invisible.
public struct Workspace: Sendable, Equatable, Hashable {
    /// Absolute path of the workspace root folder.
    public let path: String

    /// The machine it lives on, as it is written in `~/.ssh/config`. `nil` means
    /// this one.
    ///
    /// Part of the identity, not decoration: two machines can hold the same path,
    /// and a row per machine is the only honest answer. Without this they would
    /// collapse into one and the column would show a folder in two states at once.
    public let host: String?

    public init(path: String, host: String? = nil) {
        self.path = PathNormalizer.normalize(path)
        self.host = host?.trimmed.nilIfEmpty
    }

    /// `true` when the folder is on another machine.
    ///
    /// What it gates is behavior, not just looks: there is no local window to
    /// bring to the front, and no local transcript to open.
    public var isRemote: Bool { host != nil }

    /// The string that identifies this workspace wherever one is needed: the
    /// grouping key, the row's id, and the key under which its name, its slot,
    /// its place in the order, its hiding and its muting are all remembered.
    ///
    /// It exists because the type's own promise above was not being kept. `host`
    /// is part of `Equatable` and `Hashable`, and every one of those callers
    /// keyed on `path` alone: a folder called `/w/project` on this Mac and one on
    /// a remote node became **one row**, in whichever state the more urgent
    /// member happened to be, and hiding one hid both. A comment claiming an
    /// identity the code does not enforce is worse than no comment, because the
    /// next reader stops checking.
    ///
    /// A local workspace keys on its path and nothing else, which is not a
    /// convenience: every name, slot and hidden flag anybody has saved is stored
    /// under that string, so keeping it identical is what makes this change cost
    /// nobody their layout.
    ///
    /// A remote one is the host, a colon, then the path. The first spelling
    /// tried was `//host` and the path, and it was quietly wrong: these keys pass
    /// through `PathNormalizer.normalize` on their way into `RowNames`, which
    /// collapses every run of slashes, so the key that went in was never the key
    /// that came back out and a renamed remote row lost its name. A leading
    /// character that is not a slash cannot be a path at all, so the colon form
    /// collides with nothing and survives being normalised.
    public var key: String {
        guard let host else { return path }
        return host + ":" + path
    }

    /// Name shown next to the traffic light — it matches what VS Code writes in
    /// the window title, and it is the key used to find that window again.
    ///
    /// Deliberately **without** the host: this value is matched against window
    /// titles, and adding anything to it would break that match.
    ///
    /// It is also the only name there is. There used to be a second one, `label`,
    /// that appended ` @host` for the column to draw, and on a machine called
    /// `minisforum` it ate the name it was meant to qualify: eleven characters of
    /// a field about a hundred points wide, on every row of that machine, saying
    /// the same word every time. The row shows a mark instead and the host is
    /// spelled out in the tooltip, where there is room for the word "on" — see
    /// `RowSummary.subtitle`.
    public var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

/// Path normalization, kept separate because both the resolver and `Workspace` use it.
public enum PathNormalizer {
    /// Strips trailing slashes and collapses doubled ones, without touching the filesystem.
    ///
    /// Deliberately does not resolve symlinks: `cwd` and `workspaceFolders` come from
    /// the same source (Claude Code) and are already consistent with each other.
    /// Resolving links would mean I/O on every signal in exchange for no real case covered.
    public static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let collapsed = path.replacingOccurrences(
            of: "/+", with: "/", options: .regularExpression
        )
        guard collapsed.count > 1, collapsed.hasSuffix("/") else { return collapsed }
        return String(collapsed.dropLast())
    }

    /// `true` when `candidate` is `parent` or one of its subfolders.
    ///
    /// The comparison runs component by component, not by string prefix: otherwise
    /// `/dev/lampboard-old` would come out as contained in `/dev/lampboard`.
    public static func isDescendant(_ candidate: String, of parent: String) -> Bool {
        let candidate = normalize(candidate)
        let parent = normalize(parent)
        if candidate == parent { return true }
        return candidate.hasPrefix(parent + "/")
    }
}
