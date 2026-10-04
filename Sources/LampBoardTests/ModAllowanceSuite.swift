import LampBoardCore
import Foundation
import TestKit

/// This Mac's allowance strip with the mod's windows in it (D67).
enum ModAllowanceSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let account = ClaudeAccount(email: "design@example.com", uuid: "acc-1")

    private static func service(at: Date) -> AllowanceReport {
        AllowanceReport(account: account, machine: "this Mac", limits: AccountLimits(limits: [
            .init(span: .session, percent: 10, resetsAt: nil),
            .init(span: .week, percent: 40, resetsAt: nil),
            .init(span: .weekForModel("Fable"), percent: 55, resetsAt: nil),
        ], readAt: at))
    }

    private static let windows: [ModReport.RateLimit] = [
        .init(kind: "five_hour", percent: 20, resetsAt: nil),
        .init(kind: "seven_day", percent: 67, resetsAt: nil),
        .init(kind: "spend_limit", percent: 5, resetsAt: nil),
    ]

    static let suite = TestSuite("The allowance with the mod's windows", [

        TestCase("Fresher windows from the mod replace session and week, and keep the model's cap") { t in
            let merged = ModAllowance.merged([service(at: t0)], mod: (windows, t0.addingTimeInterval(60)), machine: "this Mac")
            t.expectEqual(merged.count, 1)
            t.expectEqual(merged.first?.account, account, "the service still names the account")
            t.expectEqual(merged.first?.limits.limits.map(\.percent), [20, 67, 55])
            t.expectEqual(merged.first?.limits.readAt, t0.addingTimeInterval(60))
        },

        TestCase("An older reading from the mod changes nothing") { t in
            let merged = ModAllowance.merged([service(at: t0)], mod: (windows, t0.addingTimeInterval(-60)), machine: "this Mac")
            t.expectEqual(merged, [service(at: t0)])
        },

        // The service's switch is off, or its borrowed token has aged out: the
        // session's own figures still draw the bars.
        TestCase("With nothing from the service, the mod's bars stand alone, labelled by the machine") { t in
            let remote = AllowanceReport(account: nil, machine: "buildbox", limits: AccountLimits(limits: [], readAt: t0))
            let merged = ModAllowance.merged([remote], mod: (windows, t0), machine: "this Mac")
            t.expectEqual(merged.map(\.machine), ["this Mac", "buildbox"])
            t.expectNil(merged.first?.account)
            t.expectEqual(merged.first?.limits.limits.map(\.label), ["session", "week"], "a spend limit has no bar here")
        },

        TestCase("Without the mod, or with no window it can draw, the strip is the service's") { t in
            t.expectEqual(ModAllowance.merged([service(at: t0)], mod: nil, machine: "this Mac"), [service(at: t0)])
            let odd = [ModReport.RateLimit(kind: "spend_limit", percent: 5, resetsAt: nil)]
            t.expectEqual(ModAllowance.merged([], mod: (odd, t0), machine: "this Mac"), [])
        },
    ])
}
