import CoreGraphics
import LampBoardCore
import Foundation
import TestKit

/// The lamp in the menu bar: what it stands for, and whether it is there at all.
enum MenuBarSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private static func session(
        _ id: String,
        _ status: SessionStatus,
        path: String,
        harness: Harness = .claudeCode
    ) -> SessionState {
        SessionState(
            id: id,
            status: status,
            workspace: Workspace(path: path),
            updatedAt: t0,
            statusSince: t0,
            harness: harness
        )
    }

    private static func summary(
        _ sessions: [SessionState],
        options: ColumnOptions = ColumnOptions(),
        calm: Set<String> = []
    ) -> MenuBarSummary {
        let state = TrafficLightState(
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        )
        return MenuBarSummary.of(
            rendering: ColumnLayout.render(state, options: options),
            calmWorkspaces: calm
        )
    }

    static let suite = TestSuite("The lamp in the menu bar", [

        TestCase("An empty column has nothing to say") { t in
            let s = summary([])
            t.expect(s.isEmpty, "no lamp")
            t.expectEqual(s.count, 0, "and nothing to count")
            t.expect(!(s.blinks), "and nothing to blink about")
            t.expectEqual(s.tooltip, "LampBoard: no sessions", "and it says so")
        },

        TestCase("The icon carries the most urgent thing the column is showing") { t in
            // The order here is deliberately not the urgency order: the summary
            // must rank them, not take the first.
            let s = summary([
                session("a", .working, path: "/dev/one"),
                session("b", .awaiting, path: "/dev/two"),
                session("c", .idle, path: "/dev/three"),
            ])
            t.expectEqual(s.lamp, .awaiting, "amber outranks the rest")
            t.expectEqual(s.count, 1, "and there is one of it")
        },

        TestCase("It counts how many rows carry that state") { t in
            let s = summary([
                session("a", .ready, path: "/dev/one"),
                session("b", .ready, path: "/dev/two"),
                session("c", .working, path: "/dev/three"),
            ])
            t.expectEqual(s.lamp, .ready, "green is the most urgent here")
            t.expectEqual(s.count, 2, "two rows of it")
            t.expectEqual(s.counts[.working], 1, "and the rest is still counted")
        },

        TestCase("Only the three states a click clears make it blink") { t in
            // The same three the row's own click puts back to rest. A blink that
            // fired on `working` would be on for most of the day, and a signal
            // that is always on is not a signal.
            for status in [SessionStatus.awaiting, .ready, .failed] {
                let s = summary([session("x", status, path: "/dev/one")])
                t.expect(s.blinks, "\(status.rawValue) blinks")
                t.expect(s.needsAttention, "\(status.rawValue) is news")
            }
            for status in [SessionStatus.working, .waiting, .idle] {
                let s = summary([session("x", status, path: "/dev/one")])
                t.expect(!(s.blinks), "\(status.rawValue) holds still")
                t.expect(!(s.needsAttention), "\(status.rawValue) is not news")
            }
        },

        TestCase("A project told not to blink still colours the icon") { t in
            // *Don't blink* silences the movement and not the state, on a row and
            // for the same reason up here.
            let s = summary(
                [session("x", .awaiting, path: "/dev/one")],
                calm: [Workspace(path: "/dev/one").key]
            )
            t.expectEqual(s.lamp, .awaiting, "the colour stays")
            t.expect(!(s.blinks), "the movement does not")
        },

        TestCase("One silenced project does not silence another") { t in
            let s = summary(
                [
                    session("x", .awaiting, path: "/dev/quiet"),
                    session("y", .awaiting, path: "/dev/loud"),
                ],
                calm: [Workspace(path: "/dev/quiet").key]
            )
            t.expect(s.blinks, "the one that was not silenced still asks")
            t.expectEqual(s.count, 2, "and both are counted")
        },

        TestCase("A hidden project that needs attention still reaches the icon") { t in
            // Hidden is not forgotten: the column keeps a summary line that lights
            // up, and an icon that ignored it would move the "hide means forget"
            // failure into the menu bar, where it is harder to notice.
            let s = summary(
                [
                    session("x", .awaiting, path: "/dev/hidden"),
                    session("y", .idle, path: "/dev/shown"),
                ],
                options: ColumnOptions(hidden: [Workspace(path: "/dev/hidden").key])
            )
            t.expectEqual(s.lamp, .awaiting, "the hidden row's state reaches the icon")
            t.expect(s.blinks, "and it blinks")
        },

        TestCase("The filter changes what the icon answers for") { t in
            // With "only what's waiting" on, a working session is not on screen,
            // so the icon must not speak for it. The icon summarises the column,
            // never the state behind it.
            let sessions = [
                session("a", .working, path: "/dev/one"),
                session("b", .ready, path: "/dev/two"),
            ]
            let all = summary(sessions)
            let filtered = summary(sessions, options: ColumnOptions(onlyWaiting: true))
            t.expectEqual(all.counts[.working], 1, "unfiltered, the working row counts")
            t.expectNil(filtered.counts[.working], "filtered, it is not on screen")
            t.expectEqual(filtered.lamp, .ready, "and the green is what is left")
        },

        TestCase("Grouping is respected, because rows are what a person sees") { t in
            // Two sessions, one project, one row. The icon counts one.
            let s = summary([
                session("a", .ready, path: "/dev/project"),
                session("b", .ready, path: "/dev/project", harness: .codex),
            ])
            t.expectEqual(s.count, 1, "one row, not two sessions")
        },

        TestCase("A count of things asking for nothing is not shown") { t in
            // Seen in the menu bar on the first build: a resting ring with `6`
            // beside it, because six projects were idle. The number is only worth
            // the space when it counts something that wants a person.
            let resting = summary([
                session("a", .idle, path: "/dev/one"),
                session("b", .idle, path: "/dev/two"),
            ])
            t.expectEqual(resting.count, 2, "the count is still there for the tooltip")
            t.expect(!(resting.needsAttention), "but nothing here wants anybody")

            let asking = summary([
                session("c", .awaiting, path: "/dev/three"),
                session("d", .awaiting, path: "/dev/four"),
            ])
            t.expect(asking.needsAttention, "two blocked sessions do")
            t.expectEqual(asking.count, 2, "and the number says how many")
        },

        // MARK: Whether the lamp is on screen at all

        // The strip status items are drawn in, on the machine these numbers were
        // measured on: a 14-inch MacBook, whose notch leaves 848 to 1512.
        // Everything below uses those, because a rule about geometry tested with
        // invented geometry proves only that the arithmetic runs.

        TestCase("A lamp inside the strip the system draws in is reachable") { t in
            let verdict = MenuBarPlacement.verdict(
                lamp: CGRect(x: 1_180, y: 949, width: 28, height: 33),
                in: CGRect(x: 848, y: 950, width: 664, height: 32)
            )
            t.expectEqual(verdict, .reachable, "beside the clock, where a lamp belongs")
        },

        TestCase("A lamp the system accepted and did not draw is unreachable") { t in
            // The measurement this whole rule exists for. The bar was full, the
            // item was created, `isVisible` answered true, and the frame came back
            // at x=809 — inside the notch, thirty-nine points short of the strip.
            // Nothing was on screen, and the panel that lived behind it could not
            // be opened by any gesture.
            let verdict = MenuBarPlacement.verdict(
                lamp: CGRect(x: 809, y: 949, width: 28, height: 33),
                in: CGRect(x: 848, y: 950, width: 664, height: 32)
            )
            t.expectEqual(verdict, .unreachable, "a frame is not the same thing as a lamp")
        },

        TestCase("So is one pushed clean off the side of the screen") { t in
            // Further down the same run: the frames keep being handed out past the
            // left edge of the display. This one was the twenty-sixth.
            let verdict = MenuBarPlacement.verdict(
                lamp: CGRect(x: -345, y: 949, width: 44, height: 33),
                in: CGRect(x: 848, y: 950, width: 664, height: 32)
            )
            t.expectEqual(verdict, .unreachable, "off the screen is not somewhere to click")
        },

        TestCase("The rule is inside the strip, not merely starting inside it") { t in
            let verdict = MenuBarPlacement.verdict(
                lamp: CGRect(x: 1_500, y: 949, width: 44, height: 33),
                in: CGRect(x: 848, y: 950, width: 664, height: 32)
            )
            t.expectEqual(verdict, .unreachable, "a lamp hanging off the end is not whole")
        },

        TestCase("A frame with no height has not been laid out yet") { t in
            // Measured on the turn the item is created, and on the next one:
            // `(0, 0, 28, 0)`. Reading that as a refusal would move the panel out
            // of the menu bar on every single launch, for everybody.
            let verdict = MenuBarPlacement.verdict(
                lamp: CGRect(x: 0, y: 0, width: 28, height: 0),
                in: CGRect(x: 848, y: 950, width: 664, height: 32)
            )
            t.expectEqual(verdict, .notYetPlaced, "ask again rather than conclude")
        },

        TestCase("A screen with no notch is not evidence of anything") { t in
            // There is no equivalent of the strip on a screen without a notch, and
            // a rule that guessed there would be moving somebody's panel on a
            // hunch. The panel keeps its home, and the door added for this — the
            // app itself, started a second time — works there too.
            let verdict = MenuBarPlacement.verdict(
                lamp: CGRect(x: 300, y: 1_400, width: 28, height: 33), in: nil
            )
            t.expectEqual(verdict, .reachable, "nothing here can disprove the lamp")
        },

        TestCase("The tooltip names states in order of urgency") { t in
            let s = summary([
                session("a", .idle, path: "/dev/one"),
                session("b", .awaiting, path: "/dev/two"),
                session("c", .working, path: "/dev/three"),
            ])
            t.expectEqual(
                s.tooltip,
                "LampBoard: 1 waiting for your answer, 1 working, 1 idle",
                "most urgent first, and it names the state rather than the colour"
            )
        },
    ])
}
