import LampBoardCore
import Foundation
import TestKit

/// Which limit each account's line shows, what the line is called, and when there
/// is no line at all (U1).
enum AllowanceLinesSuite {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func report(_ email: String?, _ limits: [AccountLimits.Limit], machine: String = "this Mac") -> AllowanceReport {
        AllowanceReport(account: email.map { ClaudeAccount(email: $0, uuid: nil) }, machine: machine,
                        limits: AccountLimits(limits: limits, readAt: now))
    }

    static let soon = now.addingTimeInterval(3_600)

    static let suite = TestSuite("Allowance lines", [

        TestCase("The session window takes the line, unless another limit is spent") { t in
            let ordinary = report("design@example.com", [
                .init(span: .session, percent: 40, resetsAt: soon), .init(span: .week, percent: 80, resetsAt: soon),
            ])
            t.expectEqual(AllowanceLines.shown(in: ordinary)?.span, .session)
            let spentWeek = report("design@example.com", [
                .init(span: .session, percent: 40, resetsAt: soon), .init(span: .week, percent: 94, resetsAt: soon),
            ])
            t.expectEqual(AllowanceLines.shown(in: spentWeek)?.span, .week, "a spent week is the binding limit")
        },

        TestCase("A window that has not started has no line: no «0% —»") { t in
            let unstarted = report("sam@example.net", [
                .init(span: .session, percent: 0, resetsAt: nil), .init(span: .week, percent: 12, resetsAt: soon),
            ])
            t.expectNil(AllowanceLines.shown(in: unstarted))
            let started = report("sam@example.net", [.init(span: .session, percent: 0, resetsAt: soon)])
            t.expectEqual(AllowanceLines.shown(in: started)?.percent, 0, "at zero but counting down is a line")
            let spentAnyway = report("sam@example.net", [
                .init(span: .session, percent: 0, resetsAt: nil), .init(span: .week, percent: 97, resetsAt: soon),
            ])
            t.expectEqual(AllowanceLines.shown(in: spentAnyway)?.span, .week, "a spent week still stops the work")
        },

        TestCase("Without a session window, the fullest limit") { t in
            let weekOnly = report("design@example.com", [
                .init(span: .week, percent: 30, resetsAt: soon), .init(span: .weekForModel("Fable"), percent: 50, resetsAt: soon),
            ])
            t.expectEqual(AllowanceLines.shown(in: weekOnly)?.percent, 50)
        },

        TestCase("Names: the part before the @, unless two accounts share it") { t in
            t.expectEqual(AllowanceLines.names(for: ["design@example.com", "sam@example.net"]),
                          ["design", "sam"])
            t.expectEqual(AllowanceLines.names(for: ["sam@example.com", "sam@example.net"]),
                          ["example.com", "example.net"], "the domain is what differs")
            t.expectEqual(AllowanceLines.names(for: ["sam@example.com", "sam@example.com"]),
                          ["sam@example.com", "sam@example.com"], "nothing shorter tells them apart")
            t.expectEqual(AllowanceLines.names(for: ["buildbox", "design@example.com"]),
                          ["buildbox", "design"], "a machine is named whole")
        },
    ])
}
