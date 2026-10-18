import LampBoardCore
import Foundation
import TestKit

/// Which notifications a source sends after each look (§2.9, W4): transitions
/// only, amber after four seconds, the silences, presence, and the device last
/// used ringing first (Q5, Q9). The gate «Push oneste» of §6.2.
enum PushPlannerSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private static let node = V1SourceIdentity(kind: .node, name: "example-node")

    static func id(_ n: Int) -> String { String(format: "20000000-0000-4000-8000-%012ld", n) }

    static func row(_ n: Int, _ status: SessionStatus, since: Date = t0, workspace: String? = nil,
                    muted: Bool = false, hidden: Bool = false, ask: String? = nil) -> V1Row {
        let session = SessionSnapshot(
            id: id(n), status: status.rawValue, workspace: workspace ?? "project-\(n)", path: "/work/project-\(n)",
            updatedAt: since, statusSince: since, pendingAsk: ask, muted: muted, entrypoint: "cli", origin: "terminal",
            title: "Example session \(n)"
        )
        return V1Row(session: session, source: node, extras: V1RowExtras(hidden: hidden))
    }

    static let phone = PushDevice(id: "phone-1", usedAt: t0.addingTimeInterval(-3600))
    static let pad = PushDevice(id: "pad-1", usedAt: t0.addingTimeInterval(-7200))

    /// Looks one after the other, the alerts of each.
    static func run(_ looks: [(Double, [V1Row])], devices: [PushDevice] = [phone], memory: PushMemory = PushMemory())
        -> (alerts: [[PlannedAlert]], memory: PushMemory, plans: [PushPlan]) {
        var memory = memory
        var alerts: [[PlannedAlert]] = []
        var plans: [PushPlan] = []
        for (seconds, rows) in looks {
            let (plan, next) = PushPlanner.plan(rows: rows, devices: devices, memory: memory, at: t0.addingTimeInterval(seconds))
            memory = next
            alerts.append(plan.alerts)
            plans.append(plan)
        }
        return (alerts, memory, plans)
    }

    static let suite = TestSuite("Push planner: which notifications a source sends", [

        TestCase("Ten amber rows at start are zero notifications, and stay zero") { t in
            let ambers = (1...10).map { row($0, .awaiting, since: t0.addingTimeInterval(-60)) }
            let result = run([(0, ambers), (5, ambers), (60, ambers)])
            t.expectEqual(result.alerts.flatMap { $0 }.count, 0, "what was so at start is not news")
        },

        TestCase("Gate «Push oneste» bites: without the announced memory the same ten ring") { t in
            let ambers = (1...10).map { row($0, .awaiting, since: t0.addingTimeInterval(-60)) }
            var primed = run([(0, [])]).memory
            primed.statuses = Dictionary(uniqueKeysWithValues: ambers.map { ($0.id, "idle") })
            let result = run([(5, ambers)], memory: primed)
            t.expectEqual(result.alerts.flatMap { $0 }.count, 10, "a memory emptied turns ten ambers into ten notifications")
        },

        TestCase("An amber row rings once, four seconds into its spell, urgent") { t in
            let result = run([
                (0, [row(1, .working)]),
                (5, [row(1, .awaiting, since: t0.addingTimeInterval(4))]),
                (10, [row(1, .awaiting, since: t0.addingTimeInterval(4))]),
                (15, [row(1, .awaiting, since: t0.addingTimeInterval(4))]),
            ])
            t.expectEqual(result.alerts.map(\.count), [0, 0, 1, 0], "not at one second old, once at six, never again")
            t.expectEqual(result.alerts[2].first?.urgent, true, "a question is priority 10")
            t.expectEqual(result.alerts[2].first?.event, .waiting, "waiting")
            t.expectEqual(result.plans[1].nextCheck, t0.addingTimeInterval(8), "and it asks to be looked at when it is old enough")
        },

        TestCase("An amber row answered within four seconds never rings") { t in
            let result = run([
                (0, [row(1, .working)]),
                (1, [row(1, .awaiting, since: t0.addingTimeInterval(1))]),
                (3, [row(1, .working, since: t0.addingTimeInterval(3))]),
                (20, [row(1, .working, since: t0.addingTimeInterval(3))]),
            ])
            t.expectEqual(result.alerts.flatMap { $0 }.count, 0, "resolved within four seconds")
        },

        TestCase("A second amber spell is a second notification") { t in
            let result = run([
                (0, [row(1, .working)]),
                (10, [row(1, .awaiting, since: t0)]),
                (20, [row(1, .working, since: t0.addingTimeInterval(20))]),
                (30, [row(1, .awaiting, since: t0.addingTimeInterval(25))]),
            ])
            t.expectEqual(result.alerts.map(\.count), [0, 1, 0, 1], "one per spell")
        },

        TestCase("Off still remembers: turning notifications on is not a burst") { t in
            let off = PushDevice(id: "phone-1", preferences: V1PushPreferences(enabled: false), usedAt: phone.usedAt)
            var memory = run([(0, [row(1, .working), row(2, .working)])], devices: [off]).memory
            let ambers = [row(1, .awaiting, since: t0.addingTimeInterval(5)), row(2, .awaiting, since: t0.addingTimeInterval(5))]
            let quiet = run([(20, ambers)], devices: [off], memory: memory)
            t.expectEqual(quiet.alerts.flatMap { $0 }.count, 0, "off sends nothing")
            memory = quiet.memory
            let on = run([(40, ambers)], devices: [phone], memory: memory)
            t.expectEqual(on.alerts.flatMap { $0 }.count, 0, "turned on later: what was already amber is not news")
        },

        TestCase("Red rings on the transition; a finished turn only for a device that asked") { t in
            let wants = PushDevice(id: "pad-1", preferences: V1PushPreferences(finished: true), usedAt: pad.usedAt)
            let result = run([
                (0, [row(1, .working), row(2, .working)]),
                (5, [row(1, .failed), row(2, .idle)]),
            ], devices: [phone, wants])
            let events = Set(result.alerts[1].map { "\($0.device) \($0.event.rawValue)" })
            t.expect(events.contains("phone-1 failed"), "red, to the device last used")
            t.expect(events.contains("pad-1 finished"), "the finished turn to the device that asked")
            t.expect(!events.contains("phone-1 finished"), "never to one that did not")
        },

        TestCase("«Don't alert me», muted projects and «until» are silences") { t in
            let project = PushDevice(id: "phone-1", preferences: V1PushPreferences(mutedProjects: ["project-2"]), usedAt: phone.usedAt)
            let looks: [(Double, [V1Row])] = [
                (0, [row(1, .working, muted: true), row(2, .working), row(3, .working)]),
                (10, [row(1, .awaiting, since: t0, muted: true), row(2, .awaiting, since: t0), row(3, .awaiting, since: t0)]),
            ]
            let result = run(looks, devices: [project])
            t.expectEqual(result.alerts[1].map(\.session), [id(3)], "the muted row and the muted project stay quiet")
            let until = PushDevice(id: "phone-1", preferences: V1PushPreferences(mutedUntil: t0.addingTimeInterval(3600)), usedAt: phone.usedAt)
            t.expectEqual(run(looks, devices: [until]).alerts.flatMap { $0 }.count, 0, "everything silent for an hour")
        },

        TestCase("The device last used rings; the other gets a quiet copy two minutes later if nobody moved") { t in
            let looks: [(Double, [V1Row])] = [
                (0, [row(1, .working)]),
                (10, [row(1, .awaiting, since: t0)]),
                (60, [row(1, .awaiting, since: t0)]),
                (131, [row(1, .awaiting, since: t0)]),
                (200, [row(1, .awaiting, since: t0)]),
            ]
            let result = run(looks, devices: [pad, phone])
            t.expectEqual(result.alerts[1].map(\.device), ["phone-1"], "the one used last rings")
            t.expectEqual(result.alerts[1].first?.quiet, false, "with its sound")
            t.expectEqual(result.alerts[2].count, 0, "not yet")
            t.expectEqual(result.alerts[3].map(\.device), ["pad-1"], "the other, after two minutes")
            t.expectEqual(result.alerts[3].first?.quiet, true, "quietly")
            t.expectEqual(result.alerts[4].count, 0, "once")
        },

        TestCase("The quiet copy is not sent once the row has moved") { t in
            let result = run([
                (0, [row(1, .working)]),
                (10, [row(1, .awaiting, since: t0)]),
                (60, [row(1, .working, since: t0.addingTimeInterval(60))]),
                (200, [row(1, .working, since: t0.addingTimeInterval(60))]),
            ], devices: [pad, phone])
            t.expectEqual(result.alerts.flatMap { $0 }.map(\.device), ["phone-1"], "answered in time: nobody else hears of it")
        },

        TestCase("An app in front shows the row itself: no phone rings; put away, a session still waiting does") { t in
            let inHand = PushDevice(id: "phone-1", usedAt: t0.addingTimeInterval(5))
            let result = run([
                (0, [row(1, .working)]),
                (10, [row(1, .awaiting, since: t0)]),
                (30, [row(1, .awaiting, since: t0)]),
                (60, [row(1, .awaiting, since: t0)]),
                (90, [row(1, .awaiting, since: t0)]),
            ], devices: [inHand, pad])
            t.expectEqual(result.alerts[1].count + result.alerts[2].count, 0, "seen in the last 45 s: neither it nor the iPad")
            t.expectEqual(result.alerts[3].map(\.device), ["phone-1"], "the phone put away, the row still waiting: it rings")
            t.expectEqual(result.alerts[4].count, 0, "once")
            let answered = run([
                (0, [row(1, .working)]),
                (10, [row(1, .awaiting, since: t0)]),
                (30, [row(1, .working, since: t0.addingTimeInterval(30))]),
                (90, [row(1, .working, since: t0.addingTimeInterval(30))]),
            ], devices: [inHand, pad])
            t.expectEqual(answered.alerts.flatMap { $0 }.count, 0, "answered from the app: nothing afterwards")
        },

        TestCase("In one session, the others' alerts wait and come in one line when it leaves") { t in
            let focused = PushDevice(id: "phone-1", usedAt: t0.addingTimeInterval(9), focusedSession: id(1))
            var memory = run([(0, [row(1, .working), row(2, .working), row(3, .working)])], devices: [focused]).memory
            let during = run([(10, [row(1, .working), row(2, .awaiting, since: t0), row(3, .failed)])], devices: [focused], memory: memory)
            t.expectEqual(during.alerts.flatMap { $0 }.count, 0, "held while the person is in session 1")
            memory = during.memory
            let gone = PushDevice(id: "phone-1", usedAt: t0.addingTimeInterval(9))
            let after = run([(120, [row(1, .working), row(2, .awaiting, since: t0), row(3, .failed)])], devices: [gone], memory: memory)
            let line = after.alerts.flatMap { $0 }
            t.expectEqual(line.count, 1, "one line")
            t.expectEqual(line.first?.event, .summary, "the summary")
            t.expect(line.first?.body.hasPrefix("While you were focused:") == true, "said as the Mac says it: \(line.first?.body ?? "")")
        },

        TestCase("The counts go out when they change, and only then") { t in
            let result = run([
                (0, [row(1, .working), row(2, .idle)]),
                (5, [row(1, .working), row(2, .idle)]),
                (10, [row(1, .awaiting, since: t0), row(2, .idle, hidden: true)]),
            ])
            t.expectEqual(result.plans[0].counts, PushCounts(waiting: 0, failed: 0, ready: 0, working: 1), "first")
            t.expectNil(result.plans[1].counts, "unchanged")
            t.expectEqual(result.plans[2].counts, PushCounts(waiting: 1, failed: 0, ready: 0, working: 0), "changed")
        },

        TestCase("The memory survives a restart of the source as JSON") { t in
            let memory = run([(0, [row(1, .working)]), (10, [row(1, .awaiting, since: t0)])], devices: [pad, phone]).memory
            let data = try? V1Codec.encoder().encode(memory)
            let back = data.flatMap { try? V1Codec.decoder().decode(PushMemory.self, from: $0) }
            t.expectEqual(back, memory, "written and read back")
        },

        TestCase("While you were away: finished turns and failures the column no longer shows") { t in
            var ledger = RowsAwayLedger(since: t0, rows: [row(1, .working), row(2, .working)])
            ledger.observe([row(1, .idle), row(2, .failed)])
            ledger.observe([row(1, .working), row(2, .working)])
            ledger.observe([row(1, .idle), row(2, .working)])
            let line = ledger.summary(now: t0.addingTimeInterval(4000), rows: [row(1, .idle), row(2, .working)])
            t.expectEqual(line, "While you were away (1h 6m): 2 turns finished (project-1), 1 earlier failure (project-2).", "the line")
            t.expectNil(RowsAwayLedger(since: t0, rows: []).summary(now: t0, rows: []), "nothing, never «nothing happened»")
        },
    ])
}
