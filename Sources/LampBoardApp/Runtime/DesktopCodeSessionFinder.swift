import LampBoardCore
import Foundation

/// Finds, at the moment of a click, the Claude app's id for a Code tab
/// conversation (D107): the index under `claude-code-sessions` whose transcript
/// is the row's session. Read on a click and never on a timer.
///
/// The click runs on the main actor, so a file is parsed only once its bytes
/// contain the session's id: a miss — a local agent conversation, another
/// account — costs a read of each index and no parsing. When several indexes
/// name the same transcript (a conversation copied, or archived and opened
/// again), the one still open wins, then the one written last.
enum DesktopCodeSessionFinder {
    /// An index is a couple of kilobytes; past this it is not one.
    static let maxBytes = 1 << 20

    static func localSessionId(for cliSessionId: String, home: URL = AppConfig.homeDirectory) -> String? {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let children = { (url: URL) in
            (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
                                                  options: [.skipsHiddenFiles])) ?? []
        }
        let needle = Data(cliSessionId.utf8)
        var best: (entry: DesktopCodeSession.Entry, at: Date)?
        // Resolved first: a listing does not follow a link, and the folder may be
        // one (a test home links it; so may a person who moved the app's data).
        for organisation in children(DesktopCodeSession.root(inHome: home).resolvingSymlinksInPath()) {
            for account in children(organisation) {
                for file in children(account) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    guard let values = try? file.resourceValues(forKeys: keys),
                          let size = values.fileSize, size <= maxBytes,
                          let data = try? Data(contentsOf: file), data.range(of: needle) != nil,
                          let entry = DesktopCodeSession.entry(in: data, forCLISession: cliSessionId)
                    else { continue }
                    let at = values.contentModificationDate ?? .distantPast
                    if let current = best,
                       !DesktopCodeSession.prefers(entry, at: at, over: current.entry, at: current.at) { continue }
                    best = (entry, at)
                }
            }
        }
        return best?.entry.localSessionId
    }
}
