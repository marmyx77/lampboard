import Foundation

/// The conversations of a project that can be taken up again (hub-terminale R5):
/// its transcripts, the latest first, without the ones a process holds now —
/// taking one of those up would make a second writer.
public enum PastConversations {

    public struct Item: Equatable, Sendable, Identifiable {
        public let id: String
        public let modified: Date
        public let title: String?

        public init(id: String, modified: Date, title: String?) {
            self.id = id
            self.modified = modified
            self.title = title
        }
    }

    /// The latest `limit` of `items`, none of them `live`, none that is not a
    /// conversation's id.
    public static func pick(_ items: [Item], live: Set<String>, limit: Int = 15) -> [Item] {
        items.filter { ModReport.isSessionId($0.id) && $0.id.count == 36 && !live.contains($0.id) }
            .sorted { $0.modified > $1.modified }
            .prefix(limit).map { $0 }
    }

    /// The transcripts of `folder` in another machine's listing (`RemoteTranscripts`).
    public static func remote(_ files: [RemoteTranscripts.File], folder: String) -> [Item] {
        let prefix = "./" + TranscriptLocator.directoryName(forWorkspace: folder) + "/"
        return files.filter { $0.path.hasPrefix(prefix) }
            .map { Item(id: $0.sessionId, modified: $0.modified, title: nil) }
    }
}
