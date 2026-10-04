import Foundation

/// The row's second line in the wide panel: what the session is doing now, in
/// the fewest words that say it (UX §4).
///
/// The card already says all of it at length; this is the one phrase worth
/// reading without moving the pointer — what it asks, what it is running, why
/// it died, what answer waits — so the column reads as a list of situations
/// rather than a list of names.
public enum RowActivity {

    /// Past this the line is cut, with an ellipsis: the row has room for about
    /// forty characters, and the rest is the card's to say.
    public static let maxLength = 80

    public static func line(for row: ColumnRow, now: Date) -> String {
        let session = row.primary
        let place = session.workspace.host.map { "@" + $0 }
        let doing: String?
        switch row.status {
        case .awaiting:
            doing = session.pendingAsk?.sentence ?? SessionStatus.awaiting.label
        case .failed:
            doing = session.failureReason?.detailedLabel ?? "the turn failed"
        case .working:
            if let stuck = session.stuckTool(at: now) {
                let minutes = CompactDuration.label(seconds: now.timeIntervalSince(stuck.since))
                doing = "stuck \(minutes) on " + (stuck.detail ?? stuck.tool)
            } else if let tool = session.runningTool {
                doing = tool.detail.map { "\(tool.tool) \($0)" } ?? tool.tool
            } else {
                doing = "working"
            }
        case .ready:
            // The first line with something on it: an answer that opens with a
            // blank line would otherwise leave the row's second line empty.
            doing = session.lastMessage.flatMap { message in
                message.prefix(2_000).split(whereSeparator: \.isNewline)
                    .map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            } ?? "an answer to read"
        case .waiting:
            let holding = RowSummary.counted(session.waitingOn)
            doing = holding.isEmpty ? SessionStatus.waiting.label : "waiting on " + holding
        case .idle:
            doing = nil
        }
        var parts: [String]
        if let doing {
            parts = [place, doing].compactMap { $0 }
        } else {
            parts = [session.harness.displayName, place].compactMap { $0 }
        }
        // A project of several says the most urgent one's line, and how many
        // more there are behind it.
        if row.count > 1 { parts.append("+\(row.count - 1)") }
        return clean(parts.joined(separator: " · "))
    }

    /// One line, control and format characters turned to spaces.
    public static func flat(_ text: String) -> String {
        String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func clean(_ text: String) -> String {
        // Control and format characters become spaces, not nothing: a tab
        // between two words must not glue them, and a bidi override must not
        // reorder the line.
        let flat = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > maxLength ? String(flat.prefix(maxLength - 1)) + "…" : flat
    }
}
