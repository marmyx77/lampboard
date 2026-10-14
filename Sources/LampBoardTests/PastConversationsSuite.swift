import Foundation
import LampBoardCore
import TestKit

/// What a project offers to take up again (hub-terminale R5).
enum PastConversationsSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let a = "4b138f7d-67ab-4d4c-9396-77adaed0f851"
    static let b = "5c249a8e-78bc-4e5d-8a07-88bbeae1a962"
    static let c = "6d35ab9f-89cd-4f6e-9b18-99ccfbf2ba73"

    static let suite = TestSuite("Past conversations to take up", [

        TestCase("The latest first; the ones a process holds first of all, marked to open, never a name that is not an id") { t in
            let items = [PastConversations.Item(id: a, modified: t0, title: "Old"),
                         PastConversations.Item(id: b, modified: t0.addingTimeInterval(60), title: "Newer"),
                         PastConversations.Item(id: c, modified: t0.addingTimeInterval(120), title: "Live"),
                         PastConversations.Item(id: "agent-1234", modified: t0.addingTimeInterval(180), title: "A subagent")]
            let picked = PastConversations.pick(items, live: [c])
            t.expectEqual(picked.map(\.id), [c, b, a], "the live one first: shown, so it is not taken for missing")
            t.expectEqual(picked.map(\.isLive), [true, false, false], "and marked: opened where it runs, never taken up (a second writer)")
            t.expectEqual(PastConversations.pick(items, live: [], limit: 1).map(\.id), [c])
            t.expectEqual(PastConversations.pick(items, live: [a], limit: 1).map(\.id), [a, c], "the limit is for the rest")
        },

        TestCase("On another machine, only the transcripts of that folder") { t in
            let files = [RemoteTranscripts.File(path: "./-home-dev-web/\(a).jsonl", size: 10, modified: t0),
                         RemoteTranscripts.File(path: "./-home-dev-web-old/\(b).jsonl", size: 10, modified: t0),
                         RemoteTranscripts.File(path: "./-home-dev-api/\(c).jsonl", size: 10, modified: t0)]
            t.expectEqual(PastConversations.remote(files, folder: "/home/dev/web").map(\.id), [a])
        },

        TestCase("The resume list is as tall as its rows up to eight, then scrolls in the height of eight") { t in
            let row = ResumeList.rowHeight, edge = 2 * ResumeList.inset
            t.expectEqual(ResumeList.height(rows: 0), edge)
            t.expectEqual(ResumeList.height(rows: 1), row + edge, "one row is shown whole, not half of it")
            t.expectEqual(ResumeList.height(rows: 5), 5 * row + edge, "five rows, five rows tall: none behind a scroller")
            t.expectEqual(ResumeList.height(rows: 8), 8 * row + edge)
            t.expectEqual(ResumeList.height(rows: 30), 8 * row + edge, "past eight it stops growing and scrolls")
            t.expect(!ResumeList.scrolls(rows: 8), "eight fit")
            t.expect(ResumeList.scrolls(rows: 9), "the ninth scrolls")
            t.expect(ResumeList.height(rows: 2) > ResumeList.height(rows: 1), "the sheet grows with the list")
        },

        TestCase("A resume row says its title, its project and how old it is; untitled ones read apart") { t in
            let items = [PastConversations.Item(id: c, modified: t0, title: nil, isLive: true),
                         PastConversations.Item(id: b, modified: t0.addingTimeInterval(-3 * 3600), title: "Ship the\nrelease"),
                         PastConversations.Item(id: a, modified: t0.addingTimeInterval(-2 * 86400), title: nil)]
            let rows = ResumeList.rows(items, project: "web", host: "bestia", name: { $0 == c ? "Hermes" : nil }, now: t0)
            t.expectEqual(rows.map(\.id), [c, b, a], "the order pick gave: the running one, then the latest first")
            t.expectEqual(rows.map(\.title), ["Hermes", "Ship the release", "4b138f7d"], "one line; the row's name; else the id's start")
            t.expectEqual(rows[1].detail, "web on bestia · 5c249a8e")
            t.expectEqual(rows[2].detail, "web on bestia", "the id is not said twice")
            t.expectEqual(rows.map(\.age), ["Running now", "3.0h", "2d"])
            t.expectEqual(ResumeList.rows(items, project: "web", host: nil, name: { _ in nil }, now: t0).map(\.detail), ["web", "web · 5c249a8e", "web"], "this Mac is not named")
        },

        TestCase("Up and down move the selection inside the list; it starts on the first row") { t in
            t.expectEqual(ResumeList.firstSelection(count: 3), 0)
            t.expectNil(ResumeList.firstSelection(count: 0))
            t.expectEqual(ResumeList.move(0, by: 1, count: 3), 1)
            t.expectEqual(ResumeList.move(2, by: 1, count: 3), 2, "the last row stays selected")
            t.expectEqual(ResumeList.move(0, by: -1, count: 3), 0, "the first row stays selected")
            t.expectEqual(ResumeList.move(nil, by: 1, count: 3), 0)
            t.expectEqual(ResumeList.move(nil, by: -1, count: 3), 2)
            t.expectEqual(ResumeList.move(7, by: -1, count: 3), 1, "a selection past a shorter list comes back inside it")
            t.expectNil(ResumeList.move(0, by: 1, count: 0))
        },
    ])
}
