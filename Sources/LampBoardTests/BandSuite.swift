import LampBoardCore
import Foundation
import TestKit

/// The band above the prompt (D84): what it shows, and to whom.
enum BandSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func row(_ id: String, _ status: SessionStatus, since: Double = 0, ask: PendingAsk? = nil) -> SessionState {
        SessionState(id: id, status: status, workspace: Workspace(path: "/home/dev/\(id)"),
                     updatedAt: t0.addingTimeInterval(since), statusSince: t0.addingTimeInterval(since), pendingAsk: ask)
    }

    private static let cards = WaitingQueue.cards(sessions: [
        row("docs", .awaiting, ask: PendingAsk(tool: "Bash", detail: "npm publish")),
        row("legal", .failed, since: 1), row("api", .ready, since: 2), row("mobile", .failed, since: 3),
        row("events", .awaiting, since: 4),
    ], suggestions: [], now: t0.addingTimeInterval(10))

    static let suite = TestSuite("The band above the prompt", [

        TestCase("What stops work, the most urgent first, three at most; answers to read wait for the panel") { t in
            let items = Band.items(cards: cards, excluding: nil)
            t.expectEqual(items.map(\.session), ["docs", "events", "legal"])
            t.expectEqual(items.first?.kind, "permission")
            t.expect(!items.contains { $0.session == "api" }, "a ready answer is not in the band")
        },

        TestCase("Never the session's own: its own dialog is in front of it") { t in
            t.expectEqual(Band.items(cards: cards, excluding: "docs").map(\.session), ["events", "legal", "mobile"])
        },

        TestCase("A title and a line, each one clean line, cut with an ellipsis") { t in
            let long = WaitingQueue.cards(sessions: [
                row(String(repeating: "x", count: 50), .awaiting, ask: PendingAsk(tool: "Bash", detail: String(repeating: "y", count: 100))),
            ], suggestions: [], now: t0)
            let item = Band.items(cards: long, excluding: nil).first
            t.expectEqual(item?.title.count, 32)
            t.expect(item?.title.hasSuffix("…") == true, "cut where it says so")
            t.expect((item?.line.count ?? 0) <= 60, "the line too")
        },

        TestCase("A secret in a command is masked, a bidi override is gone, and a node is told only the kind") { t in
            let risky = WaitingQueue.cards(sessions: [
                row("docs", .awaiting, ask: PendingAsk(tool: "Bash", detail: "API_KEY=sk-live-123 npm publish \u{202E}txt.exe")),
            ], suggestions: [], now: t0)
            let line = Band.items(cards: risky, excluding: nil).first?.line ?? ""
            t.expect(!line.contains("sk-live-123"), "masked: \(line)")
            t.expect(!line.unicodeScalars.contains { $0.value == 0x202E }, "no override")
            t.expectEqual(Band.items(cards: risky, excluding: nil, lines: false).first?.line, "a permission")
        },

        TestCase("The wire is versioned and lists the items in order") { t in
            let wire = (try? JSONSerialization.jsonObject(with: Band.json(Band.items(cards: cards, excluding: nil)))) as? [String: Any]
            t.expectEqual(wire?["v"] as? Int, 1)
            t.expectEqual(((wire?["items"] as? [[String: Any]]) ?? []).compactMap { $0["session"] as? String }, ["docs", "events", "legal"])
            t.expectEqual(String(decoding: Band.json([]), as: UTF8.self), #"{"items":[],"v":1}"#)
        },
    ])
}
