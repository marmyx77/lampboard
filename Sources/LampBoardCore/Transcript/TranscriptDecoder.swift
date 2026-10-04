import Foundation

/// Turns transcript lines into chat entries.
///
/// The second point where external data enters the domain, and it follows the
/// same rule as `HookPayloadDecoder`: nothing is inferred. What it does differently
/// is **fail quietly** — a line it does not understand yields no entries instead
/// of an error. That is deliberate. The transcript is Claude Code's own working
/// file and carries a dozen record types we have no business rendering
/// (`file-history-snapshot`, `queue-operation`, `mode`, …). Treating an unknown
/// type as a fault would turn every new Claude Code record into a broken window.
///
/// The one thing it must never do is guess who spoke. See `isHuman`.
public enum TranscriptDecoder {

    /// Decodes one JSONL line into zero, one or two entries.
    ///
    /// Two, because a single assistant record routinely holds an answer *and* the
    /// tool calls that produced it, and on screen those are different things.
    public static func entries(fromLine line: String) -> [TranscriptEntry] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return entries(from: object)
    }

    /// Decodes an already-parsed record.
    public static func entries(from record: [String: Any]) -> [TranscriptEntry] {
        guard let type = record["type"] as? String else { return [] }
        let uuid = (record["uuid"] as? String) ?? UUID().uuidString
        let timestamp = date(from: record["timestamp"] as? String)

        switch type {
        case "user":
            return userEntries(record, uuid: uuid, timestamp: timestamp)
        case "assistant":
            return assistantEntries(record, uuid: uuid, timestamp: timestamp)
        case "attachment":
            return queuedPeerEntries(record, uuid: uuid, timestamp: timestamp)
        default:
            return []
        }
    }

    /// The conversation title, when the line carries one.
    public static func title(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "ai-title"
        else { return nil }
        return (object["aiTitle"] as? String)?.trimmed.nilIfEmpty
    }

    // MARK: - User records

    /// A `user` record is usually **not** a human message.
    ///
    /// The role says `user` because that is where the protocol puts tool output,
    /// hook context and injected reminders — not because anybody typed anything.
    /// The only field that separates the two is `origin.kind`, checked against
    /// 7042 transcripts before being leaned on.
    ///
    /// The obvious shortcut is "no `toolUseResult` means a person wrote it", and
    /// it was measured rather than argued about: across 60 recent transcripts it
    /// promotes **579** records — `isMeta` context, compaction summaries,
    /// task notifications — against **209** genuine messages. Nearly three fake
    /// user bubbles for every real one, each of them words the user never said.
    private static func isHuman(_ record: [String: Any]) -> Bool {
        origin(record) == "human"
    }

    private static func origin(_ record: [String: Any]) -> String? {
        (record["origin"] as? [String: Any])?["kind"] as? String
    }

    /// Recovers what the user actually typed out of a delivered notification.
    ///
    /// The wrapper Claude Code builds looks like this, and we keep only the tail:
    ///
    /// ```
    /// <task-notification><summary>…</summary></task-notification>
    /// <system-reminder>
    /// The user sent this from the lampboard panel …  reply to it directly: HELLO
    /// </system-reminder>
    /// ```
    ///
    /// Returns `nil` — leaving the entry a note — whenever the preamble is absent,
    /// which is every notification that did not come from us. Matching loosely
    /// here would mean relabelling somebody else's background agent as a sentence
    /// the user wrote, and a chat window that invents the user's words is worse
    /// than one that shows too many system notes.
    static func userMessage(inDeliveredNotification text: String) -> String? {
        guard let range = text.range(of: Mailbox.rewakePreamble) else { return nil }
        let tail = text[range.upperBound...]
        // The envelope closes after the message; anything from the first closing
        // tag onwards belongs to Claude Code, not to the user.
        let body = tail.components(separatedBy: "</system-reminder>").first ?? String(tail)
        return body.trimmed.nilIfEmpty
    }

    private static func userEntries(
        _ record: [String: Any], uuid: String, timestamp: Date
    ) -> [TranscriptEntry] {
        // A compaction is a boundary in the conversation, and one the user should
        // see: everything above it is a summary, not what was actually said.
        if record["isCompactSummary"] as? Bool == true {
            return [TranscriptEntry(
                id: uuid, kind: .note, text: "context compacted", timestamp: timestamp
            )]
        }

        if origin(record) == "task-notification" {
            let text = plainText(in: record)

            // A message the user sent from the chat window comes back wearing the
            // same origin as a background agent reporting in — Claude Code has one
            // envelope for both. Left alone it would render as a system note, so
            // the user would watch their own sentences appear as machine chatter.
            //
            // The preamble we put on outbound messages is the signature that tells
            // them apart. It is ours, it is on every message we send, and it is on
            // nothing else.
            if let sent = userMessage(inDeliveredNotification: text) {
                return [TranscriptEntry(id: uuid, kind: .human, text: sent, timestamp: timestamp)]
            }

            let fallback = text.nilIfEmpty ?? "a background task reported in"
            return [TranscriptEntry(id: uuid, kind: .note, text: fallback, timestamp: timestamp)]
        }

        if origin(record) == "peer" {
            return peerEntries(from: record["origin"] as? [String: Any], text: plainText(in: record), uuid: uuid, timestamp: timestamp)
        }

        guard isHuman(record) else { return [] }

        let text = plainText(in: record)
        guard let text = text.nilIfEmpty else { return [] }
        return [TranscriptEntry(id: uuid, kind: .human, text: text, timestamp: timestamp)]
    }

    // MARK: - Messages through the box (D81)

    /// A message through Claude Code's box. The user's words only when it says
    /// it is from LampBoard *and* starts with its preamble. A session talking to
    /// another names itself, so its messages read as notes; a process of the
    /// user's own could claim both, which is the account boundary of D15, D81.
    private static func peerEntries(
        from origin: [String: Any]?, text: String, uuid: String, timestamp: Date
    ) -> [TranscriptEntry] {
        let sender = (origin?["from"] as? String).map { String($0.prefix(40)).trimmed } ?? ""
        if sender == PeerBox.sender, let typed = PeerBox.typed(fromDelivered: text) {
            return [TranscriptEntry(id: uuid, kind: .human, text: typed, timestamp: timestamp)]
        }
        let who = sender.isEmpty ? "" : " (\(sender))"
        return [TranscriptEntry(id: uuid, kind: .note, text: "a message from another session\(who)", timestamp: timestamp)]
    }

    /// A message taken into a running turn is kept as a `queued_command`
    /// attachment, not a user record (measured, 2.1.289). Only the box's are
    /// read: a prompt the user queued in the terminal has its own record.
    private static func queuedPeerEntries(
        _ record: [String: Any], uuid: String, timestamp: Date
    ) -> [TranscriptEntry] {
        guard let attachment = record["attachment"] as? [String: Any],
              attachment["type"] as? String == "queued_command",
              let origin = attachment["origin"] as? [String: Any], origin["kind"] as? String == "peer"
        else { return [] }
        return peerEntries(from: origin, text: (attachment["prompt"] as? String) ?? "", uuid: uuid, timestamp: timestamp)
    }

    // MARK: - Assistant records

    private static func assistantEntries(
        _ record: [String: Any], uuid: String, timestamp: Date
    ) -> [TranscriptEntry] {
        guard let blocks = contentBlocks(in: record) else {
            // Content as a bare string is legal and does happen.
            let text = plainText(in: record)
            guard let text = text.nilIfEmpty else { return [] }
            return [TranscriptEntry(id: uuid, kind: .assistant, text: text, timestamp: timestamp)]
        }

        var said = ""
        var tools: [String] = []

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                appendParagraph((block["text"] as? String) ?? "", to: &said)
            case "tool_use":
                if let name = (block["name"] as? String)?.trimmed.nilIfEmpty {
                    tools.append(name)
                }
            default:
                // `thinking` lands here on purpose: it is not what Claude said,
                // and a chat window that shows it is a debugger, not a chat.
                continue
            }
        }

        var result: [TranscriptEntry] = []
        if let text = said.nilIfEmpty {
            result.append(
                TranscriptEntry(id: uuid + ":text", kind: .assistant, text: text, timestamp: timestamp)
            )
        }
        if !tools.isEmpty {
            result.append(
                TranscriptEntry(
                    id: uuid + ":tools",
                    kind: .activity,
                    text: activityLabel(for: tools),
                    timestamp: timestamp
                )
            )
        }
        return result
    }

    /// `Read ×3 · Edit · Bash` — the tools in the order they were called, with
    /// repeats folded so a turn that read forty files does not produce forty words.
    static func activityLabel(for tools: [String]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for tool in tools {
            if counts[tool] == nil { order.append(tool) }
            counts[tool, default: 0] += 1
        }
        return order
            .map { counts[$0] == 1 ? $0 : "\($0) ×\(counts[$0]!)" }
            .joined(separator: " · ")
    }

    // MARK: - Content

    private static func contentBlocks(in record: [String: Any]) -> [[String: Any]]? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        return message["content"] as? [[String: Any]]
    }

    /// The readable text of a record, whatever shape its content takes.
    ///
    /// Non-text blocks become a placeholder rather than vanishing: a message that
    /// was only a screenshot has to leave a trace, or the conversation shows a
    /// gap where a person remembers sending something.
    private static func plainText(in record: [String: Any]) -> String {
        guard let message = record["message"] as? [String: Any] else { return "" }

        if let direct = message["content"] as? String { return direct.trimmed }

        guard let blocks = message["content"] as? [[String: Any]] else { return "" }

        var text = ""
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                appendParagraph((block["text"] as? String) ?? "", to: &text)
            case "image":
                appendParagraph("[image]", to: &text)
            case "document":
                appendParagraph("[document]", to: &text)
            default:
                continue
            }
        }
        return text
    }

    private static func appendParagraph(_ piece: String, to text: inout String) {
        let trimmed = piece.trimmed
        guard !trimmed.isEmpty else { return }
        if !text.isEmpty { text += "\n\n" }
        text += trimmed
    }

    // MARK: - Time

    /// Transcript timestamps are ISO 8601 with fractional seconds. The formatter
    /// without them is tried too: the field has carried both shapes.
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFraction = ISO8601DateFormatter()

    static func date(from raw: String?) -> Date {
        guard let raw, !raw.isEmpty else { return .distantPast }
        return withFraction.date(from: raw) ?? withoutFraction.date(from: raw) ?? .distantPast
    }
}
