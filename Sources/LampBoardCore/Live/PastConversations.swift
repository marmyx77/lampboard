import Foundation

/// The conversations of a project (hub-terminale R5): its transcripts, the
/// latest first. The ones a process holds now come first and are marked: they
/// are opened where they run, never taken up again, which would make a second
/// writer. Hidden, they read as LampBoard not finding them (13 October 2026:
/// Hermes, running in tmux on the Bestia, was simply missing from the list).
public enum PastConversations {

    public struct Item: Equatable, Sendable, Identifiable {
        public let id: String
        public let modified: Date
        public let title: String?
        /// A process holds it now: open it, do not take it up.
        public let isLive: Bool

        public init(id: String, modified: Date, title: String?, isLive: Bool = false) {
            self.id = id
            self.modified = modified
            self.title = title
            self.isLive = isLive
        }
    }

    /// The ones `live` holds first, marked, then the latest `limit` of the
    /// rest; none that is not a conversation's id.
    public static func pick(_ items: [Item], live: Set<String>, limit: Int = 15) -> [Item] {
        let ids = items.filter { ModReport.isSessionId($0.id) && $0.id.count == 36 }
            .sorted { $0.modified > $1.modified }
        let running = ids.filter { live.contains($0.id) }
            .map { Item(id: $0.id, modified: $0.modified, title: $0.title, isLive: true) }
        let rest = ids.filter { !live.contains($0.id) }.prefix(limit)
        return running + rest
    }

    /// The transcripts of `folder` in another machine's listing (`RemoteTranscripts`).
    public static func remote(_ files: [RemoteTranscripts.File], folder: String) -> [Item] {
        let prefix = "./" + TranscriptLocator.directoryName(forWorkspace: folder) + "/"
        return files.filter { $0.path.hasPrefix(prefix) }
            .map { Item(id: $0.sessionId, modified: $0.modified, title: nil) }
    }
}
