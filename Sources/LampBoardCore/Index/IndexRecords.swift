import Foundation

/// From a transcript to what the search index keeps (0.7, M1): the words the
/// person typed and Claude answered, and what is known of the conversation —
/// where it ran, what it is called, when, how many prompts.
///
/// Who spoke is `TranscriptDecoder`'s to say, the same reading the chat window
/// trusts: context, notes, tool calls and other sessions' messages are not the
/// conversation and are not indexed. Pure: the store reads files and keeps the
/// offsets, this reads lines.
public enum IndexRecords {

    /// The most kept of one message: a pasted log is not what is searched for.
    public static let textLimit = 4000

    public struct Message: Sendable, Equatable {
        public let id: String
        /// `user` or `assistant`.
        public let role: String
        public let at: Date
        public let text: String
    }

    /// What the lines said about the conversation; `nil` where they said nothing,
    /// so a later chunk adds to an earlier one rather than erasing it.
    public struct Facts: Sendable, Equatable {
        public var cwd: String?
        public var title: String?
        public var firstAt: Date?
        public var lastAt: Date?
        public var prompts = 0

        public init() {}

        /// This chunk's facts after an earlier chunk's.
        public func following(_ earlier: Facts) -> Facts {
            var merged = self
            // Where it began: a later `cd` is not where it resumes from.
            merged.cwd = earlier.cwd ?? cwd
            merged.title = title ?? earlier.title
            merged.firstAt = earlier.firstAt ?? firstAt
            merged.lastAt = lastAt ?? earlier.lastAt
            merged.prompts = earlier.prompts + prompts
            return merged
        }
    }

    /// Complete lines only: the store hands over what ends in a newline and
    /// keeps the rest for the next read.
    public static func read<S: Sequence>(lines: S) -> (facts: Facts, messages: [Message]) where S.Element: StringProtocol {
        var facts = Facts()
        var messages: [Message] = []
        for line in lines {
            let text = String(line)
            guard !text.isEmpty else { continue }
            if let title = TranscriptDecoder.title(fromLine: text) ?? namedTitle(text) { facts.title = title }
            if facts.cwd == nil, let cwd = cwd(of: text) { facts.cwd = cwd }
            for entry in TranscriptDecoder.entries(fromLine: text) {
                let role: String
                switch entry.kind {
                case .human: role = "user"; facts.prompts += 1
                case .assistant: role = "assistant"
                case .activity, .note: continue
                }
                let body = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                messages.append(Message(id: entry.id, role: role, at: entry.timestamp,
                                        text: body.count <= textLimit ? body : String(body.prefix(textLimit))))
                facts.firstAt = facts.firstAt ?? entry.timestamp
                facts.lastAt = entry.timestamp
            }
        }
        return (facts, messages)
    }

    // MARK: - Internals

    /// The person's own name for it (`custom-title`) or Claude Code's
    /// (`summary`), when the line is one of those.
    static func namedTitle(_ line: String) -> String? {
        guard line.contains("\"custom-title\"") || line.contains("\"summary\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return nil }
        switch object["type"] as? String {
        case "custom-title": return (object["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        case "summary": return (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        default: return nil
        }
    }

    static func cwd(of line: String) -> String? {
        guard line.contains("\"cwd\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let cwd = object["cwd"] as? String, cwd.hasPrefix("/")
        else { return nil }
        return cwd
    }
}

/// What the person typed in the bar, as an FTS5 query that cannot be misread
/// (0.7, M1): each word quoted, so a hyphen is a hyphen and not a column filter,
/// a quote cannot close the string, and an operator word is just a word.
/// Every word must appear; the last one may be the start of a word.
public enum IndexQuery {

    public static let maxWords = 8

    public static func fts(_ typed: String) -> String? {
        let words = typed
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./@")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-_./@")) }
            .filter { !$0.isEmpty }
            .prefix(maxWords)
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { index, word in
            let quoted = "\"" + word.replacingOccurrences(of: "\"", with: "") + "\""
            return index == words.count - 1 && word.count >= 2 ? quoted + "*" : quoted
        }.joined(separator: " ")
    }
}
