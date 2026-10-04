import Foundation

/// What the companion mod does, in sentences, from what Claude Code itself
/// reads in it (plan 5.10).
///
/// The source is `claude plugin validate --strict --json` run on the folder
/// the app installs from: Claude Code's own static reading of the module, not
/// a description of ours. A mod running in every session is installed only if
/// one can see what it does, so the sentences are built from what the reading
/// lists — and anything this table does not know is shown as Claude Code
/// spelled it, never left out: a changed mod must look changed.
public enum ModTrust {

    public struct Reading: Equatable, Sendable {
        public let valid: Bool
        public let sentences: [String]
        public let problems: [String]
    }

    static let hooks = [
        "session.start": "when a session starts",
        "session.measure": "when its context, cost or limits change",
        "session.end": "when it ends",
    ]

    /// Claude Code's capability, in words, and no more than it says: which
    /// files and which addresses is LampBoard's own claim, made in the text
    /// beside the switch, not dressed up as Claude Code's reading.
    static let calls = [
        "$.env.get": "reads environment variables",
        "$.fs.read": "reads files",
        "$.http.fetch": "makes network requests",
        "$.session.id": "reads the session's id",
        "$.session.model": "reads the session's model name",
    ]

    /// `nil` when the text is not `validate`'s JSON.
    public static func read(validateJSON data: Data) -> Reading? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let valid = object["success"] as? Bool
        else { return nil }
        let entries = [object["manifest"]].compactMap { $0 as? [String: Any] }
            + ((object["contents"] as? [[String: Any]]) ?? [])
        var sentences: [String] = []
        var problems: [String] = []
        for entry in entries {
            for key in ["errors", "warnings"] {
                for problem in (entry[key] as? [[String: Any]]) ?? [] {
                    problems.append((problem["message"] as? String) ?? "\(key.dropLast()) without a message")
                }
            }
            for note in (entry["notes"] as? [String]) ?? [] {
                sentences.append(sentence(for: note))
            }
        }
        // A valid reading that lists nothing is not "it does nothing": the
        // notes moved or were renamed, and an empty list under "as Claude Code
        // reads it" would look exactly like a mod with nothing to declare.
        if valid, sentences.isEmpty { return nil }
        return Reading(valid: valid, sentences: sentences, problems: problems)
    }

    /// One note of `validate` as a sentence: `./register.js calls: $.fs.read
    /// (via panel), …` reads "It reads files (LampBoard's token and port), …".
    static func sentence(for note: String) -> String {
        guard let colon = note.range(of: ": ") else { return note }
        let label = note[..<colon.lowerBound]
        let items = note[colon.upperBound...].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #" \(via [^)]*\)"#, with: "", options: .regularExpression)
        }
        if label.hasSuffix(" hooks") {
            return "It runs " + list(items.map { hooks[$0] ?? "on \($0)" }) + "."
        }
        if label.hasSuffix(" calls") {
            return "It " + list(items.map { calls[$0] ?? "uses \($0)" }) + "."
        }
        if label.hasSuffix(" env reads") {
            return "It reads the environment variables " + list(items) + "."
        }
        if label.hasSuffix(" env writes") {
            return items == ["nothing"] ? "It changes no environment variable." : "It sets " + list(items) + "."
        }
        return note
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return "nothing"
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
