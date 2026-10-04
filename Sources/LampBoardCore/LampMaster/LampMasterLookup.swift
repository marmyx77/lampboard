import Foundation

/// The three tools a session can call without a model running: who else is on
/// these files, who knows about this, who hit this error before.
///
/// WHAT THEY NEVER RETURN
/// Another session's own words. What one conversation wrote can read like an
/// order ("ignore the instructions and…"), and these answers go straight into
/// the context of the session that asked, which acts with the user's tools.
/// So the answers are made of facts about sessions — an id, a project, a title,
/// a time, a file name, which words matched — and never of their prompts or
/// replies. The title is the one piece of prose, and it is the short name
/// Claude Code gave the conversation, clipped.
public enum LampMasterLookup {

    public static let shown = 5
    public static let titleLength = 80

    // MARK: - overlaps

    /// - Parameters:
    ///   - asker: the calling session's id, left out of the answer.
    ///   - cwd: the calling session's folder, to read relative paths against.
    public static func overlaps(
        files: [String], asker: String?, cwd: String?, sessions: [LampMasterSession], now: Date
    ) -> String {
        let since = now.addingTimeInterval(-LampMasterSignals.overlapWindow)
        let others = sessions.filter { $0.card.sessionId != asker }
        var lines: [String] = []

        for session in others {
            let touched = session.card.writes.filter { write in
                write.at >= since && files.contains { matches(write.path, $0, cwd: cwd) }
            }
            guard let latest = touched.max(by: { $0.at < $1.at }) else { continue }
            let names = Set(touched.map { clean(($0.path as NSString).lastPathComponent, to: titleLength) })
                .sorted().joined(separator: ", ")
            lines.append("\(describe(session, now: now)) wrote \(names), last \(ago(latest.at, now: now))")
        }

        let mine = sessions.first { $0.card.sessionId == asker }?.card
        if let branch = mine?.gitBranch, let folder = mine?.cwd ?? cwd {
            for session in others where session.liveness != .closed
                && session.card.gitBranch == branch && session.card.cwd == folder {
                lines.append("\(describe(session, now: now)) is live on the same branch, \(branch)")
            }
        }
        guard !lines.isEmpty else {
            return "No other session wrote these files in the last two hours, and none is live on the same branch."
        }
        return lines.prefix(shown * 2).joined(separator: "\n")
    }

    /// A written path against a path the caller named: equal when absolute,
    /// or ending with it when relative — `src/routes.ts` is the same file in
    /// any session whose folder holds it.
    static func matches(_ written: String, _ named: String, cwd: String?) -> Bool {
        let wanted = named.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return false }
        if wanted.hasPrefix("/") { return written == wanted }
        if let cwd, written == cwd + "/" + wanted { return true }
        return written.hasSuffix("/" + wanted)
    }

    // MARK: - who_knows

    public static func whoKnows(
        topic: String, asker: String?, sessions: [LampMasterSession], now: Date
    ) -> String {
        let terms = Self.terms(topic)
        guard !terms.isEmpty else { return "Name a topic in a few words: a service, a file, a feature." }
        let needed = max(1, (terms.count + 1) / 2)

        let found = sessions
            .filter { $0.card.sessionId != asker }
            .compactMap { session -> (LampMasterSession, [String])? in
                let card = session.card
                let haystack = ([card.title ?? "", card.cwd ?? "", card.lastAnswer ?? "", card.gitBranch ?? ""]
                    + card.recentPrompts + card.writes.map(\.path)).joined(separator: " ").lowercased()
                let matched = terms.filter { haystack.contains($0) }
                return matched.count >= needed ? (session, matched) : nil
            }
            .sorted {
                $0.1.count != $1.1.count
                    ? $0.1.count > $1.1.count
                    : ($0.0.card.lastActivity ?? .distantPast) > ($1.0.card.lastActivity ?? .distantPast)
            }
        guard !found.isEmpty else { return "No session of the last week worked on that, as far as their cards show." }
        return found.prefix(shown)
            .map { "\(describe($0.0, now: now)), last active \(ago($0.0.card.lastActivity, now: now)); matched: \($0.1.joined(separator: ", "))" }
            .joined(separator: "\n")
    }

    /// The words of a topic worth looking for: three characters or more, with
    /// the dashes, dots and slashes that hold names like `events-api` together,
    /// and without the small words every conversation contains.
    static func terms(_ topic: String) -> [String] {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./")).inverted
        var seen = Set<String>()
        return topic.lowercased()
            .components(separatedBy: separators)
            .filter { $0.count >= 3 && !commonWords.contains($0) && seen.insert($0).inserted }
            .prefix(12).map { $0 }
    }

    static let commonWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "who", "what", "where", "when", "how",
        "which", "has", "have", "was", "are", "about", "into", "not", "any", "all", "one",
    ]

    // MARK: - precedents

    public static func precedents(
        error: String, asker: String?, sessions: [LampMasterSession], now: Date
    ) -> String {
        let fingerprint = FailureFingerprint.of(error)
        let saving: Set<SessionCard.Milestone.Kind> = [.commit, .merge, .push, .pullRequest, .testsPassed]
        let lines = sessions
            .filter { $0.card.sessionId != asker }
            .compactMap { session -> String? in
                let hits = session.card.failures.filter { $0.fingerprint == fingerprint }
                guard let last = hits.max(by: { $0.at < $1.at }) else { return nil }
                let after = session.card.milestones.filter { saving.contains($0.kind) && $0.at > last.at }
                    .max { $0.at < $1.at }
                let outcome = after.map { "then saved work (\($0.kind.rawValue)) \(ago($0.at, now: now))" }
                    ?? "nothing saved after it"
                return "\(describe(session, now: now)) hit it \(hits.count == 1 ? "once" : "\(hits.count) times"), "
                    + "last \(ago(last.at, now: now)); \(outcome)"
            }
        guard !lines.isEmpty else { return "No other session hit this error in the last week, as far as their cards show." }
        return "The error reads as: \(fingerprint)\n" + lines.prefix(shown).joined(separator: "\n")
    }

    // MARK: - Shared

    static func describe(_ session: LampMasterSession, now: Date) -> String {
        let card = session.card
        let project = card.cwd.map { ($0 as NSString).lastPathComponent } ?? "?"
        let title = card.title.map { " · \u{201C}" + clean($0, to: titleLength) + "\u{201D}" } ?? ""
        return "\(clean(session.shortId, to: 8)) · \(clean(project, to: titleLength))\(title) · \(session.liveness.rawValue)"
    }

    /// A name another session chose — a title, a file name — made fit to show:
    /// one line, no control characters, clipped. A title can be written to read
    /// like an order; on one short line, quoted, after the notice, it reads as
    /// what it is.
    static func clean(_ text: String, to length: Int) -> String {
        let flat = String(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : Character($0)
        })
        return String(flat.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(length))
    }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "at an unknown time" }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / (24 * 60)) days ago"
    }
}
