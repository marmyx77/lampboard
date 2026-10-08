import Foundation

/// Starting a session from LampBoard (D133): what is offered, and what runs.
///
/// On this Mac a new session starts in the background (`claude --bg`), where
/// Claude Code's supervisor keeps it. On another machine it starts inside tmux:
/// it outlives the window and the ssh, any terminal can attach to it, and Remote
/// Control reaches it when that machine has it switched on. Nothing here names a
/// machine: the hosts are the person's, from Settings › Other Macs.
public enum NewSession {

    /// The folders a machine's sessions worked in, the most recent first.
    public static func recentFolders(in state: TrafficLightState, host: String?, limit: Int = 12) -> [String] {
        var seen = Set<String>()
        return state.sessions.values
            .filter { $0.workspace.host == host }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.workspace.path)
            .filter { seen.insert($0).inserted }
            .prefix(limit).map { $0 }
    }

    /// A tmux session name from a folder: letters, digits, dashes and
    /// underscores, at most forty, and not one already `taken` there.
    public static func tmuxName(for folder: String, taken: Set<String>) -> String {
        let base = (folder as NSString).lastPathComponent
        var name = String(base.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : (scalar == "_" ? "_" : "-")
        })
        while name.hasPrefix("-") || name.hasPrefix("_") { name.removeFirst() }
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = String(name.prefix(40))
        while name.hasSuffix("-") { name.removeLast() }
        if name.isEmpty { name = "claude" }
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name)-\(number)") { number += 1 }
        return "\(name)-\(number)"
    }

    /// One word for a POSIX shell: single quotes, a quote inside closed and reopened.
    public static func shellQuoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A script for whatever login shell the other machine has: ssh hands its
    /// command to that shell, and fish or csh would not read a POSIX one.
    public static func posix(_ script: String) -> String { "sh -c " + shellQuoted(script) }

    /// A fresh tag for a session LampBoard starts in tmux.
    public static func newLaunchTag() -> String {
        String(UUID().uuidString.lowercased().filter { $0 != "-" }.prefix(16))
    }

    /// What a tag may be: sixteen to thirty-two lowercase hex digits, safe in a
    /// shell, in a sed pattern and in a tmux option.
    public static func isLaunchTag(_ tag: String) -> Bool {
        (16...32).contains(tag.count) && tag.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// What the other machine runs, under `sh` (D133). If a tmux session there
    /// already carries `launch`, it attaches to it: a reattach never starts a
    /// second one. Otherwise, in an existing `folder`, a new session named
    /// `name` or, if anything there has that name, `name-2` and on, so a tmux
    /// session of the person's is never joined. Its first pane is the person's
    /// own shell, interactive so that its startup files put `claude` on PATH,
    /// running `claude` and staying open when it ends. One command string for
    /// tmux, which a tmux older than 3.0 needs.
    public static func remoteCommand(folder: String, name: String, launch: String) -> String {
        let quoted = shellQuoted(name)
        let folder = shellQuoted(folder)
        let pane = shellQuoted(#""$SHELL" -ilc 'claude; exec "$SHELL" -l'"#)
        return [
            #"export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin""#,
            "l=\(launch)",
            #"n=$(tmux list-sessions -F '#{@lampboard} #{session_name}' 2>/dev/null | sed -n "s/^$l //p" | head -n 1)"#,
            "if [ -z \"$n\" ]; then",
            "  test -d \(folder) || { echo \"There is no folder \"\(folder)\" on this machine.\"; exit 1; }",
            "  n=\(quoted); i=2; while tmux has-session -t \"=$n\" 2>/dev/null; do n=\(quoted)-$i; i=$((i+1)); done",
            "  tmux new-session -d -s \"$n\" -c \(folder) \(pane) || exit 1",
            "  tmux set-option -t \"=$n:\" @lampboard \"$l\"",
            "fi",
            "exec tmux attach-session -t \"=$n:\"",
        ].joined(separator: "\n")
    }
}
