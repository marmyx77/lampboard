import Foundation

/// The `v1` wire, written down once, by hand, apart from the code that writes it.
///
/// This is what makes the conformance suite a contract and not a mirror: it does
/// not ask the Core's types what a message looks like, it holds every source to
/// this list. A field renamed in a source's encoder is a required key missing
/// and an unknown key present, both reported. Adding a field means adding it
/// here, on purpose, where a reviewer sees it.
public enum V1WireContract {

    public enum Kind: Equatable {
        case string, int, number, bool, object, array, null
        /// An ISO 8601 time, as a string.
        case date
    }

    public struct Field {
        public let name: String
        public let kinds: [Kind]
        public let required: Bool

        init(_ name: String, _ kinds: [Kind], required: Bool = true) {
            self.name = name
            self.kinds = kinds
            self.required = required
        }
    }

    private static func req(_ name: String, _ kinds: Kind...) -> Field { Field(name, kinds) }
    private static func opt(_ name: String, _ kinds: Kind...) -> Field { Field(name, kinds, required: false) }

    /// Every reply carries these.
    static let envelope = [req("type", .string), opt("re", .int)]

    public static let replies: [String: [Field]] = [
        "hello": [
            req("protocol", .int), req("minClient", .int), req("version", .string), req("source", .object),
            req("startedAt", .date), opt("binaryModifiedAt", .date), opt("configModifiedAt", .date),
            req("stateAge", .object), opt("relay", .object), req("role", .string),
        ],
        "state": [
            req("journal", .string), req("seq", .int), req("source", .object), req("rows", .array, .null),
            opt("rowsAt", .date), req("at", .date),
        ],
        "events": [
            req("journal", .string), opt("since", .int), req("replayed", .int), req("resync", .bool),
            req("ping", .number),
        ],
        "event": [req("seq", .int), req("at", .date), req("kind", .string), opt("row", .object), opt("id", .string)],
        "ping": [req("seq", .int), req("at", .date)],
        "transcript": [req("session", .string), req("messages", .array), req("notSent", .int)],
        "result": [req("op", .string)],
        "devices": [req("devices", .array)],
        "error": [req("code", .string), req("message", .string)],
        "bye": [req("reason", .string)],
    ]

    static let source = [req("kind", .string), req("name", .string)]
    static let stateAge = [req("seq", .int), opt("lastEventAt", .date), opt("lastProbeAt", .date), opt("seconds", .number)]
    static let relay = [req("outcome", .string), req("at", .date)]
    static let message = [req("role", .string), req("text", .string), opt("at", .date)]
    static let device = [req("id", .string), req("name", .string), req("pairedAt", .date), opt("lastSeenAt", .date)]

    /// A row: the read endpoint's snapshot and the `v1` fields, flat.
    public static let row: [Field] = [
        req("id", .string), req("status", .string), req("workspace", .string), req("path", .string),
        req("updatedAt", .date), req("statusSince", .date), req("activeSubagents", .int), req("harness", .string),
        opt("pendingAsk", .string), req("waitingOn", .array), opt("contextPercent", .int), opt("contextTokens", .int),
        opt("contextWindow", .int), opt("contextModel", .string), opt("contextConfidence", .string),
        opt("costUSD", .number), opt("failureReason", .string), opt("lastMessage", .string), req("muted", .bool),
        opt("slot", .int), opt("transcriptPath", .string), opt("git", .object), opt("host", .string),
        opt("entrypoint", .string), req("origin", .string), opt("title", .string), opt("jobId", .string),
        opt("summary", .string), opt("needs", .string), opt("unreadAnswers", .int), req("label", .string),
        req("source", .object), req("owner", .string),
        opt("cacheMinutes", .int), opt("stuckSince", .date), opt("runningTool", .string), opt("fileConflict", .string),
        req("hidden", .bool), req("folded", .bool), opt("order", .int), opt("readAt", .date),
        opt("hostProbedAt", .date), opt("hostReachable", .bool), opt("terminal", .string),
        opt("bridgeSessionId", .string), opt("permissionMode", .string), req("heldByMac", .bool),
    ]

    public static let statuses: Set<String> = ["idle", "working", "waiting", "ready", "blocked", "failed"]
    public static let errorCodes: Set<String> = [
        "malformed", "unknownOp", "badRequest", "helloFirst", "clientTooOld", "forbidden", "notFound", "badFrame", "unavailable",
    ]

