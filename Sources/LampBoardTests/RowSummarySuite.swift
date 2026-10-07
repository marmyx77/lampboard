import LampBoardCore
import Foundation
import TestKit

/// What a row says about itself when you rest the pointer on it.
///
/// This used to be a `private var` on a SwiftUI view, assembled by appending
/// strings — untouchable by any test here, and, as it turned out, never once
/// displayed on a screen. Now it is a value, and these are the rules it follows.
enum RowSummarySuite {

    /// A fixed calendar: the labels must not depend on the machine's time zone.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private static func moment(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 7, day: day, hour: hour, minute: minute
        )) ?? Date(timeIntervalSince1970: 0)
    }

    private static let now = moment(29, 16, 0)

    private static func session(
        _ id: String = "s1",
        _ status: SessionStatus = .ready,
        path: String = "/dev/billing-gateway",
        host: String? = nil,
        at: Date = moment(29, 15, 16),
        waitingOn: [String] = [],
        subagents: Int = 0,
        context: ContextReading? = nil,
        message: String? = nil,
        failure: StopFailureReason? = nil,
        title: String? = nil
    ) -> SessionState {
        SessionState(
            id: id,
            status: status,
            workspace: Workspace(path: path, host: host),
            lastMessage: message,
            updatedAt: at,
            statusSince: at,
            failureReason: failure,
            activeAgentIds: Set((0..<subagents).map { "agent-\($0)" }),
            waitingOn: waitingOn,
            title: title,
            context: context
        )
    }

    private static func row(
        _ sessions: [SessionState], slot: Int? = nil, alias: String? = nil
    ) -> ColumnRow {
        ColumnRow(
            id: sessions[0].workspace.path, workspace: sessions[0].workspace,
            sessions: sessions, slot: slot, alias: alias
        )
    }

    private static func summary(_ row: ColumnRow, muted: Bool = false) -> RowSummary {
        RowSummary.of(row, now: now, muted: muted, calendar: calendar)
    }

    private static func value(_ summary: RowSummary, _ label: String) -> String? {
        summary.fields.first { $0.label == label }?.value
    }

    private static func detail(_ summary: RowSummary, _ label: String) -> String? {
        summary.fields.first { $0.label == label }?.detail
    }

    private static let full = ContextReading(
        tokens: 860_960, model: "claude-opus-5", window: 1_000_000, confidence: .exact, at: nil
    )

    static let suite = TestSuite("What a row says about itself", [

        TestCase("The state is the header, not a field") { t in
            let s = summary(row([session()]))
            t.expectEqual(s.title, "billing-gateway", "the name")
            t.expectEqual(s.status, .ready, "and the state travels beside it")
            t.expect(!s.fields.contains { $0.label == "state" }, "never as a row of the grid")
        },

        TestCase("The machine and the folder go under the name") { t in
            // A row on another machine, renamed: both facts, and nowhere else on
            // screen do either of them appear.
            let remote = row([session(host: "devmachine")], alias: "Invoicing")
            t.expectEqual(summary(remote).title, "Invoicing", "the name the user chose")
            t.expectEqual(
                summary(remote).subtitle, "on devmachine · in billing-gateway",
                "where it is, and what it really is"
            )
        },

        TestCase("With no name of its own the folder is not repeated") { t in
            // The title already is the folder: a second line saying it again is a
            // line that says nothing.
            t.expectNil(summary(row([session()])).subtitle, "nothing to add")
        },

        TestCase("The context carries the figure, the tokens and the shape") { t in
            let s = summary(row([session(context: full)]))
            t.expectEqual(value(s, "context"), "86%", "the figure as the row shows it")
            t.expectEqual(detail(s, "context"), "\(860_960.formatted()) of \((1_000_000).formatted())",
                          "the tokens behind it")
            t.expectEqual(s.fields.first { $0.label == "context" }?.fill, 0.86096, "and the arc")
            t.expectEqual(value(s, "model"), "claude-opus-5", "the model of that same reply")
        },

        TestCase("A session nobody has read yet says so, and does not go blank") { t in
            let s = summary(row([session()]))
            t.expectEqual(value(s, "context"), "—", "the dash, never an empty cell")
            t.expect(detail(s, "context")?.contains("nothing read") == true, "and it says why")
            t.expectNil(value(s, "model"), "no reading, no model")
        },

        TestCase("A void reading does not print its tokens") { t in
            // `— 412,117 of 1,000,000` reads as a figure with a typo in front of
            // it. It is not a figure: the session was compacted after that reply.
            let gone = ContextReading(
                tokens: 412_117, model: "claude-fable-5", window: 1_000_000,
                confidence: .unknown, at: nil
            )
            let s = summary(row([session(context: gone)]))
            t.expectEqual(value(s, "context"), "—", "the dash")
            t.expectEqual(detail(s, "context"), "the session was compacted since that reading", "and why")
            t.expectNil(s.fields.first { $0.label == "context" }?.fill, "and no bar to read it by")
        },

        TestCase("A floor stays a floor here too") { t in
            let floor = ContextReading(
                tokens: 860_960, model: "claude-opus-5", window: 1_000_000,
                confidence: .floor, at: nil
            )
            t.expectEqual(value(summary(row([session(context: floor)])), "context"), "≥86%", "the ≥")
        },

        TestCase("What is holding a row is named, and counted") { t in
            let blue = row([session("s1", .waiting, waitingOn: ["monitor", "monitor", "shell"])])
            t.expectEqual(value(summary(blue), "waiting on"), "monitor ×2, shell", "counted, in order")

            // The same list under a different word: on a row that is not blue
            // these are ears left open, not something the turn is waiting for.
            let green = row([session("s1", .ready, waitingOn: ["monitor"])])
            t.expectEqual(value(summary(green), "listening"), "monitor", "an ear, not a wait")
        },

        TestCase("A group says how many, and what each one is doing") { t in
            let group = row([
                session("a", .awaiting), session("b", .ready), session("c", .idle),
            ])
            t.expectEqual(value(summary(group), "sessions"), "3 in this project", "the count")
            t.expectEqual(
                summary(group).sessions,
                ["#1 · needs you", "#2 · done", "#3 · resting"],
                "each one named, in the order they were opened"
            )
        },

        TestCase("A session that has a title is listed by it, not by its number") { t in
            // Three states with nothing attached to them was a list you could
            // read and not use: it said something in this project is waiting,
            // and left you to guess which of three conversations it was.
            let group = row([
                session("a", .awaiting, title: "Fix the parser"),
                session("b", .working, title: "Write the release notes"),
            ])
            t.expectEqual(
                summary(group).sessions,
                ["Fix the parser · needs you",
                 "Write the release notes · working"],
                "the conversation, then what it is doing"
            )
        },

        TestCase("A single session gets no list of one") { t in
            t.expect(summary(row([session()])).sessions.isEmpty, "nothing to enumerate")
        },

        TestCase("The slot moved here when the ring took its cell") { t in
            let s = summary(row([session()], slot: 7))
            t.expectEqual(value(s, "slot"), "7", "the number")
            t.expectEqual(detail(s, "slot"), "lampboard open 7", "and the command it stands for")
        },

        TestCase("An interrupted turn says what ended it, and marks the text as an error") { t in
            let dead = row([session("s1", .failed, message: "rate limit exceeded", failure: .rateLimit)])
            t.expectEqual(value(summary(dead), "ended"), "request limit reached", "the reason")
            t.expect(summary(dead).messageIsError, "and the message is not something Claude wrote for you")
        },

        TestCase("The help line promises only what this row can do") { t in
            // A modifier that does nothing when pressed is worse than one nobody
            // knows about.
            let here = summary(row([session()]))
            t.expect(here.keys.contains("⇧ folder"), "a local row can be revealed")

            let elsewhere = summary(row([session(host: "devmachine")]))
            t.expect(!elsewhere.keys.contains("folder"),
                     "a folder on another machine is not a folder here")

            // The handle is drawn on every row: naming it here would push the
            // figure people came for onto a second line.
            t.expect(!here.keys.contains("drag"), "what you can see needs no caption")
        },

        TestCase("Muting is a standing condition, not something that happened") { t in
            t.expectEqual(summary(row([session()]), muted: true).notice,
                          "Alerts are off for this project.", "said once, quietly")
            t.expectNil(summary(row([session()])).notice, "and not at all when it is not true")
        },

        TestCase("The moment is a value, not a sentence") { t in
            // The row says `1d`; this says which day. The two are the pair that
            // let the row get short enough to give the name back its width.
            t.expectEqual(value(summary(row([session(at: moment(29, 14, 49))])), "activity"),
                          "14:49", "today")
            t.expectEqual(value(summary(row([session(at: moment(28, 22, 30))])), "activity"),
                          "yesterday, 22:30", "the day before")
            t.expectEqual(value(summary(row([session(at: moment(22, 9, 5))])), "activity"),
                          "22/07, 09:05", "and further back")
        },
    ])
}
