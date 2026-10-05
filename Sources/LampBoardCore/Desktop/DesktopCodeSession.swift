import Foundation

/// A session in the Claude app's Code tab, as the application files it (0.6).
///
/// The tab keeps one index per conversation under
/// `claude-code-sessions/<organisation>/<account>/local_<id>.json`, and that
/// index names two ids: its own (`sessionId`, `local_…`) and the transcript's
/// (`cliSessionId`), which is the session id every hook carries. The second is
/// how a row finds the first; the first is what the application opens.
///
/// The link is the application's own, read from its code (2.19675) and tried on
/// the test Mac: with the app on one conversation,
/// `claude://code/continue?session=local_<id>` brought up the other. Before it a
/// click could only raise the application, whatever conversation it was on.
public enum DesktopCodeSession {

    /// The application refuses any other shape (`^local_[A-Za-z0-9-]{1,64}$`), so
    /// an index that names one is not read further.
    static let localIdPattern = #"^local_[A-Za-z0-9-]{1,64}$"#

    public static func root(inHome home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
    }

    /// One conversation's entry in the application's index.
    public struct Entry: Equatable, Sendable {
        public let localSessionId: String
        public let isArchived: Bool

        public init(localSessionId: String, isArchived: Bool) {
            self.localSessionId = localSessionId
            self.isArchived = isArchived
        }
    }

    /// The application's entry for the conversation whose transcript is `cli`,
    /// when `data` is that conversation's index.
    public static func entry(in data: Data, forCLISession cli: String) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["cliSessionId"] as? String) == cli,
              let local = object["sessionId"] as? String,
              local.range(of: localIdPattern, options: .regularExpression) != nil
        else { return nil }
        return Entry(localSessionId: local, isArchived: object["isArchived"] as? Bool ?? false)
    }

    /// Between two indexes naming the same transcript: the open one, then the
    /// one written last.
    public static func prefers(_ entry: Entry, at date: Date, over other: Entry, at otherDate: Date) -> Bool {
        if entry.isArchived != other.isArchived { return !entry.isArchived }
        return date > otherDate
    }

    public static func localSessionId(in data: Data, forCLISession cli: String) -> String? {
        entry(in: data, forCLISession: cli)?.localSessionId
    }

    /// The link that opens that conversation in the application.
    public static func continueURL(localSessionId: String) -> URL? {
        guard localSessionId.range(of: localIdPattern, options: .regularExpression) != nil else { return nil }
        return URL(string: "claude://code/continue?session=\(localSessionId)")
    }
}
