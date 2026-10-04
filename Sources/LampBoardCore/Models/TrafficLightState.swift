import Foundation

/// The complete state of the traffic light column.
///
/// An immutable structure: the reducer always produces a new version of it.
/// The ordering of the sessions is a derived property, not mutable state.
public struct TrafficLightState: Sendable, Equatable {
    /// Sessions indexed by session id.
    public let sessions: [String: SessionState]

    /// Rows the user took off the column, and when.
    ///
    /// A row can outlive what it describes: a chat tab closed while its process
    /// stays loaded, a rollout a shared daemon keeps open. The panel is right
    /// that the conversation exists, and the person is right that it is gone —
    /// the tab is not a fact this machine publishes anywhere, so neither can
    /// prove the other wrong. This is where the person decides.
    ///
    /// The date is the whole mechanism. It is not a list of rows never to show
    /// again: it is the moment after which a row has to say something new to
    /// come back. Evidence older than the dismissal is the evidence that was
    /// already there, and bringing the row back on it would undo the click.
    /// Anything newer is a session that spoke, and that outranks the dismissal.
    public let dismissed: [String: Date]

    public init(sessions: [String: SessionState] = [:], dismissed: [String: Date] = [:]) {
        self.sessions = sessions
        self.dismissed = dismissed
    }

    public static let empty = TrafficLightState()

    /// Sessions ordered the way they should be drawn in the column.
    ///
    /// State urgency first; then, for equal states, whoever has been waiting
    /// longest. The alphabetical criterion used previously gave precedence to
    /// the luckiest name: between two sessions asking for a permission, the one
    /// stuck for six minutes belongs above the one stuck for ten seconds.
    /// The name stays as a tie-break, so the order doesn't jitter between refreshes.
    public var ordered: [SessionState] {
        sessions.values.sorted { lhs, rhs in
            if lhs.status.urgencyRank != rhs.status.urgencyRank {
                return lhs.status.urgencyRank < rhs.status.urgencyRank
            }
            if lhs.statusSince != rhs.statusSince {
                return lhs.statusSince < rhs.statusSince
            }
            if lhs.workspace.name != rhs.workspace.name {
                return lhs.workspace.name.localizedStandardCompare(rhs.workspace.name) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    /// Number of sessions currently waiting on the user.
    public var unseenCount: Int {
        sessions.values.filter { $0.status.clearsOnFocus }.count
    }

    /// Most urgent state present in the column, if there is at least one.
    public var mostUrgentStatus: SessionStatus? {
        sessions.values.map(\.status).min { $0.urgencyRank < $1.urgencyRank }
    }

    /// Copy with a session inserted or replaced.
    public func upserting(_ session: SessionState) -> TrafficLightState {
        var next = sessions
        next[session.id] = session
        return TrafficLightState(sessions: next, dismissed: dismissed)
    }

    /// Copy without the given session.
    public func removing(sessionId: String) -> TrafficLightState {
        var next = sessions
        next.removeValue(forKey: sessionId)
        return TrafficLightState(sessions: next, dismissed: dismissed)
    }

    /// Copy with a row taken off at the user's request, and the moment recorded.
    ///
    /// The session is removed and the date kept: see `dismissed` for why the date
    /// is the whole point rather than the id.
    public func dismissing(sessionId: String, at moment: Date) -> TrafficLightState {
        var rows = sessions
        rows.removeValue(forKey: sessionId)
        var marks = dismissed
        marks[sessionId] = moment
        return TrafficLightState(sessions: rows, dismissed: marks)
    }

    /// Whether evidence dated `moment` is enough to bring a dismissed row back.
    ///
    /// True when the row was never dismissed, or when what is being offered is
    /// newer than the dismissal. Equal dates count as older: the sweep that runs
    /// in the same instant is showing what was already on screen.
    public func admits(sessionId: String, evidenceAt moment: Date) -> Bool {
        guard let dismissedAt = dismissed[sessionId] else { return true }
        return moment > dismissedAt
    }

    /// Copy that has forgotten a dismissal, because the session spoke.
    public func undismissing(sessionId: String) -> TrafficLightState {
        guard dismissed[sessionId] != nil else { return self }
        var marks = dismissed
        marks.removeValue(forKey: sessionId)
        return TrafficLightState(sessions: sessions, dismissed: marks)
    }

    /// Copy without the sessions that have shown no sign of life for longer than `maxAge`.
    ///
    /// The threshold applies to **every** state, `working` included. The exemption
    /// that used to be here — "a long turn is not a dead session" — made yellows
    /// immortal, and the case where that happens is not rare: `Stop` does not fire
    /// when you interrupt a turn with Esc, and no other hook covers it. Every
    /// interruption left a yellow row behind forever.
    ///
    /// If the threshold gets it wrong the damage is bounded: on the next signal the
    /// reducer recreates the row, so at worst you temporarily lose a clickable
    /// target, not an event.
    /// - Parameter alive: sessions whose process is confirmed running. These are
    ///   **never** pruned, however old their last signal looks.
    ///
    ///   Pruning exists to drop rows we can no longer account for. A live pid is
    ///   accounting for one, and dropping it anyway was a real defect: a session
    ///   open for a week and working right now vanished from the column, because
    ///   the file its age was read from is written once at startup and never
    ///   touched again. The traffic light went dark on exactly the session it
    ///   existed to show.
    public func pruning(
        olderThan maxAge: TimeInterval, at now: Date, keepingAlive alive: Set<String> = []
    ) -> TrafficLightState {
        // A watched command still running is alive by definition: nothing
        // refreshes it while it runs, and a night-long job would vanish mid-run.
        let survivors = sessions.filter { id, session in
            alive.contains(id) || now.timeIntervalSince(session.updatedAt) <= maxAge
                || (session.harness == .command && session.status == .working)
        }
        return TrafficLightState(sessions: survivors, dismissed: dismissed)
    }
}

extension TrafficLightState {
    /// A session by its id, or by the eight characters LampMaster names it with
    /// when they name one session only. A LampMaster card carries the short
    /// form; looked up as an id it found nothing, and opening the card did
    /// nothing (found on the test Mac while building the Plancia).
    public func session(named id: String) -> SessionState? {
        if let exact = sessions[id] { return exact }
        guard id.count >= 8 else { return nil }
        let matches = sessions.values.filter { $0.id.hasPrefix(id) }
        return matches.count == 1 ? matches.first : nil
    }
}

