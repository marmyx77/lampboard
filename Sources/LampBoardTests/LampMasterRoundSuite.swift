import LampBoardCore
import Foundation
import TestKit

/// The round around the model: the command it runs, the envelope it reads,
/// when it runs at all, and the ledger of what it showed.
enum LampMasterRoundSuite {

    typealias F = LampMasterFixtures
    typealias S = LampMasterAdvice.Suggestion

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static let envelope = #"""
    {"type":"result","subtype":"success","is_error":false,"duration_ms":16900,"num_turns":1,
     "total_cost_usd":0.079,"usage":{"input_tokens":12,"cache_read_input_tokens":4000,
     "cache_creation_input_tokens":1600,"output_tokens":1500},
     "structured_output":{"notebook":"n","suggestions":[{"kind":"stalled","sessions":["9ffa24f0"],
      "text":"t","evidence":"e","action":{"kind":"open"},"confidence":0.8,"key":"k"}]}}
    """#

    static func suggestion(_ key: String, sessions: [String] = ["aaaaaaaa"]) -> S {
        S(kind: .stalled, sessions: sessions, text: "t", evidence: "e", action: .init(kind: .open),
          confidence: 0.8, key: key)
    }

    static func decide(
        _ trigger: LampMasterSchedule.Trigger, enabled: Bool = true, lastRun: Double? = 0,
        lastDigest: String? = "old", digest: String = "new", sessions: Int = 3, tokens: Int = 0, at minutes: Double
    ) -> LampMasterSchedule.Decision {
        LampMasterSchedule.decide(
            trigger: trigger, enabled: enabled, interval: LampMasterSchedule.defaultInterval,
            lastRun: lastRun.map(F.at), lastDigest: lastDigest, digest: digest, sessionCount: sessions,
            tokensToday: tokens, now: F.at(minutes)
        )
    }

    static func frame(_ chunks: [String], at minutes: Double) -> LampMasterFrame {
        let session = LampMasterSession(card: F.card("aaaaaaaa1", chunks), liveness: .idle)
        return LampMasterFrameBuilder.build(sessions: [session], now: F.at(minutes))
    }

    static let suite = TestSuite("LampMaster: the round", [

        TestCase("The command keeps the round out of hooks, sessions, connectors and settings") { t in
            let arguments = LampMasterCommand.arguments(model: "sonnet", system: "be brief")
            t.expectEqual(value(after: "--settings", in: arguments), #"{"disableAllHooks":true}"#)
            t.expectEqual(value(after: "--tools", in: arguments), "")
            t.expectEqual(value(after: "--setting-sources", in: arguments), "")
            t.expectEqual(value(after: "--mcp-config", in: arguments), #"{"mcpServers":{}}"#)
            t.expectEqual(value(after: "--model", in: arguments), "sonnet")
            t.expectEqual(value(after: "--system-prompt", in: arguments), "be brief")
            for flag in ["-p", "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands"] {
                t.expect(arguments.contains(flag), "\(flag) is passed")
            }
        },

        TestCase("The frame is never an argument: ps would show it") { t in
            let arguments = LampMasterCommand.arguments(model: "opus", system: LampMasterPrompt.system(language: "English"))
            t.expect(!arguments.contains { $0.contains("<frame>") }, "no frame among the arguments")
            t.expectEqual(arguments.filter { !$0.hasPrefix("-") }.count, 9, "only the flags' own values")
        },

        TestCase("The envelope gives the advice, the tokens as billed, the cost and the time") { t in
            let run = LampMasterRun.read(Data(envelope.utf8))
            t.expectNil(run.failure)
            t.expectEqual(run.advice?.suggestions.first?.key, "k")
            t.expectEqual(run.inputTokens, 5_612, "fresh, cache read and cache write")
            t.expectEqual(run.outputTokens, 1_500)
            t.expectEqual(run.tokens, 7_112)
            t.expectEqual(run.costUSD, 0.079)
            t.expectEqual(run.seconds, 16.9)
        },

        TestCase("A run claude reports as failed is failed, and its tokens still count") { t in
            let failed = #"{"type":"result","subtype":"error_max_turns","is_error":true,"usage":{"input_tokens":900,"output_tokens":40}}"#
            let run = LampMasterRun.read(Data(failed.utf8))
            t.expectEqual(run.failure, .reportedError)
            t.expectNil(run.advice)
            t.expectEqual(run.tokens, 940)
        },

        TestCase("Not JSON is unreadable; an envelope without the schema is off schema") { t in
            t.expectEqual(LampMasterRun.read(Data("Error: not logged in".utf8)).failure, .unreadable)
            let prose = #"{"type":"result","subtype":"success","is_error":false,"result":"Here are my thoughts…"}"#
            t.expectEqual(LampMasterRun.read(Data(prose.utf8)).failure, .offSchema)
        },

        TestCase("The timer waits for the interval; a failed round counts as a run") { t in
            t.expectEqual(decide(.timer, at: 59), .wait)
            t.expectEqual(decide(.timer, at: 60), .run)
            t.expectEqual(decide(.timer, lastRun: nil, at: 0), .run, "never ran")
        },

        TestCase("The interval stays between thirty minutes and two hours") { t in
            t.expectEqual(LampMasterSchedule.clamp(5 * 60), 30 * 60)
            t.expectEqual(LampMasterSchedule.clamp(6 * 60 * 60), 120 * 60)
            t.expectEqual(LampMasterSchedule.clamp(45 * 60), 45 * 60)
        },

        TestCase("Opening the card refreshes after fifteen minutes; asking needs two") { t in
            t.expectEqual(decide(.opened, at: 14), .wait)
            t.expectEqual(decide(.opened, at: 15), .run)
            t.expectEqual(decide(.asked, at: 1), .skip(.tooSoon), "a loop of requests cannot spend the day")
            t.expectEqual(decide(.asked, at: 2), .run)
            t.expectEqual(decide(.asked, lastRun: nil, at: 0), .run, "never ran")
        },

        TestCase("The skips, in order: off, nobody, nothing new, the day's ceiling") { t in
            t.expectEqual(decide(.asked, enabled: false, sessions: 0, at: 90), .skip(.off))
            t.expectEqual(decide(.asked, sessions: 0, at: 90), .skip(.empty))
            t.expectEqual(decide(.asked, lastDigest: "same", digest: "same", tokens: 999_999, at: 90), .skip(.unchanged))
            t.expectEqual(decide(.asked, tokens: 200_000, at: 90), .skip(.dailyCap))
            t.expectEqual(decide(.asked, tokens: 199_999, at: 90), .run)
        },

        TestCase("The digest ignores the minutes passing, and sees a new answer or a new signal") { t in
            let asking = [F.prompt("build it", at: 0), F.answer("Ready. Shall I install it?", at: 1)]
            let early = LampMasterSchedule.digest(frame(asking, at: 5))
            t.expectEqual(LampMasterSchedule.digest(frame(asking, at: 9)), early, "four minutes later")
            t.expect(LampMasterSchedule.digest(frame(asking, at: 30)) != early, "waiting on the user now")
            let answered = asking + [F.prompt("yes", at: 6)]
            t.expect(LampMasterSchedule.digest(frame(answered, at: 9)) != early, "a new prompt")
            t.expectEqual(early.count, 16)
        },

        TestCase("The last run skips the skips; today's tokens are today's") { t in
            let rounds = [
                LampMasterRound(at: F.at(-24 * 60), trigger: .timer, outcome: .ran, tokens: 50_000),
                LampMasterRound(at: F.at(0), trigger: .timer, outcome: .failed, failure: .timedOut, tokens: 900),
                LampMasterRound(at: F.at(60), trigger: .timer, outcome: .skipped, skip: .unchanged),
                LampMasterRound(at: F.at(70), trigger: .asked, outcome: .ran, tokens: 7_000),
            ]
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            t.expectEqual(LampMasterLedger.lastRun(rounds)?.at, F.at(70))
            t.expectEqual(LampMasterLedger.lastRun(Array(rounds.prefix(3)))?.outcome, .failed)
            let tied = [LampMasterRound(at: F.at(0), trigger: .timer, outcome: .ran, digest: "first"),
                        LampMasterRound(at: F.at(0), trigger: .asked, outcome: .ran, digest: "second")]
            t.expectEqual(LampMasterLedger.lastRun(tied)?.digest, "second", "a tie goes to the later line")
            t.expectEqual(LampMasterLedger.tokens(on: F.at(80), in: rounds, calendar: utc), 7_900)
        },

        TestCase("Open suggestions expire after four hours and settle when their sessions leave") { t in
            let shown = LampMasterLedger.entries(for: [suggestion("a"), suggestion("b", sessions: ["bbbbbbbb"])], at: F.at(0))
            let present: Set = ["aaaaaaaa", "bbbbbbbb"]
            t.expectEqual(LampMasterLedger.settle(shown, present: present, now: F.at(239)).filter(\.isOpen).count, 2)
            t.expectEqual(LampMasterLedger.settle(shown, present: present, now: F.at(240)).compactMap(\.outcome), [.expired, .expired])
            let gone = LampMasterLedger.settle(shown, present: ["aaaaaaaa"], now: F.at(10))
            t.expectEqual(gone.map(\.outcome), [nil, .superseded])
        },

        TestCase("A reaction settles once; a late click on a settled card changes nothing") { t in
            let shown = LampMasterLedger.entries(for: [suggestion("a"), suggestion("b")], at: F.at(0))
            let ignored = LampMasterLedger.resolve(shown, id: shown[0].id, outcome: .ignored, now: F.at(5))
            t.expectEqual(ignored.map(\.outcome), [.ignored, nil])
            let again = LampMasterLedger.resolve(ignored, id: shown[0].id, outcome: .accepted, now: F.at(6))
            t.expectEqual(again[0].outcome, .ignored)
            t.expectEqual(LampMasterLedger.open(again).map(\.suggestion.key), ["b"])
        },

        TestCase("The next frame hears about the last day, and the validator knows when each key showed") { t in
            let old = LampMasterLedger.entries(for: [suggestion("a")], at: F.at(-25 * 60))
            let new = LampMasterLedger.resolve(
                LampMasterLedger.entries(for: [suggestion("a"), suggestion("b")], at: F.at(-30)),
                id: "\(Int(F.at(-30).timeIntervalSince1970))-1", outcome: .wrong, now: F.at(-20))
            let recent = LampMasterLedger.recent(old + new, now: F.at(0))
            t.expectEqual(recent.map(\.key), ["a", "b"])
            t.expectEqual(recent.map(\.outcome), ["open", "wrong"])
            t.expectEqual(recent.first?.minutesAgo, 30)
            t.expectEqual(LampMasterLedger.shownAt(old + new)["a"], F.at(-30))
        },

        TestCase("Records go a line each and come back; a broken line costs only itself") { t in
            let round = LampMasterRound(at: F.at(0), trigger: .opened, outcome: .ran, model: "opus", seconds: 16.9,
                                        tokens: 7_112, costUSD: 0.079, sessions: 8, rejected: ["noEvidence": 1], shown: 2)
            let shown = LampMasterLedger.entries(for: [suggestion("a")], at: F.at(0))[0]
            guard let roundLine = LampMasterLedger.line(round), let shownLine = LampMasterLedger.line(shown) else {
                return t.expect(false, "both encode")
            }
            t.expect(!roundLine.contains("\n"), "one line")
            t.expectEqual(LampMasterLedger.records(roundLine + "\n{\"at\":\n" + roundLine, as: LampMasterRound.self), [round, round])
            t.expectEqual(LampMasterLedger.records(shownLine, as: LampMasterShown.self), [shown])
        },

        TestCase("The panel's line says why there is nothing, never a blank") { t in
            let time: (Date) -> String = { _ in "14:00" }
            let ran = LampMasterRound(at: F.at(0), trigger: .timer, outcome: .ran)
            t.expectEqual(LampMasterLine.text(open: 2, last: ran, running: false, time: time), "2 suggestions · round at 14:00")
            t.expectEqual(LampMasterLine.text(open: 1, last: ran, running: false, time: time), "1 suggestion · round at 14:00")
            t.expectEqual(LampMasterLine.text(open: 0, last: ran, running: false, time: time), "Nothing to report · round at 14:00")
            t.expectEqual(LampMasterLine.text(open: 3, last: ran, running: true, time: time), "LampMaster is looking…")
            t.expectEqual(LampMasterLine.text(open: 0, last: nil, running: false, time: time), "LampMaster · no round yet")
            let capped = LampMasterRound(at: F.at(0), trigger: .timer, outcome: .skipped, skip: .dailyCap)
            t.expectEqual(LampMasterLine.text(open: 0, last: capped, running: false, time: time), "Today's tokens spent · signals only")
            let failed = LampMasterRound(at: F.at(0), trigger: .timer, outcome: .failed, failure: .notLaunched)
            t.expectEqual(LampMasterLine.text(open: 0, last: failed, running: false, time: time),
                          "Last round failed: claude was not found")
        },

        TestCase("A card's button says what the click does; nothing to do, no button") { t in
            typealias A = S.Action
            t.expectEqual(LampMasterLine.button(A(kind: .ask, target: "bbbbbbbb", question: "Which port?")), "Copy question and open")
            t.expectEqual(LampMasterLine.button(A(kind: .ask, target: "bbbbbbbb")), "Open", "no question to copy")
            t.expectEqual(LampMasterLine.button(A(kind: .close)), "End session…")
            t.expectNil(LampMasterLine.button(A(kind: .none)))
            let aimed = S(kind: .cross, sessions: ["aaaaaaaa"], text: "t", evidence: "e",
                          action: A(kind: .ask, target: "bbbbbbbb"), confidence: 0.8, key: "k")
            t.expectEqual(LampMasterLine.subject(of: aimed), "bbbbbbbb", "the target before the first session")
            t.expectEqual(LampMasterLine.subject(of: suggestion("k")), "aaaaaaaa")
        },

        TestCase("Rejections are counted by reason") { t in
            let verdict = LampMasterValidator.Verdict(
                shown: [], rejected: [(suggestion("a"), .noEvidence), (suggestion("b"), .noEvidence), (suggestion("c"), .muted)])
            t.expectEqual(LampMasterLedger.rejections(verdict), ["noEvidence": 2, "muted": 1])
        },
    ])
}
