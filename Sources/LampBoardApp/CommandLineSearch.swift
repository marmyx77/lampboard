import Foundation
import LampBoardCore

/// `lampboard search <words>` (0.7): the conversations that say them, from the
/// index the panel keeps — brought up to date first, so it answers whether the
/// panel is running or not. `lampboard week` is `search --week`: the week in
/// a paragraph, from the same index.
extension CommandLineInterface {

    static func runSearch(_ words: String) -> Int32 {
        if words == "--reset" {
            let gone = SearchIndex().reset()
            print(gone ? "The search index is gone; the panel builds it again." : "The search index could not be removed.")
            return gone ? 0 : 1
        }
        guard words == "--week" || IndexQuery.fts(words) != nil else {
            print("Usage: lampboard search <words>")
            return 2
        }
        let index = SearchIndex()
        guard index.open() else {
            print("The search index could not be opened at ~/.lampboard/index.sqlite: \(index.problem ?? "unknown").")
            return 1
        }
        // The whole backlog in one go here: a person asked and is waiting.
        index.update(files: 100_000, bytes: Int.max)
        if words == "--week" {
            print(index.week())
            return 0
        }
        let hits = index.search(words, limit: 10)
        guard !hits.isEmpty else {
            print("No conversation says that.")
            return 0
        }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        for hit in hits {
            let when = hit.lastAt.map { day.string(from: $0) } ?? "        "
            // A transcript's words reach the terminal clean: no escape sequence in a title.
            let name = RowActivity.flat(hit.title ?? hit.cwd.map { ($0 as NSString).lastPathComponent } ?? String(hit.sessionId.prefix(8)))
            print("\(when)  \(name)  \(hit.sessionId)")
            print("    \(hit.snippet)")
        }
        return 0
    }
}
