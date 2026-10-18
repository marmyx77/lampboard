import Foundation

/// One device a source may notify, as the source knows it at one moment.
public struct PushDevice: Equatable, Sendable {
    public let id: String
    public let preferences: V1PushPreferences
    /// When the app last said it was in use there (`cmd focus`): the device
    /// last used is the one that rings (Q9), and one used a moment ago is in
    /// the person's hand.
    public let usedAt: Date?
    /// The session open on its screen when it last said so: while it is, the
    /// other sessions' alerts wait for one line (`FocusHold`, G1).
    public let focusedSession: String?

    public init(id: String, preferences: V1PushPreferences = .standard, usedAt: Date? = nil, focusedSession: String? = nil) {
        self.id = id
        self.preferences = preferences
        self.usedAt = usedAt
        self.focusedSession = focusedSession
    }

    /// The app in front: it shows the column itself, live (Q5).
    public func isPresent(at now: Date) -> Bool {
        guard let usedAt else { return false }
        return now.timeIntervalSince(usedAt) <= PushPlanner.presenceWindow && usedAt <= now.addingTimeInterval(60)
    }
}

/// One notification a source decided to send to one device.
public struct PlannedAlert: Equatable, Sendable {
    public let device: String
    public let event: PushEvent
    /// The row, or `nil` for a summary.
    public let session: String?
    public let title: String
    public let body: String
    /// Priority 10: a new question for the person (§2.8, point 4).
    public let urgent: Bool
    /// Without a sound: the copy for the other devices (Q9).
    public let quiet: Bool
}

/// What the source must do after one look.
public struct PushPlan: Equatable, Sendable {
    public var alerts: [PlannedAlert] = []
    /// The counts, when they changed since the last ones sent: for the badge,
    /// the widget and the Live Activity.
    public var counts: PushCounts?
    /// Look again then, even if nothing else happens: an amber row too young
    /// to announce, or the other devices' copy coming due.
    public var nextCheck: Date?

    public init(alerts: [PlannedAlert] = [], counts: PushCounts? = nil, nextCheck: Date? = nil) {
        self.alerts = alerts
        self.counts = counts
        self.nextCheck = nextCheck
    }
}

/// What a source remembers between looks to notify **transitions** and never
/// states (D9): what each row was, which amber rows were announced, what the
/// other devices are still owed, what waited for a focus.
public struct PushMemory: Codable, Equatable, Sendable {
    /// `nil` before the first look: what is already so at start is not news.
    public var statuses: [String: String]?
    /// When each amber row was first seen amber, for the rows whose own time
    /// says less.
    public var amberSince: [String: Date] = [:]
    /// The amber rows already announced in this amber spell.
    public var announced: Set<String> = []
    /// The other devices' copies (Q9).
    public var owed: [Owed] = []
    /// What waited, per device, while that device was in one session.
    public var held: [String: [Held]] = [:]
    /// The session each device was in when its held alerts began.
    public var heldFocus: [String: String] = [:]
    public var lastCounts: PushCounts?

    public struct Owed: Codable, Equatable, Sendable {
        public let device: String
        public let event: PushEvent
        public let session: String
        public let status: String
        public let due: Date
        public let title: String
        public let body: String
    }

    public struct Held: Codable, Equatable, Sendable {
        public let event: PushEvent
        public let session: String
        public let name: String
    }

    public init() {}
}

/// The rule that decides which notifications a source sends after each look:
/// one function, so that `lampd` now and the Mac in W5 notify the same way.
///
/// It is the Mac's `SessionNotifier` made a pure function over `v1` rows:
/// - **transitions only.** The first look records what is so and sends nothing:
///   ten amber rows at start are zero notifications.
/// - **amber after four seconds** in the same amber spell, announced once; a
///   question answered within four seconds is never announced. The memory moves
///   even while notifications are off, so turning them on is not a burst.
/// - **red** on the transition; **a turn finished** only for a device that asked
///   (`V1PushPreferences.finished`): from the files, a session that worked and is
///   at rest, or that has an answer.
/// - **silences**: the row's own («Don't alert me», `mute`), the device's muted
///   projects, everything until a time.
/// - **presence** (Q5): a device used in the last `presenceWindow` seconds shows
///   the column itself, live; while one is, nobody's phone rings. One in a
///   session holds the others' alerts and says them in one line when it leaves
///   (`FocusHold`, G1).
/// - **the device last used rings** (Q9); the others get a quiet copy after
///   `othersAfter` if the row has not moved in the meantime.
public enum PushPlanner {

