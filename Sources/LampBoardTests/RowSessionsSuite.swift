import LampBoardCore
import Foundation
import TestKit

/// The sessions inside one row, told apart from one another.
///
/// A project can hold several conversations at once, and until now the column
/// could only say how many. Measured on a real machine: three Claude sessions in
/// one folder, identical in every field the panel draws, differing only by a
/// UUID nobody sees. These cases are about the two things that make them
/// separable, a stable order and a name each.
enum RowSessionsSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private static func session(
        _ id: String,
        _ status: SessionStatus,
        born: TimeInterval,
        title: String? = nil,
        path: String = "/dev/project"
    ) -> SessionState {
        SessionState(
            id: id,
            status: status,
            workspace: Workspace(path: path),
            updatedAt: t0.addingTimeInterval(born + 100),
            statusSince: t0.addingTimeInterval(born + 100),
            origin: .editor,
            title: title,
            firstSeenAt: t0.addingTimeInterval(born)
        )
    }

    private static func row(_ sessions: [SessionState]) -> ColumnRow {
        ColumnRow(id: "/dev/project", workspace: Workspace(path: "/dev/project"), sessions: sessions)
    }

    static let suite = TestSuite("Row sessions", [

        TestCase("The sessions of a row are listed in the order they were opened") { t in
            // Not by urgency, which is what `sessions` itself is sorted by. The
            // column does not reorder itself (D23) and neither may the list inside
            // a row: a sub-row that jumps because a turn finished is the same
            // defect one level down, and it is worse there, because the rows are
            // closer together and a misclick opens the wrong conversation.
            let members = row([
                session("second", .ready, born: 200),
                session("first", .working, born: 100),
            ]).members

            t.expectEqual(members.map(\.id), ["first", "second"], "birth order")
            t.expectEqual(members.map(\.ordinal), [1, 2], "numbered along that order")
        },

        TestCase("The order holds still when a session changes state") { t in
            // The whole point of ordering by birth: this is the case that made the
            // grouped row unusable, two sessions swapping places every time one of
            // them started or finished a turn.
            let first = session("first", .working, born: 100)
            let second = session("second", .idle, born: 200)

            let before = row([first, second]).members.map(\.id)
            let after = row([second.with(status: .awaiting, at: t0), first]).members.map(\.id)

            t.expectEqual(before, after, "the same two, in the same places")
        },

        TestCase("An order somebody chose beats the order they were opened in") { t in
            let members = ColumnRow(
                id: "/dev/project", workspace: Workspace(path: "/dev/project"),
                sessions: [session("first", .working, born: 100), session("second", .ready, born: 200)],
                order: ["second", "first"]
            ).members
            t.expectEqual(members.map(\.id), ["second", "first"], "as it was arranged")
            t.expectEqual(members.map(\.ordinal), [1, 2], "and numbered along that")
        },

        TestCase("A conversation nobody placed arrives at the end") { t in
            // Not in the middle of a list somebody arranged, which is where it
            // would land if the two orders were merged by birth. A new line has to
            // appear somewhere you can find it.
            let members = ColumnRow(
                id: "/dev/project", workspace: Workspace(path: "/dev/project"),
                sessions: [
                    session("fresh", .working, born: 50),
                    session("first", .working, born: 100),
                    session("second", .ready, born: 200),
                ],
                order: ["second", "first"]
            ).members
            t.expectEqual(members.map(\.id), ["second", "first", "fresh"],
                          "the arranged ones, then the newcomer")
        },

        TestCase("An order naming sessions that have ended is not a hole") { t in
            // The order is kept by session id and a session id dies with its
            // process, so an order outlives the things it names. What is left has
            // to keep its places rather than fall back to nothing.
            let members = ColumnRow(
                id: "/dev/project", workspace: Workspace(path: "/dev/project"),
                sessions: [session("second", .ready, born: 200)],
                order: ["gone", "second", "also-gone"]
            ).members
            t.expectEqual(members.map(\.id), ["second"], "what is still here, where it was put")
        },

        TestCase("A session with a title is called by it") { t in
            let members = row([session("a", .working, born: 100, title: "Refactor the parser")]).members
            t.expectEqual(members.first?.name, "Refactor the parser", "its own name")
        },

        TestCase("A session with no title yet is called by its position") { t in
            // A title appears after the first exchange, not before, so for the
            // first seconds of a conversation there is nothing to read. An empty
            // name would make two fresh sessions indistinguishable at exactly the
            // moment somebody opened the second one and is looking for it.
            let members = row([
                session("a", .working, born: 100),
                session("b", .working, born: 200),
            ]).members

            t.expectEqual(members.map(\.name), ["#1", "#2"], "position, until there is a title")
        },

        TestCase("A row holding one session still lists it") { t in
            let members = row([session("only", .ready, born: 100, title: "One thing")]).members
            t.expectEqual(members.count, 1, "one member")
            t.expectEqual(members.first?.ordinal, 1, "and it is the first")
        },

        TestCase("Two sessions born in the same instant keep a stable order") { t in
            // Adoption from the filesystem gives a whole set the same timestamp.
            // Ties broken by id rather than left to the sort, because an unstable
            // sort would renumber the list between two identical renders.
            let members = row([
                session("bbb", .working, born: 100),
                session("aaa", .working, born: 100),
            ]).members

            t.expectEqual(members.map(\.id), ["aaa", "bbb"], "the tie is broken, not left open")
        },

        TestCase("When a session was first seen survives every copy") { t in
            // `firstSeenAt` is the only stable thing about a session: `updatedAt`
            // and `statusSince` both move. A copy that dropped it would renumber
            // the list on the next signal, which is the defect this exists to
            // prevent.
            let born = t0.addingTimeInterval(50)
            let original = SessionState(
                id: "a", status: .working, workspace: Workspace(path: "/dev/project"),
                updatedAt: t0, statusSince: t0, firstSeenAt: born
            )

            let moved = original
                .with(status: .ready, at: t0.addingTimeInterval(900))
                .with(title: "Named later")
                .with(harness: .codex)

            t.expectEqual(moved.firstSeenAt, born, "still the moment it appeared")
        },

        TestCase("The cap leaves out only conversations at rest, never the one waiting (D190)") { t in
            // The case from the field: seven agents in one project, the cap at
            // six, and the one waiting was the seventh to be opened.
            let sessions = (1...6).map { session("s\($0)", .idle, born: TimeInterval($0) * 100) }
                + [session("stratega", .awaiting, born: 700)]
            let shown = RowSession.shown(row(sessions).members, cap: 6)
            t.expectEqual(shown.count, 6, "still six lines")
            t.expect(shown.contains { $0.id == "stratega" }, "the waiting one has its own line")
            t.expectEqual(shown.map(\.id), ["s1", "s2", "s3", "s4", "s5", "stratega"], "in the row's order, the last opened at rest left out")
        },

        TestCase("Under the cap, or opened in full, every conversation has a line (D190)") { t in
            let sessions = (1...7).map { session("s\($0)", .idle, born: TimeInterval($0) * 100) }
            let members = row(sessions).members
            t.expectEqual(RowSession.shown(Array(members.prefix(6)), cap: 6).count, 6, "six of six")
            t.expectEqual(RowSession.shown(members, cap: 6).count, 6, "seven at rest: six")
            t.expectEqual(RowSession.shown(members, cap: 6, all: true).count, 7, "opened in full: seven")
        },

        TestCase("More conversations at work than the cap all keep their lines (D190)") { t in
            let sessions = (1...8).map { session("s\($0)", $0 == 1 ? .idle : .working, born: TimeInterval($0) * 100) }
            let shown = RowSession.shown(row(sessions).members, cap: 6)
            t.expectEqual(shown.map(\.id), (2...8).map { "s\($0)" }, "all seven at work, the one at rest left out")
        },

        TestCase("A session built without one is first seen when it was last updated") { t in
            // Every construction site that predates this field, including the
            // fixtures, still has to produce a session with a defensible answer.
            let updated = t0.addingTimeInterval(400)
            let session = SessionState(
                id: "a", status: .working, workspace: Workspace(path: "/dev/project"),
                updatedAt: updated, statusSince: updated
            )
            t.expectEqual(session.firstSeenAt, updated, "the only moment it knows")
        },
    ])
}
