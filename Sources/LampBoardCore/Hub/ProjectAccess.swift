import Foundation

/// The Hub's look into a session's project (D156): a tree, a file, what git
/// says, a search, a shell — on this Mac from the disk, on another machine
/// through the panel's own ssh, never through the session's mod.
///
/// Everything here is confined to the project's folder: a path is relative,
/// has no `..`, does not start with a dash (it would read as an option) and
/// carries no control character. A file that resolves outside the folder (a
/// link) is refused where it is read: here by the app, there by the script.
public enum ProjectAccess {

    /// The relative path, if it stays inside the project.
    public static func relative(_ path: String) -> String? {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.hasPrefix("-"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// Whether `resolved` (a real path) is the project's `root` or inside it.
    public static func isInside(_ resolved: String, root: String) -> Bool {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return resolved == base || resolved.hasPrefix(base + "/")
    }

    /// How a file is shown.
    public enum Kind: Equatable, Sendable {
        /// Code or text, with the highlighter's language when it has one.
        case code(language: String)
        /// Markdown: Code or Preview.
        case markdown
        /// An image, a PDF, an archive: not drawn as text.
        case binary
    }

    public static func kind(of name: String) -> Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdx": return .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "zip", "gz", "tgz", "dmg", "ico", "icns",
             "mp3", "mp4", "mov", "wav", "woff", "woff2", "ttf", "otf", "sqlite", "db", "o", "a", "dylib":
            return .binary
        default:
            return .code(language: ext.isEmpty ? name.lowercased() : ext)
        }
    }

    /// The most of a file the preview reads: a log of gigabytes must not hold the Hub.
    public static let previewBytes = 1_000_000
}

/// What `git status --porcelain=v1` says, by relative path: `M`, `A`, `D`, `R`, `?`.
public enum GitStatus {

    public static func parse(_ porcelain: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in porcelain.split(separator: "\n") where line.count > 3 {
            let codes = line.prefix(2)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            let code: String
            if codes == "??" { code = "?" }
            else if codes.contains("A") { code = "A" }
            else if codes.contains("D") { code = "D" }
            else if codes.contains("R") { code = "R" }
            else { code = "M" }
            result[path] = code
        }
        return result
    }
}

/// What the session did to each file lately (the Hub's colours): read, written,
/// or written and then in a commit. From the tools it ran, never from a model.
public enum FileMarks {

    public enum Mark: String, Equatable, Sendable { case read, written, committed }

    static let readers: Set<String> = ["Read", "Grep", "Glob", "NotebookRead"]
    static let writers: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// `tools`: (name, detail) oldest first, where the detail of a file tool is
    /// its path and a command's is its first line. `changed`: what git calls
    /// changed now. A file written before a `git commit` and no longer changed
    /// went into that commit.
    public static func marks(tools: [(name: String, detail: String?)], root: String, changed: Set<String>) -> [String: Mark] {
        var result: [String: Mark] = [:]
        var writtenBeforeCommit: Set<String> = []
        for tool in tools {
            guard let detail = tool.detail else { continue }
            if tool.name == "Bash", detail.trimmingCharacters(in: .whitespaces).hasPrefix("git commit") {
                writtenBeforeCommit.formUnion(result.filter { $0.value == .written }.keys)
                continue
            }
            guard let path = relative(detail, root: root) else { continue }
            if writers.contains(tool.name) {
                result[path] = .written
            } else if readers.contains(tool.name), result[path] == nil {
                result[path] = .read
            }
        }
        for path in writtenBeforeCommit where !changed.contains(path) && result[path] == .written {
            result[path] = .committed
        }
        return result
    }

    private static func relative(_ path: String, root: String) -> String? {
        let base = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(base) { return ProjectAccess.relative(String(path.dropFirst(base.count))) }
        return path.hasPrefix("/") ? nil : ProjectAccess.relative(path)
    }
}

/// The commands the panel runs on another machine, through its own ssh, to look
/// into a project there. Each is one `sh -c` script with every value quoted;
/// each resolves the real path and refuses one outside the folder.
public enum RemoteProject {

    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Entries of a folder, one per line, a folder ending in `/`. The folder is
    /// resolved (`pwd -P`): one that is a link out of the project is refused.
    public static func list(root: String, relative: String?) -> String? {
        if let relative, ProjectAccess.relative(relative) == nil { return nil }
        let target = quote(relative.map { "./" + $0 } ?? ".")
        return "cd -- \(quote(root)) && r=$(pwd -P) && p=$(cd -- \(target) 2>/dev/null && pwd -P) "
            + "&& case \"$p/\" in \"$r\"/*) ls -1Ap -- \"$p\" ;; *) exit 3 ;; esac"
    }

