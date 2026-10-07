import LampBoardCore
import Foundation
import TestKit

/// Sessions at rest for half a day fold into one line at the foot of the column
/// (U2): «Resting · 3 — legacy-import, billing-worker, checkout-api».
enum RestingFoldSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let hour: TimeInterval = 3_600

    private static func session(_ id: String, _ status: SessionStatus, hoursAgo: Double, folder: String? = nil) -> SessionState {
        let at = t0.addingTimeInterval(-hoursAgo * hour)
        return SessionState(id: id, status: status, workspace: Workspace(path: "/home/dev/\(folder ?? id)"),
                            updatedAt: at, statusSince: at)
    }

    private static func state(_ sessions: [SessionState]) -> TrafficLightState {
        TrafficLightState(sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }))
    }

    private static let mixed = state([
        session("api", .working, hoursAgo: 0),
        session("docs", .idle, hoursAgo: 2),
        session("legacy", .idle, hoursAgo: 37),
        session("billing", .idle, hoursAgo: 31),
    ])
    private static let order = ["/home/dev/api", "/home/dev/legacy", "/home/dev/docs", "/home/dev/billing"]

    static let suite = TestSuite("Resting fold", [

        TestCase("Rows at rest for twelve hours leave the column for one line, in the user's order") { t in
            let rendering = ColumnLayout.render(mixed, options: ColumnOptions(order: order), now: t0)
            t.expectEqual(rendering.rows.map(\.id), ["/home/dev/api", "/home/dev/docs"], "two hours at rest is not resting yet")
            t.expectEqual(rendering.resting?.rows.map(\.id), ["/home/dev/legacy", "/home/dev/billing"])
            t.expectEqual(rendering.resting?.line, "Resting · 2 — legacy, billing")
        },

        TestCase("Opened, the line stays and the rows are listed under it") { t in
            let rendering = ColumnLayout.render(mixed, options: ColumnOptions(order: order, showsResting: true), now: t0)
            t.expectEqual(rendering.resting?.isOpen, true)
            t.expectEqual(rendering.rows.count, 2, "the resting rows are drawn under the line, not among the others")
        },

        TestCase("A project with one session still working is not resting") { t in
            let busy = state([
                session("a", .idle, hoursAgo: 40, folder: "web"),
                session("b", .working, hoursAgo: 0, folder: "web"),
            ])
            let rendering = ColumnLayout.render(busy, options: ColumnOptions(), now: t0)
            t.expectNil(rendering.resting)
            t.expectEqual(rendering.rows.count, 1)
        },

        TestCase("A bound key still finds a folded row") { t in
            let rendering = ColumnLayout.render(mixed, options: ColumnOptions(order: order), now: t0)
            t.expectEqual(rendering.row(inSlot: 2)?.id, "/home/dev/legacy")
        },

        TestCase("Without a clock nothing folds: the callers that never asked keep their rows") { t in
            let rendering = ColumnLayout.render(mixed, options: ColumnOptions(order: order))
            t.expectNil(rendering.resting)
            t.expectEqual(rendering.rows.count, 4)
        },

        TestCase("«Only what's waiting» sets them aside like any other quiet row, with no line") { t in
            let rendering = ColumnLayout.render(mixed, options: ColumnOptions(onlyWaiting: true, order: order), now: t0)
            t.expectNil(rendering.resting)
            t.expectEqual(rendering.filteredOut, 4)
        },

        TestCase("At rest is grey and says «resting», never the red of a failure") { t in
            t.expectEqual(SessionStatus.idle.label, "resting")
        },
    ])
}
