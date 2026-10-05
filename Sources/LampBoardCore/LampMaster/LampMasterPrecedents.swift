import Foundation

/// The fifth job (D3): a failure of the last hour that another conversation
/// met before. Found by searching first — the search index (D88), a failure's
/// own words, no token — and handed to the round as candidates with what was
/// said around them; the round judges, the search does not.
public enum LampMasterPrecedents {

    /// One conversation the index found.
    public struct Hit: Sendable, Equatable {
        public let sessionId: String
        public let project: String?
        public let lastAt: Date?
        public let snippet: String

        public init(sessionId: String, project: String?, lastAt: Date?, snippet: String) {
            self.sessionId = sessionId
            self.project = project
            self.lastAt = lastAt
            self.snippet = snippet
        }
    }

    static let perFailure = 3
    static let failuresSearched = 4
    static let snippetLength = 300
    /// The same project counts as elsewhere from the day before on.
    static let sameProjectAfter: TimeInterval = 24 * 60 * 60

    /// The precedents of every session's failures of the last hour, each
    /// failure searched once, four at most.
    public static func frame(
        for sessions: [LampMasterSession], now: Date, search: (String) -> [Hit]
    ) -> [LampMasterFrame.Precedent] {
        let hourAgo = now.addingTimeInterval(-3_600)
        // Each failure searched once, the most recent first; the same failure in
        // two sessions picked for each, since each has its own project.
        var results: [String: [Hit]] = [:], precedents: [LampMasterFrame.Precedent] = []
        for session in sessions {
            var mine = Set<String>()
            for failure in session.card.failures(since: hourAgo).reversed() {
                guard failure.terms.count >= 2, mine.insert(failure.fingerprint).inserted else { continue }
                if results[failure.fingerprint] == nil {
                    guard results.count < failuresSearched else { continue }
                    results[failure.fingerprint] = search(failure.terms.joined(separator: " "))
                }
                let found = pick(results[failure.fingerprint] ?? [], for: session, now: now)
                guard !found.isEmpty else { continue }
                precedents.append(.init(session: session.shortId, error: failure.fingerprint, found: found))
            }
        }
        return precedents
    }

    /// Another project, or the same one on another day; never the session's
    /// own conversation. Three at most, each said in one clean line.
    public static func pick(_ hits: [Hit], for session: LampMasterSession, now: Date) -> [LampMasterFrame.Precedent.Found] {
        let project = session.card.cwd.map { ($0 as NSString).lastPathComponent }
        return hits
            .filter { hit in
                hit.sessionId != session.card.sessionId
                    && (hit.project != project || now.timeIntervalSince(hit.lastAt ?? now) >= sameProjectAfter)
            }
            .prefix(perFailure)
            .map { hit in
                .init(id: String(hit.sessionId.prefix(8)), project: hit.project.map { LampMasterLookup.clean($0, to: 40) },
                      date: hit.lastAt.map(day), snippet: LampMasterLookup.clean(hit.snippet, to: snippetLength))
            }
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
