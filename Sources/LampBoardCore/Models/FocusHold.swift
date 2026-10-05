import Foundation

/// One session in the foreground (§5.3, G1). While it is, the notifications of
/// every other session wait; when the focus is taken off they come back in one
/// line, the most urgent first. The panel's colours are untouched: a row still
/// turns amber, it just does not interrupt.
public struct FocusHold: Sendable, Equatable {

    public struct Held: Sendable, Equatable {
        public let event: NotificationText.Event
        public let sessionId: String
        public let name: String
    }

    public let focused: String?
    public let held: [Held]

    public init(focused: String? = nil, held: [Held] = []) {
        self.focused = focused
        self.held = held
    }

    /// Whether a notification for `sessionId` may go out now.
    public func admits(_ sessionId: String) -> Bool {
        focused == nil || focused == sessionId
    }

    /// Kept for the summary: once per session and kind, the newest name winning.
    public func holding(_ event: NotificationText.Event, sessionId: String, name: String) -> FocusHold {
        guard !admits(sessionId) else { return self }
        let others = held.filter { !($0.sessionId == sessionId && $0.event == event) }
        return FocusHold(focused: focused, held: others + [Held(event: event, sessionId: sessionId, name: name)])
    }

    public func released() -> FocusHold { FocusHold() }

    /// Only what is still true: a session answered or gone since it was held is
    /// not news when the focus comes off.
    public func keeping(_ keep: (Held) -> Bool) -> FocusHold {
        FocusHold(focused: focused, held: held.filter(keep))
    }

    /// What waited, in one line, or `nil` when nothing did.
    public func summary() -> String? {
        let order: [(NotificationText.Event, String, String)] = [
            (.waiting, "waiting for you", "waiting for you"),
            (.failed, "failed", "failed"),
            (.finished, "answer", "answers"),
        ]
        let parts = order.compactMap { event, one, many -> String? in
            let names = held.filter { $0.event == event }.map(\.name)
            guard !names.isEmpty else { return nil }
            return "\(names.count) \(names.count == 1 ? one : many) (\(names.joined(separator: ", ")))"
        }
        return parts.isEmpty ? nil : "While you were focused: " + parts.joined(separator: ", ") + "."
    }
}