    /// An amber row younger than this is a permission the agent is answering
    /// itself, or one the person is answering already (the Mac's
    /// `awaitingNotificationDelay`).
    public static let amberDelay: TimeInterval = 4
    /// How long after its last `focus` a device counts as in the person's hand.
    public static let presenceWindow: TimeInterval = 45
    /// When the devices that did not ring get their quiet copy (Q9).
    public static let othersAfter: TimeInterval = 120

    public static func plan(rows: [V1Row], devices: [PushDevice], memory: PushMemory, at now: Date) -> (PushPlan, PushMemory) {
        var memory = memory
        var plan = PushPlan()
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let counts = PushCounts(statuses: rows.filter { !$0.extras.hidden }.map(\.session.status))
        if memory.lastCounts != counts {
            plan.counts = counts
            memory.lastCounts = counts
        }

        guard let before = memory.statuses else {
            memory.statuses = byId.mapValues(\.session.status)
            for row in rows where row.session.status == SessionStatus.awaiting.rawValue {
                memory.announced.insert(row.id)
                memory.amberSince[row.id] = row.session.statusSince
            }
            return (plan, memory)
        }

        var news: [(event: PushEvent, row: V1Row)] = []
        var soonest: Date?
        // A wait held for someone in a session is said by that hold's line.
        let heldWaiting = Set(memory.held.values.flatMap { $0 }.filter { $0.event == .waiting }.map(\.session))
        for row in rows.sorted(by: { $0.id < $1.id }) {
            let status = row.session.status
            let was = before[row.id]
            if status == SessionStatus.awaiting.rawValue {
                if was != status || memory.amberSince[row.id] == nil {
                    // A new spell. The row's own time is the file's word, and a
                    // file can say when it turned before this source looked.
                    memory.amberSince[row.id] = min(max(row.session.statusSince, now.addingTimeInterval(-3600)), now)
                    memory.announced.remove(row.id)
                }
                guard !memory.announced.contains(row.id) else { continue }
                let since = memory.amberSince[row.id] ?? now
                if now.timeIntervalSince(since) >= amberDelay {
                    // With the app in someone's hand the row shows itself, and
                    // stays unannounced: put the phone away while it still
                    // waits and it rings then (seen on the simulator: an amber
                    // four seconds into a presence was never said at all).
                    let inHand = devices.contains { $0.isPresent(at: now) && admits($0, row: row, event: .waiting, at: now) }
                    if !inHand { memory.announced.insert(row.id) }
                    if inHand || !heldWaiting.contains(row.id) { news.append((.waiting, row)) }
                } else {
                    let due = since.addingTimeInterval(amberDelay)
                    soonest = min(soonest ?? due, due)
                }
                continue
            }
            memory.amberSince.removeValue(forKey: row.id)
            memory.announced.remove(row.id)
            guard let was, was != status else { continue }
            if status == SessionStatus.failed.rawValue {
                news.append((.failed, row))
            } else if Self.finishedATurn(from: was, to: status) {
                news.append((.finished, row))
            }
        }
        for id in Set(memory.amberSince.keys).subtracting(byId.keys) { memory.amberSince.removeValue(forKey: id) }
        memory.announced.formIntersection(byId.keys)
        memory.statuses = byId.mapValues(\.session.status)

        // Owed copies: still true, nobody present, and due.
        let anyonePresent = devices.contains { $0.isPresent(at: now) }
        var stillOwed: [PushMemory.Owed] = []
        for owed in memory.owed {
            guard let row = byId[owed.session], row.session.status == owed.status,
                  let device = devices.first(where: { $0.id == owed.device })
            else { continue }
            if anyonePresent { continue }
            if owed.due > now {
                stillOwed.append(owed)
                soonest = min(soonest ?? owed.due, owed.due)
                continue
            }
            guard admits(device, row: row, event: owed.event, at: now) else { continue }
            plan.alerts.append(PlannedAlert(device: owed.device, event: owed.event, session: owed.session,
                                            title: owed.title, body: owed.body, urgent: false, quiet: true))
        }
        memory.owed = stillOwed

        // Held lines: said when the device leaves the session it was in.
        for device in devices {
            guard let held = memory.held[device.id], !held.isEmpty else { continue }
            let stillIn = device.isPresent(at: now) && device.focusedSession == memory.heldFocus[device.id]
            if stillIn { continue }
            let current = held.filter { item in
                guard let row = byId[item.session], !row.session.muted else { return false }
                return item.event != .waiting || row.session.status == SessionStatus.awaiting.rawValue
            }
            memory.held[device.id] = nil
            memory.heldFocus[device.id] = nil
            let hold = FocusHold(focused: "-", held: current.map {
                FocusHold.Held(event: $0.event.notificationEvent, sessionId: $0.session, name: $0.name)
            })
            if let line = hold.summary(), device.preferences.enabled, !(device.preferences.mutedUntil.map { $0 > now } ?? false),
               !anyonePresent || !device.isPresent(at: now) {
                plan.alerts.append(PlannedAlert(device: device.id, event: .summary, session: nil, title: "LampBoard",
                                                body: line, urgent: false, quiet: false))
            }
        }

        for (event, row) in news {
            route(event, row: row, devices: devices, memory: &memory, plan: &plan, at: now)
        }
        plan.nextCheck = soonest
        return (plan, memory)
    }

