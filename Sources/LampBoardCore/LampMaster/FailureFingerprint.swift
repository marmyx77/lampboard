import Foundation

/// An error message reduced to what stays the same when it happens again.
///
/// WHY
/// Two of LampMaster's jobs hang on recognising the same failure: a session
/// failing the same way three times in an hour is stuck, and a failure some
/// other session met last month is a precedent worth a look. The raw text
/// never matches twice: it carries the absolute path of the checkout, the line
/// number, a temporary directory, a process id, a commit hash. Those go; the
/// words stay.
public enum FailureFingerprint {

    static let length = 120

    /// The fingerprint of an error's text.
    ///
    /// The line chosen is the first that says it is an error, or else the
    /// first non-empty one: compilers and package managers lead with noise
    /// (progress, the command echoed back) and put the reason on a line of its
    /// own.
    public static func of(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmed }.filter { !$0.isEmpty }
        let chosen = lines.first(where: isErrorLine) ?? lines.first ?? ""
        return normalise(chosen)
    }

    static func isErrorLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["error", "failed", "fatal", "exception", "not found", "denied", "panic"]
            .contains { lower.contains($0) }
    }

    static func normalise(_ line: String) -> String {
        var text = line.lowercased()
        let rules: [(String, String)] = [
            (#"(?:~|/)[^\s:'"`,)]*"#, "<path>"),     // paths, absolute or home-relative
            (#"\b(?=[0-9a-f]*\d)[0-9a-f]{7,64}\b"#, "<hex>"), // hashes and ids, never a word
            (#"\d+"#, "#"),                          // line numbers, pids, sizes
            (#"\s+"#, " "),
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.trimmed
        return text.count <= length ? text : String(text.prefix(length))
    }
}
