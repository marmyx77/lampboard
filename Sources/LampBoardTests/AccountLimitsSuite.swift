import LampBoardCore
import Foundation
import TestKit

enum AccountLimitsSuite {

    /// The answer as it really arrives, recorded on 20 September 2026. The named
    /// buckets and the ten unannounced ones are kept exactly as they came: the
    /// whole point of reading `limits` is that this noise must not matter.
    private static let recorded = Data("""
    {
      "five_hour": {"utilization": 9.0, "resets_at": "2026-09-20T11:39:59.991380+00:00"},
      "seven_day": {"utilization": 15.0, "resets_at": "2026-09-23T16:59:59.991399+00:00"},
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "amber_gauge": null, "cedar_ember": null, "cinder_cove": null,
      "copper_kite": null, "harbor_lantern": null, "iguana_necktie": null,
      "juniper_tide": null, "omelette_promotional": null, "amber_ladder": null,
      "nimbus_quill": {"utilization": 0.0, "resets_at": null},
      "limits": [
        {"kind": "session", "group": "session", "percent": 9, "severity": "normal",
         "resets_at": "2026-09-20T11:39:59.991380+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 15, "severity": "normal",
         "resets_at": "2026-09-23T16:59:59.991399+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 13, "severity": "normal",
         "resets_at": "2026-09-23T16:59:59.991580+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
         "is_active": false}
      ]
    }
    """.utf8)

    private static func decoded(_ json: String) -> AccountLimits? {
        AccountLimits.decode(Data(json.utf8))
    }