    /// The first bytes of a file: its folder resolved and inside the project,
    /// the file itself a regular file and not a link.
    public static func read(root: String, relative: String) -> String? {
        guard ProjectAccess.relative(relative) != nil else { return nil }
        let target = quote("./" + relative)
        return "cd -- \(quote(root)) && r=$(pwd -P) && d=$(cd -- \"$(dirname -- \(target))\" 2>/dev/null && pwd -P) "
            + "&& p=\"$d/$(basename -- \(target))\" && [ -f \"$p\" ] && [ ! -L \"$p\" ] "
            + "&& case \"$d/\" in \"$r\"/*) head -c \(ProjectAccess.previewBytes) -- \"$p\" ;; *) exit 3 ;; esac"
    }

    public static func gitStatus(root: String) -> String {
        "cd -- \(quote(root)) && git status --porcelain=v1 2>/dev/null | head -n 2000"
    }

    /// Lines matching `query`, fixed string, at most two hundred.
    public static func search(root: String, query: String) -> String? {
        guard !query.isEmpty, query.utf8.count <= 200, !query.contains("\n") else { return nil }
        return "cd -- \(quote(root)) && grep -rnIF --exclude-dir=.git --exclude-dir=node_modules -m 5 -- \(quote(query)) . 2>/dev/null | head -n 200"
    }

    /// Takes a file on standard input into the project's attachments (P11):
    /// the folder made if missing and resolved inside the project, the name a
    /// plain one not there yet, `.lampboard/` written once into git's exclude.
    /// The same script runs here with `/bin/sh` and there through ssh.
    public static func attach(root: String, name: String) -> String? {
        guard !name.isEmpty, name == HubBar.attachmentName(name, taken: []) else { return nil }
        let folder = quote(HubBar.attachmentFolder)
        let file = "\"$d\"/" + quote(name)
        return "cd -- \(quote(root)) && r=$(pwd -P) && [ ! -L .lampboard ] && [ ! -L \(folder) ] && mkdir -p -- \(folder) && d=$(cd -- \(folder) && pwd -P) "
            + "&& case \"$d/\" in \"$r\"/*) ;; *) exit 3 ;; esac && [ ! -e \(file) ] && [ ! -L \(file) ] && cat > \(file) "
            + "&& { [ ! -d .git/info ] || grep -qxF '.lampboard/' .git/info/exclude 2>/dev/null || echo '.lampboard/' >> .git/info/exclude; }"
    }

    /// The names already in the attachments folder, one per line.
    public static func attachments(root: String) -> String {
        "cd -- \(quote(root)) && [ -d \(quote(HubBar.attachmentFolder)) ] && ls -1A -- \(quote(HubBar.attachmentFolder)) || true"
    }

}

/// A shell in the project's folder (D156): the person's own shell here, an ssh
/// with a terminal there. A shell, never the session: nothing it does reaches
/// the conversation, so it is no second writer.
public enum ProjectShell {

    public static func command(root: String, host: String?, shell: String, environment: [String: String]) -> LiveCommand {
        if let host {
            let script = "cd -- \(RemoteProject.quote(root)) && exec \"${SHELL:-/bin/sh}\" -l"
            return LiveCommand(executable: "/usr/bin/ssh", arguments: SSHHardening.options + ["-t", "--", host, script],
                               directory: nil, environment: environment)
        }
        return LiveCommand(executable: shell, arguments: ["-l"], directory: root, environment: environment)
    }
}

/// Lines from `grep -rn`: `./path:line:text`.
public enum SearchHits {

    public struct Hit: Equatable, Sendable {
        public let path: String
        public let line: Int
        public let text: String

        public init(path: String, line: Int, text: String) {
            self.path = path
            self.line = line
            self.text = text
        }
    }

    public static func parse(_ output: String) -> [Hit] {
        output.split(separator: "\n").compactMap { raw in
            let line = raw.hasPrefix("./") ? raw.dropFirst(2) : raw[...]
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]), let path = ProjectAccess.relative(String(parts[0])) else { return nil }
            return Hit(path: path, line: number, text: String(parts[2].prefix(300)))
        }
    }
}
