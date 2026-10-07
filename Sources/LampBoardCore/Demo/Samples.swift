import Foundation

/// Three sample rows in the real panel, for whoever has no session at hand (U4).
///
/// In 1.0 the way to see the panel at work was a second copy of the app, opened
/// in the same corner as the real one and nearly identical to it: each «Take the
/// tour…» stacked another, and after Skip there was no visible way out. The
/// samples live in the panel the person will use, at the top of its column, marked
/// as samples and gone with one click. They are added to what the column draws and
/// never to the store: no notification, no count, no LampMaster round ever sees
/// them.
public enum Samples {

    /// A folder no project has: every sample's path starts here.
    public static let folder = "/LampBoard samples/"
    private static let prefix = "lampboard-sample-"

    public static func id(_ name: String) -> String { prefix + name }
    public static func isSample(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// How the samples stand `now`, the colours playing out from `since`: api
    /// works for eight seconds, then has an answer, then asks — the three colours
    /// worth knowing first. docs-site has an answer to read; events works. A
    /// sample in `seen` was clicked: it rests, the way a read answer does.
    public static func sessions(since: Date, now: Date, seen: Set<String>) -> [SessionState] {
        let elapsed = now.timeIntervalSince(since)
        let api: SessionStatus = elapsed < 8 ? .working : elapsed < 16 ? .ready : .awaiting
        let apiSince = since.addingTimeInterval(elapsed < 8 ? 0 : elapsed < 16 ? 8 : 16)
        let rows: [(String, SessionStatus, Date, String?, PendingAsk?)] = [
            ("api", api, apiSince, api == .ready ? "Wrote src/publish.ts. Ready to publish?" : nil,
             api == .awaiting ? PendingAsk(tool: "Bash", detail: "npm publish") : nil),
            ("docs-site", .ready, since, "The docs build is ready: 42 pages, no broken links.", nil),
            ("events", .working, since, nil, nil),
        ]
        return rows.map { name, status, statusSince, message, ask in
            let id = id(name)
            let resting = seen.contains(id) && status.clearsOnFocus
            return SessionState(
                id: id, status: resting ? .idle : status, workspace: Workspace(path: folder + name),
                lastMessage: message, updatedAt: max(statusSince, since), statusSince: statusSince,
                pendingAsk: resting ? nil : ask, title: "Sample: \(name)"
            )
        }
    }
}

extension TrafficLightState {
    /// The state with `extra` sessions added, for drawing only (the samples).
    public func adding(_ extra: [SessionState]) -> TrafficLightState {
        guard !extra.isEmpty else { return self }
        var merged = sessions
        for session in extra { merged[session.id] = session }
        return TrafficLightState(sessions: merged, dismissed: dismissed)
    }
}