    static let suite = TestSuite("The account's allowance", [

        TestCase("The recorded answer yields three bars and nothing else") { t in
            guard let limits = AccountLimits.decode(recorded) else {
                return t.fail("the recorded answer did not decode")
            }
            t.expectEqual(limits.limits.count, 3, "bars")
            t.expectEqual(limits.limits.map(\.label), ["session", "week", "Fable"], "labels")
            t.expectEqual(limits.limits.map(\.percent), [9, 15, 13], "percentages")
        },

        // The ten unannounced buckets are the reason this reads `limits` at all.
        TestCase("The unannounced buckets are not drawn") { t in
            guard let limits = AccountLimits.decode(recorded) else {
                return t.fail("the recorded answer did not decode")
            }
            let labels = Set(limits.limits.map(\.label))
            for bucket in ["nimbus_quill", "amber_gauge", "juniper_tide", "cinder_cove"] {
                t.expect(!labels.contains(bucket), "a bucket reached the panel: \(bucket)")
            }
        },

        // The label is read, never written. Change the name in the answer and the
        // bar has to follow it, or a plan change leaves the panel naming a model
        // the account no longer has.
        TestCase("The scoped bar takes its name from the answer") { t in
            let limits = decoded("""
            {"limits": [{"kind": "weekly_scoped", "percent": 4, "resets_at": null,
             "scope": {"model": {"display_name": "Mythos"}}}]}
            """)
            t.expectEqual(limits?.limits.first?.label, "Mythos", "label")
        },

        TestCase("A scoped bar with nothing to name is dropped, not guessed") { t in
            let limits = decoded("""
            {"limits": [
              {"kind": "weekly_all", "percent": 5, "resets_at": null, "scope": null},
              {"kind": "weekly_scoped", "percent": 4, "resets_at": null, "scope": null}
            ]}
            """)
            t.expectEqual(limits?.limits.map(\.label), ["week"], "only the one that can be labelled")
        },

        TestCase("An answer with no limits is empty, not an error") { t in
            let limits = decoded(#"{"five_hour": {"utilization": 3}}"#)
            t.expectNotNil(limits, "decoded")
            t.expect(limits?.limits.isEmpty == true, "no bars invented")
        },

        TestCase("Something that is not an answer decodes to nothing") { t in
            t.expectNil(AccountLimits.decode(Data("not json".utf8)), "garbage")
            t.expectNil(AccountLimits.decode(Data("[1,2,3]".utf8)), "an array is not an answer")
        },

        // Claude Code's own on-disk copy nests the same object one level down.
        // Read too, so the two shapes can never disagree about what this understands.
        TestCase("The nested shape of the on-disk cache reads the same") { t in
            let limits = decoded("""
            {"fetchedAtMs": 1789832429867, "utilization":
              {"limits": [{"kind": "session", "percent": 42, "resets_at": null}]}}
            """)
            t.expectEqual(limits?.limits.first?.percent, 42, "percent")
            t.expectEqual(limits?.limits.first?.label, "session", "label")
        },

        TestCase("Both spellings of the reset time are read") { t in
            let withFraction = decoded("""
            {"limits": [{"kind": "session", "percent": 1,
             "resets_at": "2026-09-20T11:39:59.991380+00:00"}]}
            """)
            let without = decoded("""
            {"limits": [{"kind": "session", "percent": 1,
             "resets_at": "2026-09-23T17:00:00+00:00"}]}
            """)
            // One answer carried both, so a parser that knew one of them would drop
            // the reset time of a bar at random.
            t.expectNotNil(withFraction?.limits.first?.resetsAt, "with fractional seconds")
            t.expectNotNil(without?.limits.first?.resetsAt, "without")
        },

        TestCase("A percentage outside the bar is brought back into it") { t in
            let over = decoded(#"{"limits": [{"kind": "session", "percent": 140, "resets_at": null}]}"#)
            let under = decoded(#"{"limits": [{"kind": "session", "percent": -3, "resets_at": null}]}"#)
            t.expectEqual(over?.limits.first?.percent, 100, "above")
            t.expectEqual(under?.limits.first?.percent, 0, "below")
        },

        TestCase("A row with no percentage is not a bar") { t in
            let limits = decoded(#"{"limits": [{"kind": "session", "resets_at": null}]}"#)
            t.expect(limits?.limits.isEmpty == true, "a bar with no figure was drawn")
        },

        // MARK: - The borrowed credential

        TestCase("The access token is found in the shape Claude Code writes") { t in
            let blob = Data(#"{"claudeAiOauth":{"accessToken":"sk-tok","refreshToken":"r","expiresAt":1}}"#.utf8)
            t.expectEqual(ClaudeCredentials.accessToken(in: blob), "sk-tok", "nested")
            t.expectEqual(
                ClaudeCredentials.accessToken(in: Data(#"{"accessToken":"bare"}"#.utf8)),
                "bare", "a change of nesting still reads"
            )
        },

        TestCase("Anything without a usable token reads as none") { t in
            for payload in [#"{}"#, #"{"claudeAiOauth":{}}"#, #"{"claudeAiOauth":{"accessToken":""}}"#,
                            #"{"accessToken":123}"#, "not json"] {
                t.expectNil(ClaudeCredentials.accessToken(in: Data(payload.utf8)), payload)
            }
        },

        // MARK: - Whose allowance it is

        // The two configurations that actually exist here, recorded: an
        // organization account on this Mac and a personal one on the node most of
        // the work happens on, on a different plan. One unlabelled bar for the two
        // of them is the defect these cases exist to keep fixed.
        TestCase("The account is read from the configuration") { t in
            let account = ClaudeAccount.decode(Data(#"""
            {"oauthAccount": {"emailAddress": "editorial@aworld.org",
             "accountUuid": "99d4b700-e85a-4135-a4fd-c3b7ac021ec5",
             "organizationName": "AWorld"}}
            """#.utf8))
            t.expectEqual(account?.email, "editorial@aworld.org", "address")
            t.expectEqual(account?.uuid, "99d4b700-e85a-4135-a4fd-c3b7ac021ec5", "uuid")
        },

        TestCase("The uuid falls back to the cached block") { t in
            let account = ClaudeAccount.decode(
                Data(#"{"cachedUsageUtilization": {"accountUuid": "28fe240f"}}"#.utf8)
            )
            t.expectEqual(account?.uuid, "28fe240f", "uuid")
            t.expectNil(account?.email, "no address to give")
        },

        TestCase("A configuration naming nobody is no account at all") { t in
            for payload in [#"{}"#, #"{"oauthAccount": {}}"#,
                            #"{"oauthAccount": {"emailAddress": "  "}}"#, "not json"] {
                t.expectNil(ClaudeAccount.decode(Data(payload.utf8)), payload)
            }
        },

        TestCase("With no address the machine is the label") { t in
            let unnamed = ClaudeAccount(email: nil, uuid: "u")
            t.expectEqual(unnamed.label(fallback: "minisforum"), "minisforum", "fallback")
            t.expectEqual(
                ClaudeAccount(email: "a@b.c", uuid: "u").label(fallback: "minisforum"),
                "a@b.c", "the address wins"
            )
        },

        // MARK: - Two machines, one or two allowances

        TestCase("One account on two machines draws one group") { t in
            let shared = ClaudeAccount(email: "a@b.c", uuid: "same")
            let merged = AllowanceReport.merged([
                report(shared, "this Mac", 10), report(shared, "minisforum", 11),
            ])
            t.expectEqual(merged.count, 1, "groups")
            // The local one, whose age this app controls, not the remote reading.
            t.expectEqual(merged.first?.machine, "this Mac", "the kept reading")
        },

        TestCase("Two accounts draw two groups") { t in
            let merged = AllowanceReport.merged([
                report(ClaudeAccount(email: "editorial@aworld.org", uuid: "99d4"), "this Mac", 36),
                report(ClaudeAccount(email: "armellino@gmail.com", uuid: "28fe"), "minisforum", 4),
            ])
            t.expectEqual(merged.count, 2, "groups")
            t.expectEqual(merged.map(\.label), ["editorial@aworld.org", "armellino@gmail.com"], "labels")
        },

        // Hiding a second allowance is the worse failure of the two, so an account
        // that cannot prove which one it is keeps its own group.
        TestCase("An account that cannot identify itself is never merged away") { t in
            let merged = AllowanceReport.merged([
                report(ClaudeAccount(email: "a@b.c", uuid: nil), "this Mac", 10),
                report(ClaudeAccount(email: "a@b.c", uuid: nil), "minisforum", 11),
                report(nil, "third", 12),
            ])
            t.expectEqual(merged.count, 3, "nothing was collapsed on a guess")
        },
    ])

    /// A report with one bar, for the merge cases where the figures do not matter.
    private static func report(_ account: ClaudeAccount?, _ machine: String, _ percent: Int)
        -> AllowanceReport {
        AllowanceReport(
            account: account, machine: machine,
            limits: AccountLimits(
                limits: [AccountLimits.Limit(span: .session, percent: percent, resetsAt: nil)],
                readAt: Date()
            )
        )
    }
}
