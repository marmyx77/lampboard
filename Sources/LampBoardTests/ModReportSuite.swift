import LampBoardCore
import Foundation
import TestKit

/// What the companion mod posts, and what the panel keeps of it.
///
/// The measure below is the shape a real session sent the prototype on
/// 4 October 2026 (`prototipi/mod-compagno/modlog.jsonl`), with the id replaced.
enum ModReportSuite {

    private static let id = "5f0c2a7e-1b3d-4c8e-9a6f-2d4b8e1c7a90"
    private static let at = Date(timeIntervalSince1970: 1_800_000_000)

    private static func decode(_ json: String) throws -> ModReport {
        try ModReport.decode(Data(json.utf8))
    }

    private static let measure = """
        {"v":1,"kind":"measure","session":"\(id)","model":"claude-opus-5-5",\
        "context":{"tokens":47162,"window":200000,"percent":24},\
        "rateLimits":[{"kind":"five_hour","percentUsed":20,"resetsAt":"2026-10-04T09:30:00.000Z"},\
        {"kind":"seven_day","percentUsed":67,"resetsAt":"2026-10-09T02:00:00.000Z"}],\
        "cost":{"usd":0.096836},"changed":["context","cost"]}
        """

    private static func session(context: ContextReading?) -> SessionState {
        SessionState(
            id: id, status: .working, workspace: Workspace(path: "/home/dev/api"),
            updatedAt: at, statusSince: at, context: context
        )
    }

