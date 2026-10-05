import Foundation

/// Fills a `SessionCard` from a transcript, one chunk at a time.
///
/// Shaped after `TranscriptTail`: it keeps the partial line a chunk ended on and
/// splits on the newline byte, so the runtime can hand it whatever a file read
/// returned since the last offset. The prompts and the answer come from
/// `TranscriptDecoder`, which already knows a typed prompt from the tool results
/// and the notifications that share its record type; what is new here is the
/// work: files written, calls that failed, and what got saved.
///
/// Everything it keeps is bounded, because a card lives as long as the panel
/// and a transcript can grow for days.
public struct SessionCardReader: Sendable, Equatable {

    static let promptsKept = 3
    static let promptLength = 220
    static let answerLength = 450
    static let writesKept = 200
    static let failuresKept = 50
    static let milestonesKept = 20
    static let pendingKept = 200

    public private(set) var card: SessionCard
    private var carry = ""
    /// Tool calls waiting for their result, by id: the result says whether it
    /// failed, the call says what it was.
    private var pending: [String: PendingCall] = [:]
    private var pendingOrder: [String] = []

    struct PendingCall: Sendable, Equatable {
        let tool: String
        let milestone: Milestone?

        enum Milestone: Sendable, Equatable {
            case saved(SessionCard.Milestone.Kind)
            case tests
        }
    }

    public init(sessionId: String) {
        card = SessionCard(sessionId: sessionId)
    }

    /// Reads a chunk of the transcript. A line cut at the end of the chunk is
    /// kept for the next call.
    public mutating func consume(_ chunk: String) {
        let text = carry + chunk
        var lines = text.utf8
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(text[$0.startIndex..<$0.endIndex]) }
        carry = lines.popLast() ?? ""
        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            consume(record: record)
        }
    }

    /// Reads one decoded transcript record.
    public mutating func consume(record: [String: Any]) {
        let type = record["type"] as? String
        if type == "ai-title", let title = (record["aiTitle"] as? String)?.trimmed.nilIfEmpty {
            card.title = title
            return
        }
        guard type == "user" || type == "assistant" else { return }
        if record["isSidechain"] as? Bool == true { return }
        if let cwd = (record["cwd"] as? String)?.nilIfEmpty { card.cwd = cwd }
        if let entrypoint = (record["entrypoint"] as? String)?.nilIfEmpty { card.entrypoint = entrypoint }
        if let branch = (record["gitBranch"] as? String)?.nilIfEmpty { card.gitBranch = branch }
        let at = TranscriptDecoder.date(from: record["timestamp"] as? String)
        card.lastActivity = max(card.lastActivity ?? at, at)

        for entry in TranscriptDecoder.entries(from: record) {
            switch entry.kind {
            case .human:
                card.recentPrompts.append(Self.clip(entry.text, Self.promptLength))
                card.recentPrompts = Array(card.recentPrompts.suffix(Self.promptsKept))
                card.lastPromptAt = entry.timestamp
            case .assistant:
                card.lastAnswer = Self.clip(entry.text, Self.answerLength)
                card.lastAnswerAt = entry.timestamp
            case .activity, .note:
                break
            }
        }

        let message = record["message"] as? [String: Any] ?? [:]
        let blocks = message["content"] as? [[String: Any]] ?? []
        if type == "assistant" {
            if let model = (message["model"] as? String)?.nilIfEmpty, model != "<synthetic>" {
                card.model = model
            }
            if let usage = message["usage"] as? [String: Any] {
                let total = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
                if total > 0 { card.contextTokens = total }
            }
            for block in blocks where block["type"] as? String == "tool_use" {
                call(block, at: at)
            }
        } else {
            for block in blocks where block["type"] as? String == "tool_result" {
                result(block, at: at)
            }
        }
    }

    // MARK: - Calls and results

    private mutating func call(_ block: [String: Any], at: Date) {
        guard let id = block["id"] as? String, let tool = block["name"] as? String else { return }
        let input = block["input"] as? [String: Any] ?? [:]

        if Self.writingTools.contains(tool), let path = (input["file_path"] as? String)?.nilIfEmpty {
            card.writes.append(.init(path: path, at: at))
            card.writes = Array(card.writes.suffix(Self.writesKept))
        }
        var milestone: PendingCall.Milestone?
        if tool == "Bash", let command = input["command"] as? String {
            milestone = Self.milestone(of: command)
        }
        pending[id] = PendingCall(tool: tool, milestone: milestone)
        pendingOrder.append(id)
        if pendingOrder.count > Self.pendingKept {
            pending[pendingOrder.removeFirst()] = nil
        }
    }

    private mutating func result(_ block: [String: Any], at: Date) {
        guard let id = block["tool_use_id"] as? String, let call = pending.removeValue(forKey: id)
        else { return }
        pendingOrder.removeAll { $0 == id }
        let failed = block["is_error"] as? Bool == true

        if failed {
            let text = Self.text(of: block["content"])
            card.failures.append(.init(tool: call.tool, fingerprint: FailureFingerprint.of(text), at: at,
                                       terms: FailureFingerprint.terms(of: text)))
            card.failures = Array(card.failures.suffix(Self.failuresKept))
        }
        switch call.milestone {
        case .saved(let kind) where !failed:
            record(kind, at: at)
        case .tests:
            record(failed ? .testsFailed : .testsPassed, at: at)
        default:
            break
        }
    }

    private mutating func record(_ kind: SessionCard.Milestone.Kind, at: Date) {
        card.milestones.append(.init(kind: kind, at: at))
        card.milestones = Array(card.milestones.suffix(Self.milestonesKept))
    }

    // MARK: - Reading commands

    static let writingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// What a shell command would prove if it succeeds.
    ///
    /// Only the first word of each `&&` or `;` step is looked at, after `git`:
    /// a commit message that mentions "merge" is not a merge.
    static func milestone(of command: String) -> PendingCall.Milestone? {
        let steps = command.components(separatedBy: CharacterSet(charactersIn: ";&|\n"))
            .map { $0.trimmed }
        var found: PendingCall.Milestone?
        for step in steps {
            let words = step.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let first = words.first else { continue }
            if first == "git", let verb = gitVerb(words) {
                switch verb {
                case "commit": found = .saved(.commit)
                case "merge": found = .saved(.merge)
                case "push": found = .saved(.push)
                default: break
                }
            } else if first == "gh", words.count >= 3, words[1] == "pr", words[2] == "create" {
                found = .saved(.pullRequest)
            } else if Self.isTestCommand(words) {
                return .tests
            }
        }
        return found
    }

    /// The subcommand of a `git` invocation, past the global options; `-C` and
    /// `-c` take a value, which is not the subcommand either.
    static func gitVerb(_ words: [String]) -> String? {
        var index = 1
        while index < words.count {
            let word = words[index]
            if word == "-C" || word == "-c" { index += 2; continue }
            if word.hasPrefix("-") { index += 1; continue }
            return word
        }
        return nil
    }

    static func isTestCommand(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        let tool = (first as NSString).lastPathComponent
        if tool.hasSuffix("test.sh") || ["pytest", "vitest", "jest"].contains(tool) { return true }
        let second = words.dropFirst().first ?? ""
        return (["swift", "npm", "pnpm", "yarn", "go", "cargo"].contains(tool) && second == "test")
            || (tool == "npx" && ["vitest", "jest", "playwright"].contains(second))
    }

    static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        let parts = (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return parts.joined(separator: "\n")
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }
}
