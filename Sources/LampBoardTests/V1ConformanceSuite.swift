import LampBoardCore
import Foundation
import ProtocolConformance
import TestKit

/// The conformance battery against the reference source in memory (L0). The
/// same battery runs, unchanged, against any source a byte stream reaches.
enum V1ConformanceSuite {
    static let suite = V1Conformance.suite(against: V1MemoryTarget())
}

/// The written contract the battery holds sources to, shown to catch what it is
/// there for. A contract that cannot fail is a mirror.
enum V1ContractSuite {

    private static func row() -> [String: Any] {
        let bytes = (try? V1Codec.encoder().encode(V1Fixtures.row(1))) ?? Data()
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }

    private static func event(_ row: [String: Any]) -> [String: Any] {
        ["type": "event", "seq": 1, "at": "2026-10-15T20:00:00Z", "kind": "row", "row": row]
    }

    static let suite = TestSuite("v1 written contract", [

        TestCase("A row the Core writes keeps the contract") { t in
            t.expectEqual(V1WireContract.violations(of: event(row())), [], "no violation")
        },

        TestCase("A field renamed in a source is missing and unknown at once") { t in
            var renamed = row()
            renamed["ownedBy"] = renamed.removeValue(forKey: "owner")
            let found = V1WireContract.violations(of: event(renamed))
            t.expect(found.contains { $0.contains("missing \"owner\"") }, "the old name is missing: \(found)")
            t.expect(found.contains { $0.contains("unknown key \"ownedBy\"") }, "the new one is unknown: \(found)")
        },

        TestCase("An optional field renamed is caught too") { t in
            // Absent is allowed for an optional field, so the rename shows as the
            // key nobody declared.
            var renamed = row()
            renamed["cacheMins"] = renamed.removeValue(forKey: "cacheMinutes")
            t.expect(V1WireContract.violations(of: event(renamed)).contains { $0.contains("cacheMins") }, "caught")
        },

        TestCase("A boolean is not a number, and a number is not a boolean") { t in
            // On Linux `is Bool` accepts 0 and 1 (measured, D173).
            var wrong = row()
            wrong["hidden"] = 0
            wrong["activeSubagents"] = true
            let found = V1WireContract.violations(of: event(wrong))
            t.expect(found.contains { $0.contains("hidden") }, "0 is not false")
            t.expect(found.contains { $0.contains("activeSubagents") }, "true is not 1")
        },

        TestCase("A date that is not ISO 8601 is off contract") { t in
            var wrong = row()
            wrong["updatedAt"] = 1_760_000_000
            t.expect(V1WireContract.violations(of: event(wrong)).contains { $0.contains("updatedAt") }, "a number for a time")
        },

        TestCase("A status or an error code outside the list is off contract") { t in
            var wrong = row()
            wrong["status"] = "thinking"
            t.expect(!V1WireContract.violations(of: event(wrong)).isEmpty, "thinking is not a status")
            t.expect(!V1WireContract.violations(of: ["type": "error", "code": "oops", "message": "m"]).isEmpty, "oops is not a code")
        },
    ])
}