    static let suite = TestSuite("The companion mod's reports", [

        TestCase("A start says what the mod can do; an answer carries its ask's nonce and the reply") { t in
            let start = try? decode(#"{"v":1,"kind":"start","session":"\#(id)","interactive":true,"features":["ask","Bad Word"]}"#)
            guard case .start(_, let begun)? = start else { return t.fail("not a start") }
            t.expectEqual(begun.features, ["ask"], "words only")
            let answer = try? decode(#"{"v":1,"kind":"answer","session":"\#(id)","id":"0F6A2C1E-6B5E-4D7A-9B1C-2E3F4A5B6C7D","text":"BLUE-HERON.\nSecond line\u0007"}"#)
            guard case .answer(let session, let reply)? = answer else { return t.fail("not an answer") }
            t.expectEqual(session, id)
            t.expectEqual(reply.id, "0F6A2C1E-6B5E-4D7A-9B1C-2E3F4A5B6C7D")
            t.expectEqual(reply.text, "BLUE-HERON.\nSecond line", "lines kept, controls gone")
            let refused = try? decode(#"{"v":1,"kind":"answer","session":"\#(id)","id":"0F6A2C1E-6B5E-4D7A-9B1C-2E3F4A5B6C7D","reason":"nothing-to-fork"}"#)
            guard case .answer(_, let none)? = refused else { return t.fail("not an answer") }
            t.expectNil(none.text)
            t.expectEqual(none.reason, "nothing-to-fork")
            let long = String(repeating: "x", count: ModReport.maxAnswer + 50)
            let cut = try? decode(#"{"v":1,"kind":"answer","session":"\#(id)","id":"0F6A2C1E-6B5E-4D7A-9B1C-2E3F4A5B6C7D","text":"\#(long)"}"#)
            guard case .answer(_, let trimmed)? = cut else { return t.fail("not an answer") }
            t.expectEqual(trimmed.text?.count, ModReport.maxAnswer, "cut to the bound")
        },

        TestCase("A stopped turn rests the row from its moment, unless the session spoke since (D160)") { t in
            guard case .stopped(_, let stopped)? = try? decode(
                #"{"v":1,"kind":"stopped","session":"\#(id)","turnId":"turn-7","at":\#(Int((at.timeIntervalSince1970 + 30) * 1000))}"#)
            else { return t.fail("not a stopped turn") }
            t.expectEqual(stopped.turnId, "turn-7")
            let working = TrafficLightState(sessions: [id: session(context: nil)])
            guard let action = stopped.action(for: working.sessions[id], now: at.addingTimeInterval(31)) else { return t.fail("no action") }
            let rested = StateReducer.reduce(working, action: action, now: at.addingTimeInterval(31))
            t.expectEqual(rested.sessions[id]?.status, .idle)
            t.expectEqual(rested.sessions[id]?.statusSince, at.addingTimeInterval(30), "from the moment of the stop")
            let spokeSince = SessionState(id: id, status: .working, workspace: Workspace(path: "/home/dev/api"),
                                          updatedAt: at.addingTimeInterval(30.5), statusSince: at.addingTimeInterval(30.5))
            let next = TrafficLightState(sessions: [id: spokeSince])
            let kept = stopped.action(for: spokeSince, now: at.addingTimeInterval(31)).map {
                StateReducer.reduce(next, action: $0, now: at.addingTimeInterval(31))
            } ?? next
            t.expectEqual(kept.sessions[id]?.status, .working, "a message sent after the stop keeps it working")
            let resting = SessionState(id: id, status: .ready, workspace: Workspace(path: "/home/dev/api"), updatedAt: at, statusSince: at)
            t.expectNil(stopped.action(for: resting, now: at), "only a working row rests")
            t.expectNil(try? decode(#"{"v":1,"kind":"stopped","session":"\#(id)","turnId":"bad id!"}"#))
        },

        TestCase("A measure carries the session's own count, cost and windows") { t in
            guard case .measure(let session, let m) = try? decode(measure) else {
                return t.fail("the measure was not read")
            }
            t.expectEqual(session, id)
            t.expectEqual(m.tokens, 47_162)
            t.expectEqual(m.window, 200_000)
            t.expectEqual(m.model, "claude-opus-5-5")
            t.expectEqual(m.costUSD, 0.096836)
            t.expect(!m.defaultAccount, "a report that does not say is not the default account")
            guard case .measure(_, let said) = try? decode(measure.replacingOccurrences(of: #""v":1,"#, with: #""v":1,"config":"default","#))
            else { return t.fail("not read") }
            t.expect(said.defaultAccount, "config default")
            t.expectEqual(m.rateLimits.map(\.kind), ["five_hour", "seven_day"])
            t.expectEqual(m.rateLimits.map(\.percent), [20, 67])
            t.expectNotNil(m.rateLimits.first?.resetsAt, "the fractional-second date is read")
        },

        TestCase("The first measure knows only the window, and makes no reading") { t in
            let first = #"{"v":1,"kind":"measure","session":"\#(id)","context":{"window":200000},"rateLimits":[]}"#
            guard case .measure(_, let m) = try? decode(first) else { return t.fail("not read") }
            t.expectNil(m.tokens)
            t.expectNil(m.reading(previous: nil, at: at), "no figure before the first response")
        },

        TestCase("A reading from the mod is reported, and keeps the ring's letter when the model is missing") { t in
            let m = ModReport.Measure(tokens: 50_000, window: nil, model: nil, rateLimits: [], costUSD: nil)
            let before = ContextReading(tokens: 1, model: "claude-sonnet-5-5", window: 1_000_000, confidence: .floor, at: nil)
            let reading = m.reading(previous: before, at: at)
            t.expectEqual(reading?.confidence, .reported)
            t.expectEqual(reading?.model, "claude-sonnet-5-5")
            t.expectEqual(reading?.window, 1_000_000)
            t.expectEqual(reading?.label, "5%")
        },

        TestCase("Start and end are read, and an unknown reason is other") { t in
            let start = #"{"v":1,"kind":"start","session":"\#(id)","surface":"terminal","interactive":true}"#
            t.expectEqual(try? decode(start), .start(session: id, start: .init(surface: "terminal", interactive: true, model: nil)))
            t.expectEqual(try? decode(#"{"v":1,"kind":"end","session":"\#(id)","reason":"clear"}"#), .end(session: id, reason: .clear))
            t.expectEqual(try? decode(#"{"v":1,"kind":"end","session":"\#(id)","reason":"nuked"}"#), .end(session: id, reason: .other))
        },

        TestCase("What is not a report is refused, each for its reason") { t in
            t.expectThrows(ModReport.Failure.unreadable) { _ = try decode("not json") }
            t.expectThrows(ModReport.Failure.badVersion) { _ = try decode(#"{"v":2,"kind":"end","session":"\#(id)"}"#) }
            t.expectThrows(ModReport.Failure.badVersion) { _ = try decode(#"{"kind":"end","session":"\#(id)"}"#) }
            t.expectThrows(ModReport.Failure.unknownKind) { _ = try decode(#"{"v":1,"kind":"turn","session":"\#(id)"}"#) }
            t.expectThrows(ModReport.Failure.badSession) { _ = try decode(#"{"v":1,"kind":"end","session":"../../etc"}"#) }
            t.expectThrows(ModReport.Failure.badSession) { _ = try decode(#"{"v":1,"kind":"end"}"#) }
        },

        // The route takes what any process of this user sends: nothing out of
        // range is kept, and nothing is drawn from a field that is not a word.
        TestCase("Out-of-range figures and odd words are dropped, not kept") { t in
            let wild = """
                {"v":1,"kind":"measure","session":"\(id)","model":"a b",\
                "context":{"tokens":-5,"window":0},"cost":{"usd":-1},\
                "rateLimits":[{"kind":"FIVE HOUR","percentUsed":20},{"kind":"seven_day","percentUsed":250}]}
                """
            guard case .measure(_, let m) = try? decode(wild) else { return t.fail("not read") }
            t.expectNil(m.tokens)
            t.expectNil(m.window)
            t.expectNil(m.costUSD)
            t.expectNil(m.model)
            t.expectEqual(m.rateLimits.map(\.kind), ["seven_day"], "a kind with spaces and capitals is not a word")
            t.expectEqual(m.rateLimits.first?.percent, 100, "clamped like a bar")
            let start = #"{"v":1,"kind":"start","session":"\#(id)","surface":"<script>"}"#
            guard case .start(_, let s) = try? decode(start) else { return t.fail("not read") }
            t.expectNil(s.surface)
        },

        // Found by the security review: `Int(1e300)` traps, and one report
        // would have taken the panel down with it.
        TestCase("A huge or negative figure is clamped, never a crash") { t in
            let huge = """
                {"v":1,"kind":"measure","session":"\(id)","context":{"tokens":1e300,"window":4.7e4},\
                "rateLimits":[{"kind":"a","percentUsed":1e300},{"kind":"b","percentUsed":-1e308},{"kind":"c","percentUsed":1e308}]}
                """
            guard case .measure(_, let m) = try? decode(huge) else { return t.fail("not read") }
            t.expectNil(m.tokens)
            t.expectEqual(m.window, 47_000, "a count spelled as a float is still a count")
            t.expectEqual(m.rateLimits.map(\.percent), [100, 0, 100])
        },

        TestCase("A model name with a control character is not kept") { t in
            let escape = #"{"v":1,"kind":"start","session":"\#(id)","model":"claude-\u001b[2J"}"#
            guard case .start(_, let s) = try? decode(escape) else { return t.fail("not read") }
            t.expectNil(s.model)
            let real = #"{"v":1,"kind":"start","session":"\#(id)","model":"claude-sonnet-5-5[1m]"}"#
            guard case .start(_, let r) = try? decode(real) else { return t.fail("not read") }
            t.expectEqual(r.model, "claude-sonnet-5-5[1m]")
        },

        TestCase("No more rate-limit windows than a plan has") { t in
            let many = (0..<50).map { #"{"kind":"k\#($0)","percentUsed":1}"# }.joined(separator: ",")
            guard case .measure(_, let m) = try? decode(#"{"v":1,"kind":"measure","session":"\#(id)","rateLimits":[\#(many)]}"#)
            else { return t.fail("not read") }
            t.expectEqual(m.rateLimits.count, 8)
        },

        TestCase("The session's own count is not replaced by the transcript's") { t in
            let reported = ContextReading(tokens: 47_162, model: "claude-opus-5-5", window: 200_000, confidence: .reported, at: at)
            let transcript = ContextReading(tokens: 40_000, model: "claude-opus-5-5", window: 200_000, confidence: .floor, at: at)
            let state = TrafficLightState(sessions: [id: session(context: reported)])
            let after = StateReducer.reduce(state, action: .observed(sessionId: id, context: transcript), now: at)
            t.expectEqual(after.sessions[id]?.context, reported)
            let newer = ContextReading(tokens: 60_000, model: "claude-opus-5-5", window: 200_000, confidence: .reported, at: at)
            let updated = StateReducer.reduce(state, action: .observed(sessionId: id, context: newer), now: at)
            t.expectEqual(updated.sessions[id]?.context, newer, "a newer report does replace it")
        },

        TestCase("Without the mod the transcript's reading still lands") { t in
            let transcript = ContextReading(tokens: 40_000, model: "claude-opus-5-5", window: 200_000, confidence: .floor, at: at)
            let state = TrafficLightState(sessions: [id: session(context: nil)])
            let after = StateReducer.reduce(state, action: .observed(sessionId: id, context: transcript), now: at)
            t.expectEqual(after.sessions[id]?.context, transcript)
        },

        TestCase("The cost lands on the row, and the card sums the project's conversations") { t in
            let other = "6a1d3b8f-2c4e-4d9a-8b7f-3e5c9d2a1b80"
            var state = TrafficLightState(sessions: [id: session(context: nil)])
            state = StateReducer.reduce(state, action: .costed(sessionId: id, usd: 0.0968), now: at)
            t.expectEqual(state.sessions[id]?.costUSD, 0.0968)
            t.expectEqual(StateReducer.reduce(state, action: .costed(sessionId: other, usd: 1), now: at).sessions.count, 1,
                          "a cost never makes a row")
            var second = session(context: nil)
            second = SessionState(id: other, status: .idle, workspace: second.workspace, updatedAt: at, statusSince: at, costUSD: 1.5)
            state = state.upserting(second)
            let row = ColumnRow(id: "r", workspace: second.workspace, sessions: [state.sessions[id]!, second])
            let cost = RowSummary.of(row, now: at).fields.first { $0.label == "cost" }
            t.expectEqual(cost?.value, "$1.60")
            t.expect(cost?.detail?.contains("2 conversations") == true, "detail: \(cost?.detail ?? "")")
        },

        TestCase("A row without the mod has no cost line, and a cent is never a zero") { t in
            let row = ColumnRow(id: "r", workspace: session(context: nil).workspace, sessions: [session(context: nil)])
            t.expect(!RowSummary.of(row, now: at).fields.contains { $0.label == "cost" }, "no line")
            t.expectEqual(RowSummary.spelled(dollars: 0.002), "<$0.01")
            t.expectEqual(RowSummary.spelled(dollars: 12.4), "$12.40")
        },

        TestCase("The row says the figure was counted by the session") { t in
            let reported = ContextReading(tokens: 47_162, model: "claude-opus-5-5", window: 200_000, confidence: .reported, at: at)
            t.expectEqual(reported.label, "24%", "never a floor sign")
        },
    ])
}

/// What the panel keeps of the reports, per session.
enum ModLedgerSuite {

    private static let a = "aaaaaaaa-0000-4000-8000-000000000001"
    private static let b = "bbbbbbbb-0000-4000-8000-000000000002"
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func measure(_ id: String, cost: Double?, limits: [ModReport.RateLimit] = []) -> ModReport {
        .measure(session: id, measure: .init(tokens: 10, window: 100, model: nil, rateLimits: limits, costUSD: cost,
                                             defaultAccount: true))
    }

    static let suite = TestSuite("What the panel keeps of the mod's reports", [

        TestCase("Start, measure and end add up for one session") { t in
            let ledger = ModLedger()
                .applying(.start(session: a, start: .init(surface: "terminal", interactive: true, model: "claude-opus-5-5")), now: t0)
                .applying(measure(a, cost: 0.1), now: t0.addingTimeInterval(5))
                .applying(.end(session: a, reason: .exit), now: t0.addingTimeInterval(9))
            let facts = ledger.sessions[a]
            t.expectEqual(facts?.surface, "terminal")
            t.expectEqual(facts?.interactive, true)
            t.expectEqual(facts?.model, "claude-opus-5-5")
            t.expectEqual(facts?.costUSD, 0.1)
            t.expectEqual(facts?.ended, .exit)
            t.expectEqual(facts?.heardAt, t0.addingTimeInterval(9))
        },

        TestCase("A measure without figures keeps the last ones") { t in
            let limit = ModReport.RateLimit(kind: "five_hour", percent: 20, resetsAt: nil)
            let ledger = ModLedger()
                .applying(measure(a, cost: 0.2, limits: [limit]), now: t0)
                .applying(measure(a, cost: nil), now: t0.addingTimeInterval(60))
            t.expectEqual(ledger.sessions[a]?.costUSD, 0.2)
            t.expectEqual(ledger.sessions[a]?.rateLimits, [limit], "an empty list is not every window at zero")
            t.expectEqual(ledger.sessions[a]?.rateLimitsAt, t0)
        },

        TestCase("The account's windows are the newest any session reported") { t in
            let old = ModReport.RateLimit(kind: "five_hour", percent: 20, resetsAt: nil)
            let new = ModReport.RateLimit(kind: "five_hour", percent: 35, resetsAt: nil)
            let ledger = ModLedger()
                .applying(measure(b, cost: nil, limits: [new]), now: t0.addingTimeInterval(120))
                .applying(measure(a, cost: nil, limits: [old]), now: t0)
                .applying(measure(a, cost: 0.3), now: t0.addingTimeInterval(300))
            t.expectEqual(ledger.latestRateLimits?.limits, [new])
            t.expectEqual(ledger.latestRateLimits?.at, t0.addingTimeInterval(120))
        },

        TestCase("Only the default account's windows are the strip's") { t in
            let other = ModReport.measure(session: b, measure: .init(
                tokens: 1, window: 1, model: nil, rateLimits: [.init(kind: "five_hour", percent: 90, resetsAt: nil)],
                costUSD: nil, defaultAccount: false))
            let ledger = ModLedger().applying(other, now: t0)
            t.expectNil(ledger.latestRateLimits, "a session with a config of its own may be another account")
        },

        TestCase("A restart clears the end, and the sessions gone from the column are dropped") { t in
            let ledger = ModLedger()
                .applying(.end(session: a, reason: .clear), now: t0)
                .applying(.start(session: a, start: .init(surface: nil, interactive: false, model: nil)), now: t0)
                .applying(measure(b, cost: 1), now: t0)
            t.expectNil(ledger.sessions[a]?.ended)
            t.expectEqual(Set(ledger.keeping([b]).sessions.keys), [b])
        },

        TestCase("A flood of invented ids cannot grow the ledger without end") { t in
            var ledger = ModLedger()
            for n in 0..<(ModLedger.maxSessions + 40) {
                ledger = ledger.applying(measure(String(format: "%08d-flood", n), cost: nil), now: t0.addingTimeInterval(Double(n)))
            }
            t.expectEqual(ledger.sessions.count, ModLedger.maxSessions)
            t.expectNil(ledger.sessions["00000000-flood"], "the least recently heard went first")
        },
    ])
}
