import Foundation

/// The folders of another machine, one level at a time, for attaching a project
/// there (hub-terminale R3): what `ssh` runs, and its answer read back. The first
/// line is where the listing stands, absolute; then one folder a line, hidden
/// ones left out. Every path is single-quoted; `nil` stands for the home folder.
public enum RemoteFolders {

    public struct Listing: Equatable, Sendable {
        public let path: String
        public let folders: [String]

        /// The folder above, or `nil` at the root.
        public var parent: String? {
            guard path != "/" else { return nil }
            let up = (path as NSString).deletingLastPathComponent
            return up.isEmpty ? "/" : up
        }

        public func child(_ name: String) -> String { path == "/" ? "/" + name : path + "/" + name }
    }

    /// The most folders a listing returns.
    public static let mostFolders = 500

    /// The script for `path`, or the home folder; `nil` for a path that is not absolute.
    public static func list(_ path: String?) -> String? {
        let go: String
        if let path {
            guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            go = "cd -- " + NewSession.shellQuoted(path)
        } else {
            go = "cd \"$HOME\""
        }
        return go + " 2>/dev/null || exit 3; pwd; for d in *; do [ -d \"$d\" ] && printf '%s\\n' \"$d\"; done | head -n \(mostFolders)"
    }

    /// The answer read back; `nil` when it is not one (the folder was not there).
    public static func parse(_ output: String) -> Listing? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first, first.hasPrefix("/") else { return nil }
        lines.removeFirst()
        let folders = lines.filter { !$0.hasPrefix(".") && $0 != "*" && !$0.contains("/") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Listing(path: first, folders: folders)
    }
}