    /// Who hears one piece of news, and how.
    private static func route(_ event: PushEvent, row: V1Row, devices: [PushDevice],
                              memory: inout PushMemory, plan: inout PushPlan, at now: Date) {
        let title = name(of: row)
        let body = Self.body(event, row: row)
        let listening = devices.filter { admits($0, row: row, event: event, at: now) }
        guard !listening.isEmpty else { return }
        // Someone has the app in front: it shows the row itself. One in a
        // session holds the news for when they come out of it.
        let present = listening.filter { $0.isPresent(at: now) }
        if !present.isEmpty {
            for device in present {
                guard let focused = device.focusedSession, focused != row.id else { continue }
                if memory.heldFocus[device.id] != focused { memory.held[device.id] = []; memory.heldFocus[device.id] = focused }
                var held = memory.held[device.id, default: []].filter { !($0.session == row.id && $0.event == event) }
                held.append(PushMemory.Held(event: event, session: row.id, name: title))
                memory.held[device.id] = held
            }
            return
        }
        let ringer = listening.max { ($0.usedAt ?? .distantPast, $1.id) < ($1.usedAt ?? .distantPast, $0.id) }!
        plan.alerts.append(PlannedAlert(device: ringer.id, event: event, session: row.id, title: title, body: body,
                                        urgent: event == .waiting, quiet: false))
        for other in listening where other.id != ringer.id {
            memory.owed.removeAll { $0.device == other.id && $0.session == row.id && $0.event == event }
            memory.owed.append(PushMemory.Owed(device: other.id, event: event, session: row.id, status: row.session.status,
                                               due: now.addingTimeInterval(othersAfter), title: title, body: body))
        }
    }

    /// Whether `device` wants to hear `event` about `row` at all.
    static func admits(_ device: PushDevice, row: V1Row, event: PushEvent, at now: Date) -> Bool {
        let preferences = device.preferences
        guard preferences.enabled, !row.session.muted else { return false }
        if let until = preferences.mutedUntil, until > now { return false }
        // By the folder (what the phone keeps a row by) or by the project's name.
        if preferences.mutedProjects.contains(row.session.path) || preferences.mutedProjects.contains(row.session.workspace) {
            return false
        }
        if event == .finished && !preferences.finished { return false }
        return true
    }

    /// A turn that ended with the session at rest or with an answer.
    static func finishedATurn(from before: String, to after: String) -> Bool {
        before == SessionStatus.working.rawValue
            && (after == SessionStatus.ready.rawValue || after == SessionStatus.idle.rawValue)
    }

    /// The row's name as the column shows it.
    public static func name(of row: V1Row) -> String {
        let label = row.session.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? row.session.workspace : label
    }

    /// The line under the name: what happened, never a path or a command the
    /// row did not already show on the column.
    static func body(_ event: PushEvent, row: V1Row) -> String {
        switch event {
        case .waiting:
            if let ask = row.session.pendingAsk?.trimmingCharacters(in: .whitespacesAndNewlines), !ask.isEmpty {
                return NotificationText.clipped("Waiting for you · " + ask)
            }
            return row.session.title.map { NotificationText.clipped("Waiting for your answer: " + $0) } ?? "Waiting for your answer."
        case .failed:
            return row.session.failureReason.map { "The turn ended: " + $0 } ?? "The turn ended with an error."
        case .finished:
            guard let line = NotificationText.firstLine(of: row.session.lastMessage) else { return "Finished." }
            return NotificationText.clipped("Finished · " + line)
        case .summary, .counts:
            return ""
        }
    }
}

extension PushEvent {
    /// The Mac's word for the same news (`FocusHold` speaks it).
    var notificationEvent: NotificationText.Event {
        switch self {
        case .waiting: return .waiting
        case .failed: return .failed
        case .finished, .summary, .counts: return .finished
        }
    }
}
