import Foundation

/// The live view's files (D136): the project's tree beside the session, the
/// file the agent is on, and a citation the session reads as an attachment.
public enum ProjectFiles {

    /// Folders nobody reads and that are large enough to slow a tree down.
    static let skipped: Set<String> = [".git", "node_modules", ".build", "DerivedData", "__pycache__", ".DS_Store",
                                       ".venv", ".gradle", ".next", ".turbo", ".cache"]

    /// Whether an entry of a folder is shown. Dotfiles stay (`.github`,
    /// `.claude`, `.env.example` are read and cited); the heavy ones go.
    public static func isShown(name: String) -> Bool { !name.isEmpty && !skipped.contains(name) }

    /// A folder's entries as a tree shows them: folders first, then files, each
    /// in Finder's order (`file2` before `file10`).
    public static func sorted(_ entries: [(name: String, isFolder: Bool)]) -> [(name: String, isFolder: Bool)] {
        entries.filter { isShown(name: $0.name) }.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// `@path#La-b`, as Claude Code's prompt attaches a file or its lines:
    /// relative to the session's folder when the file is inside it, a space
    /// escaped with a backslash (measured: quotes do not work, `\ ` does).
    public static func citation(path: String, root: String, lines: ClosedRange<Int>? = nil) -> String {
        let shown = relative(path, to: root) ?? path
        let escaped = shown.replacingOccurrences(of: " ", with: "\\ ")
        guard let lines else { return "@\(escaped) " }
        return "@\(escaped)#L\(lines.lowerBound)-\(lines.upperBound) "
    }

    /// `path` inside `root`, without the root; `nil` outside it.
    public static func relative(_ path: String, to root: String) -> String? {
        let root = (root as NSString).standardizingPath
        let path = (path as NSString).standardizingPath
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The tools whose detail is the file they work on.
    static let fileTools: Set<String> = ["Read", "Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// The file the agent is on, when it is one in the project: its tool works
    /// on files, and the path it names is absolute, whole and inside `root`.
    /// The helper cuts a detail at 120 characters, so a path that long may be
    /// cut, and is not followed.
    public static func followed(_ tool: RunningTool?, root: String) -> String? {
        guard let tool, fileTools.contains(tool.tool), let path = tool.detail,
              path.hasPrefix("/"), path.count < 120, relative(path, to: root) != nil else { return nil }
        return (path as NSString).standardizingPath
    }

    /// The lines a selection covers, counted from 1. The selection is in UTF-16
    /// units, as a text view reports it; one that ends at the start of a line
    /// does not take that line.
    public static func lines(in text: String, selection: Range<Int>) -> ClosedRange<Int>? {
        let units = text.utf16
        guard selection.lowerBound >= 0, selection.upperBound <= units.count else { return nil }
        let newline = UInt16(UInt8(ascii: "\n"))
        // One pass, no copy: a megabyte's selection is dragged event by event.
        var first = 1, last = 1, offset = 0
        var end = selection.upperBound
        if end > selection.lowerBound, units[units.index(units.startIndex, offsetBy: end - 1)] == newline { end -= 1 }
        for unit in units {
            if offset >= end { break }
            if unit == newline {
                if offset < selection.lowerBound { first += 1 }
                last += 1
            }
            offset += 1
        }
        return first...max(first, last)
    }

    /// What the preview shows of a file: text up to a megabyte; `nil` for
    /// anything larger, or not text.
    public static let previewLimit = 1_048_576

    public static func previewText(_ data: Data) -> String? {
        guard data.count <= previewLimit, !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
