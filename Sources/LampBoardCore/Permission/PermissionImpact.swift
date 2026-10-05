import Foundation

/// What a permission would do, in a few words beside its Allow (D87): a shell
/// command that destroys — read off its one masked line — or how many lines an
/// edit or a write touches, counted by the mod from the call's own input.
///
/// Not a simulation: nothing is run to find out. A command this does not know
/// to be destructive is not said to be safe; it is said nothing about.
public enum PermissionImpact {

    /// The commands a click should not approve unread, by the words that name
    /// them: a fixed set of spellings, not a guarantee. First match wins, so
    /// the more telling label comes first; the label is what the card says.
    static let destructive: [(label: String, pattern: String)] = [
        ("runs a downloaded script", #"\b(curl|wget)\b[^;&]*\|\s*(sudo\s+)?(\S*/)?(sh|bash|zsh)\b|\b(sh|bash|zsh)\s+<\(\s*(curl|wget)|\$\(\s*(curl|wget)\b"#),
        ("deletes recursively", #"(?<!git\s)\brm\b[^;&|]*\s(-[A-Za-z]*[rR][A-Za-z]*|--recursive)\b|\bfind\b[^;&|]*\s(-delete|-exec\s+rm)\b"#),
        ("deletes", #"(?<!git\s)\brm\b[^;&|]*\s-[A-Za-z]*f|\bshred\b"#),
        ("force-pushes", #"\bgit\s+(-C\s+\S+\s+)?push\b[^;&|]*(\s--force(-with-lease)?\b|\s-[A-Za-z]*f[A-Za-z]*\b|\s--mirror\b|\s--delete\b|\s\+\S|\s:\S)"#),
        ("discards changes", #"\bgit\s+(-C\s+\S+\s+)?(reset\s+--hard|checkout\s+(--\s|\.(\s|$)|-f\b)|restore\s+(?!--staged)|clean\b[^;&|]*(\s-[A-Za-z]*f|\s--force)|stash\s+(drop|clear)|branch\s+-D)"#),
        ("overwrites a file or disk", #"\bdd\b[^;&|]*\bof=|\bmkfs|\btruncate\s+-s\s*0"#),
        ("drops data", #"(?i)\b(drop\s+(table|database|schema|index)|truncate\s+table|delete\s+from)\b"#),
        ("changes permissions recursively", #"\b(chmod|chown)\b[^;&|]*\s(-[A-Za-z]*R|--recursive)\b"#),
        ("runs as root", #"(^|[;&|(]\s*|\b(then|xargs|time|env(\s+\w+=\S+)*)\s+)sudo\s"#),
    ]

    private static let compiled: [(label: String, regex: NSRegularExpression)] = destructive.compactMap { entry in
        (try? NSRegularExpression(pattern: entry.pattern)).map { (entry.label, $0) }
    }

    /// Said when the command goes on past the line the card shows: what the
    /// rest does is unread here, and a card with no warning must not read as
    /// one that was checked whole.
    public static let unseen = "more lines unseen"

    /// - Parameters:
    ///   - tool: the call's tool, as the card names it.
    ///   - line: the call's one line as the card shows it (masked).
    ///   - lines: removed and added, from the mod, for an edit or a write.
    ///   - partial: the command goes on past the line given (the mod says so).
    public static func of(tool: String, line: String, lines: (removed: Int, added: Int)? = nil, partial: Bool = false) -> String? {
        switch tool {
        case "Bash":
            let range = NSRange(line.startIndex..., in: line)
            if let hit = compiled.first(where: { $0.regex.firstMatch(in: line, range: range) != nil }) { return hit.label }
            return partial ? unseen : nil
        case "Edit", "MultiEdit":
            guard let lines else { return nil }
            return "−\(lines.removed) +\(lines.added) \(lines.removed + lines.added == 1 ? "line" : "lines")"
        case "Write":
            guard let lines else { return nil }
            return "writes \(lines.added) \(lines.added == 1 ? "line" : "lines")"
        default:
            return nil
        }
    }

    /// Whether what it says is a warning, drawn as one.
    public static func warns(_ impact: String) -> Bool {
        destructive.contains { $0.label == impact }
    }

    /// The counts the mod sends, `{"removed","added"}`, each a whole number in
    /// range, or nothing.
    public static func lines(from object: Any?) -> (removed: Int, added: Int)? {
        guard let object = object as? [String: Any],
              let removed = object["removed"] as? Int, let added = object["added"] as? Int,
              (0...1_000_000).contains(removed), (0...1_000_000).contains(added)
        else { return nil }
        return (removed, added)
    }
}
