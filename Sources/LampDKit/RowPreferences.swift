import Foundation
import LampBoardCore

/// The person's choices about the rows of this machine (§2.12): a name, mute,
/// hidden, the place in the column, when the last answer was read, and
/// "take it off" — kept by `lampd`, written by the phone (`cmd`) and, from the
/// Mac 2.4, by the Mac.
///
/// Every value carries the time it was set. The Mac 2.4 merges its own copy
/// into this one once (W5), field by field, and the one written last wins with
/// its date; at a tie, this one. Without the dates that merge would have to
/// guess, and what the person did from the phone would be lost or done twice.
public struct RowPreferences: Equatable, Sendable {

    public struct Stamped<Value: Equatable & Sendable>: Equatable, Sendable {
        public let value: Value
        public let at: Date
        public init(_ value: Value, at: Date) {
            self.value = value
            self.at = at
        }
    }

    public struct Row: Equatable, Sendable {
        public var label: Stamped<String>?
        public var muted: Stamped<Bool>?
        public var hidden: Stamped<Bool>?
        public var order: Stamped<Int>?
        /// `nil` inside: marked unread.
        public var readAt: Stamped<Date?>?
        /// When the row was taken off. It comes back when its session speaks
        /// after that: a file read again and again would otherwise bring it
        /// back at the next look, and never would be wrong for a session that
        /// has something new to say.
        public var dismissedAt: Stamped<Date>?

        public init() {}

        public var isEmpty: Bool {
            label == nil && muted == nil && hidden == nil && order == nil && readAt == nil && dismissedAt == nil
        }
    }

    public private(set) var rows: [String: Row] = [:]

    public init(rows: [String: Row] = [:]) {
        self.rows = rows
    }

    public func row(_ id: String) -> Row { rows[id] ?? Row() }

    /// What a low-power action changes, already validated by `V1Service`.
    /// `focus` and `calmBlink` change no row: the first says which device is in
    /// use, the second how the panel draws a blink.
    public mutating func apply(_ command: V1Command, at now: Date) {
        switch command.action {
        case .order:
            for (place, id) in (command.ids ?? []).enumerated() { rows[id, default: Row()].order = Stamped(place, at: now) }
            return
        case .focus, .calmBlink:
            return
        default:
            break
        }
        guard let id = command.session else { return }
        var row = rows[id] ?? Row()
        switch command.action {
        case .markSeen: row.readAt = Stamped(now, at: now)
        case .markUnread: row.readAt = Stamped(nil, at: now)
        case .rename: row.label = Stamped(command.name ?? "", at: now)
        case .hide: row.hidden = Stamped(command.on ?? true, at: now)
        case .mute: row.muted = Stamped(command.on ?? true, at: now)
        case .dismiss: row.dismissedAt = Stamped(now, at: now)
        case .order, .focus, .calmBlink: break
        }
        rows[id] = row
    }

    /// `row` as the person left it, or `nil` for a row taken off that has not
    /// spoken since.
    public func applied(to row: V1Row) -> V1Row? {
        guard let choices = rows[row.id] else { return row }
        if let dismissed = choices.dismissedAt, row.session.updatedAt <= dismissed.value { return nil }
        var extras = row.extras
        if let hidden = choices.hidden { extras.hidden = hidden.value }
        if let order = choices.order { extras.order = order.value }
        if let read = choices.readAt { extras.readAt = read.value }
        let label = choices.label.map { $0.value.isEmpty ? row.session.workspace : $0.value }
        let session = row.session.with(label: label, muted: choices.muted?.value)
        return V1Row(session: session, source: row.source, owner: row.owner, extras: extras)
    }

    /// Choices about rows that have not been seen for `age`: a session gone for
    /// good leaves nothing behind for ever.
    public mutating func forget(besides live: Set<String>, olderThan age: TimeInterval, at now: Date) {
        rows = rows.filter { id, row in
            if live.contains(id) { return true }
            let newest = [row.label?.at, row.muted?.at, row.hidden?.at, row.order?.at, row.readAt?.at, row.dismissedAt?.at]
                .compactMap { $0 }.max() ?? .distantPast
            return now.timeIntervalSince(newest) < age
        }
    }
}

// MARK: - On disk

extension RowPreferences {

    /// The file's shape: `{"version": 1, "rows": {"<id>": {"label": {"value": …, "at": …}, …}}}`.
    public func encoded() throws -> Data {
        var out: [String: Any] = [:]
        for (id, row) in rows where !row.isEmpty {
            var fields: [String: Any] = [:]
            func put<V>(_ key: String, _ stamped: Stamped<V>?, _ value: (V) -> Any) {
                guard let stamped else { return }
                fields[key] = ["value": value(stamped.value), "at": Self.time(stamped.at)]
            }
            put("label", row.label) { $0 }
            put("muted", row.muted) { $0 }
            put("hidden", row.hidden) { $0 }
            put("order", row.order) { $0 }
            put("readAt", row.readAt) { read -> Any in read.map { Self.time($0) as Any } ?? NSNull() }
            put("dismissedAt", row.dismissedAt) { Self.time($0) }
            out[id] = fields
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "rows": out], options: [.sortedKeys])
    }

    /// What `data` holds; an unreadable field is dropped, never the file.
    public static func decode(_ data: Data) -> RowPreferences {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["rows"] as? [String: Any] else { return RowPreferences() }
        var out: [String: Row] = [:]
        for (id, value) in rows {
            guard V1Validation.isSessionId(id), let fields = value as? [String: Any] else { continue }
            func stamp(_ key: String) -> (Any, Date)? {
                guard let field = fields[key] as? [String: Any], let at = (field["at"] as? String).flatMap(date),
                      let value = field["value"] else { return nil }
                return (value, at)
            }
            var row = Row()
            if let (v, at) = stamp("label"), let text = v as? String { row.label = Stamped(text, at: at) }
            if let (v, at) = stamp("muted"), let flag = v as? Bool { row.muted = Stamped(flag, at: at) }
            if let (v, at) = stamp("hidden"), let flag = v as? Bool { row.hidden = Stamped(flag, at: at) }
            if let (v, at) = stamp("order"), let place = (v as? NSNumber)?.intValue { row.order = Stamped(place, at: at) }
            if let (v, at) = stamp("readAt") {
                if v is NSNull { row.readAt = Stamped(nil, at: at) } else if let read = (v as? String).flatMap(date) {
                    row.readAt = Stamped(read, at: at)
                }
            }
            if let (v, at) = stamp("dismissedAt"), let gone = (v as? String).flatMap(date) { row.dismissedAt = Stamped(gone, at: at) }
            if !row.isEmpty { out[id] = row }
        }
        return RowPreferences(rows: out)
    }

    static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// The preferences file, read and written under a lock: the service and a
/// forced command reading files may both write it.
public struct PreferencesFile: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    public func load() -> RowPreferences {
        guard let data = FileManager.default.contents(atPath: path) else { return RowPreferences() }
        return RowPreferences.decode(data)
    }

    /// Reads the file again under the lock, applies `change`, writes it back,
    /// and returns what was written.
    @discardableResult
    public func update(_ change: (inout RowPreferences) -> Void) throws -> RowPreferences {
        try FileLock.with(path + ".lock") {
            var preferences = load()
            change(&preferences)
            try AtomicFile.write(try preferences.encoded(), to: path)
            return preferences
        }
    }
}
