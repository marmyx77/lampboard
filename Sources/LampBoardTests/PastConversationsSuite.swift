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
    ])
}
