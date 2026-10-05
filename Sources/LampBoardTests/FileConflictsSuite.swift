import LampBoardCore
import Foundation
import TestKit

/// The row's ⚠ (UX §4, R3a): two live sessions that wrote the same file of the
/// same checkout in the last two hours, from what their mods reported.
enum FileConflictsSuite {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func log(_ writes: [(String, String, Double)]) -> SessionActivity {
        var log = SessionActivity()
        for (index, (tool, detail, minutesAgo)) in writes.enumerated() {
            log.toolStarted(id: "c\(index)", tool: tool, detail: detail, at: now.addingTimeInterval(-minutesAgo * 60))
        }
        return log
    }

    static let suite = TestSuite("Two sessions on the same file", [

        TestCase("The same file of the same checkout, both live, within two hours: each names the other") { t in
            let found = FileConflicts.find([
                "a": log([("Edit", "/home/dev/api/src/routes.ts", 10)]),
                "b": log([("Write", "/home/dev/api/src/routes.ts", 30), ("Edit", "/home/dev/api/README.md", 5)]),
                "c": log([("Edit", "/home/dev/api/README.md", 1)]),
            ], live: ["a", "b", "c"], now: now)
            t.expectEqual(found["a"], [FileConflicts.Conflict(file: "/home/dev/api/src/routes.ts", with: "b")])
            t.expectEqual(found["b"]?.map(\.with), ["a", "c"], "routes.ts with a, README.md with c")
            t.expectEqual(found["c"]?.map(\.file), ["/home/dev/api/README.md"])
        },

        TestCase("Reading is not writing; an old write, a closed session or another checkout is no conflict") { t in
            let found = FileConflicts.find([
                "a": log([("Read", "/home/dev/api/src/routes.ts", 1), ("Bash", "npm test", 1)]),
                "b": log([("Edit", "/home/dev/api/src/routes.ts", 1)]),
                "c": log([("Edit", "/home/dev/api/src/routes.ts", 180)]),
                "d": log([("Edit", "/home/dev/api/src/routes.ts", 1)]),
                "e": log([("Edit", "/home/dev/api-wt/src/routes.ts", 1)]),
                "f": log([("Edit", "src/routes.ts", 1)]),
            ], live: ["a", "b", "c", "e", "f"], now: now)
            t.expect(found.isEmpty, "nothing here is two sessions writing one file: \(found)")
        },
    ])
}