    // MARK: - Checking

    /// Every way `message` departs from the contract, as sentences; empty when it
    /// conforms. Nested objects — rows, sources, ages — are checked too.
    public static func violations(of message: [String: Any]) -> [String] {
        guard let type = message["type"] as? String else { return ["a reply with no type"] }
        guard let fields = replies[type] else { return ["a reply of unknown type \(type)"] }
        var found = check(message, against: envelope + fields, at: type)
        switch type {
        case "hello":
            found += nested(message["source"], source, at: "hello.source")
            found += nested(message["stateAge"], stateAge, at: "hello.stateAge")
            if message["relay"] != nil { found += nested(message["relay"], relay, at: "hello.relay") }
            if let role = message["role"] as? String, !["read", "action"].contains(role) { found.append("hello.role \(role)") }
        case "state":
            found += nested(message["source"], source, at: "state.source")
            for (n, row) in ((message["rows"] as? [Any]) ?? []).enumerated() { found += rowViolations(row, at: "state.rows[\(n)]") }
        case "event":
            switch message["kind"] as? String {
            case "row": found += rowViolations(message["row"] as Any, at: "event.row")
            case "gone": if message["id"] as? String == nil { found.append("event of kind gone without id") }
            default: found.append("event of unknown kind \(String(describing: message["kind"]))")
            }
        case "transcript":
            for (n, item) in ((message["messages"] as? [Any]) ?? []).enumerated() {
                found += nested(item, self.message, at: "transcript.messages[\(n)]")
            }
        case "devices":
            for (n, item) in ((message["devices"] as? [Any]) ?? []).enumerated() { found += nested(item, device, at: "devices[\(n)]") }
        case "error":
            if let code = message["code"] as? String, !errorCodes.contains(code) { found.append("error code \(code) is not in the contract") }
        default:
            break
        }
        return found
    }

    static func rowViolations(_ value: Any, at path: String) -> [String] {
        guard let row = value as? [String: Any] else { return ["\(path) is not an object"] }
        var found = check(row, against: self.row, at: path) + nested(row["source"], source, at: "\(path).source")
        if let status = row["status"] as? String, !statuses.contains(status) { found.append("\(path).status \(status)") }
        if let kind = (row["source"] as? [String: Any])?["kind"] as? String, !["mac", "node"].contains(kind) {
            found.append("\(path).source.kind \(kind)")
        }
        return found
    }

    private static func nested(_ value: Any?, _ fields: [Field], at path: String) -> [String] {
        guard let object = value as? [String: Any] else { return ["\(path) is not an object"] }
        return check(object, against: fields, at: path)
    }

    private static func check(_ object: [String: Any], against fields: [Field], at path: String) -> [String] {
        var found: [String] = []
        let known = Set(fields.map(\.name))
        for field in fields {
            guard let value = object[field.name] else {
                if field.required { found.append("\(path): missing \"\(field.name)\"") }
                continue
            }
            if !field.kinds.contains(where: { matches(value, $0) }) {
                found.append("\(path).\(field.name): not \(field.kinds.map { "\($0)" }.joined(separator: " or "))")
            }
        }
        for key in object.keys.sorted() where !known.contains(key) {
            found.append("\(path): unknown key \"\(key)\"")
        }
        return found
    }

    /// The JSON kind of a value from `JSONSerialization`. A boolean decodes to a
    /// class of its own on the Mac and on Linux alike; `is Bool` cannot tell it
    /// from 0 and 1.
    static func matches(_ value: Any, _ kind: Kind) -> Bool {
        let isBool = (value as? NSNumber).map { type(of: $0) == type(of: NSNumber(value: true)) } ?? false
        switch kind {
        case .null: return value is NSNull
        case .bool: return isBool
        case .string: return value is String
        case .date: return (value as? String).flatMap(ISO8601DateFormatter().date(from:)) != nil
        case .object: return value is [String: Any]
        case .array: return value is [Any]
        case .number: return !isBool && value is NSNumber && (value as? NSNumber)?.doubleValue.isFinite == true
        case .int:
            guard !isBool, let number = value as? NSNumber else { return false }
            return Double(Int64(exactly: number.doubleValue) ?? Int64.min) == number.doubleValue
        }
    }
}
