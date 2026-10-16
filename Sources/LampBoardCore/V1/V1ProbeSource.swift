import Foundation

/// The `v1` source of a machine that does not serve `v1` yet, made on the phone
/// from what `V1ProbeReading` reads there over ssh (D176). Until the Linux
/// service arrives, this is how the phone sees that machine's lights at all.
///
/// The rows are made by the Mac's own rules for a remote session nobody has
/// announced: one per conversation a person started (`deservesTrafficLight`,
/// a transcript), placed by `RemoteWorkspaceResolver`, `working` when Claude
/// Code's file says `busy` and the transcript's turn is open, `waiting` (blue)
/// when it says `busy` and the turn ended — background work registered — and
/// `idle` otherwise (`RemoteAdoption.adopted`, D141), with the context the
/// probe read from the transcript's tail. Each row says how it was learned
/// (`V1StateBasis.sessionFile`): no hook reaches the phone, so amber, an
/// answer to read and red never show.
///
/// A machine that stops answering keeps its rows, marked unreachable, with the
/// time of the last answer (D21); the state's age in `hello` is that answer's.
/// The person's choices — hidden, folded, order, read, a name, mute — live
/// here, and survive every reading.
///
/// Thread-safe: the reading arrives on one task while a `V1Service` serves it
/// on another.
public final class V1ProbeSource: V1Source, @unchecked Sendable {

    public let identity: V1SourceIdentity
    private let memory: V1MemorySource
    private let lock = NSLock()
    private var answered: Date?
    private var asked: Date?
    private var tmux: [TmuxSessionInfo]?
    private var labels: [String: String] = [:]
    private var mutes: [String: Bool] = [:]

    public init(identity: V1SourceIdentity, version: String = "probe", startedAt: Date, journal: String, retention: Int = 1000) {
        self.identity = identity
        memory = V1MemorySource(identity: identity, version: version, startedAt: startedAt, journal: journal,
                                retention: retention, known: false)
    }

    // MARK: - What the app reads besides the rows

    /// When the machine last answered: the age of everything shown.
    public var answeredAt: Date? { locked { answered } }
    /// When it was last asked, answered or not.
    public var askedAt: Date? { locked { asked } }
    /// tmux's sessions there, as of the last answer; `nil` before one, or on a
    /// machine without tmux.
    public var tmuxSessions: [TmuxSessionInfo]? { locked { tmux } }
    /// What a row of this source cannot say.
    public var unknowns: [String] { V1StateBasis.sessionFile.unknowns }

    // MARK: - Readings

    /// A reading, or `nil` for a machine that did not answer.
    public func absorb(_ reading: V1ProbeReading?, at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        asked = now
        guard let reading else {
            markUnreachable(at: now)
            return
        }
        answered = now
        tmux = reading.tmuxSessions
        let fresh = Self.rows(from: reading.report, identity: identity, at: now)
        let current = memory.snapshot(at: now).rows ?? []
        let freshIds = Set(fresh.map(\.id))
        for old in current where !freshIds.contains(old.id) {
            memory.remove(id: old.id, at: now)
        }
        for row in fresh {
            let kept = keepingChoices(row, from: memory.row(row.id))
            if let old = memory.row(row.id), Self.same(old, kept) { continue }
            memory.upsert(kept, at: now)
        }
        memory.confirm(rowsAt: now)
        memory.probed(at: now)
    }

    /// The rows one report makes, before the person's choices.
    public static func rows(from report: RemoteSessionsDecoder.Report, identity: V1SourceIdentity, at now: Date) -> [V1Row] {
        let candidates = report.sessions.filter { $0.deservesTrafficLight && $0.hasTranscript }
        // One row per conversation: two processes holding it are one row,
        // working if either is, else waiting if either is, reached through tmux
        // if either is in it.
        var order: [String] = []
        var grouped: [String: [LiveSession]] = [:]
        for session in candidates {
            if grouped[session.sessionId] == nil { order.append(session.sessionId) }
            grouped[session.sessionId, default: []].append(session)
        }
        return order.compactMap { id in
            guard let group = grouped[id], let first = group.first else { return nil }
            let lead = group.first { $0.tmux != nil } ?? group.first { $0.isBusy } ?? first
            // working > waiting > idle: the Core's own order of urgency.
            let busiest = group.map(\.statusFromFile).min { $0.urgencyRank < $1.urgencyRank } ?? lead.statusFromFile
            let session = lead.with(statusFromFile: busiest)
            let workspace = RemoteWorkspaceResolver.resolve(
                cwd: session.cwd, sessionId: session.sessionId, host: identity.name,
                windows: report.windows, sessions: report.sessions, at: now
            )
            let origin: SessionOrigin = session.isBackground ? .background
                : session.tmux == nil && session.entrypoint == "claude-vscode" ? .editor : .terminal
            var state = RemoteAdoption.adopted(session, in: workspace, origin: origin)
            if let context = group.compactMap(\.context).first { state = state.with(context: context) }
            return V1Row(
                session: SessionsCodec.snapshot(of: state), source: identity,
                extras: V1RowExtras(
                    hostProbedAt: now, hostReachable: true,
                    terminal: group.compactMap(\.tmux).first.map { "tmux:\($0.session)" },
                    stateBasis: .sessionFile
                )
            )
        }
    }

    // MARK: - V1Source

    public func status(at now: Date) -> V1SourceStatus { locked { memory.status(at: now) } }

    public func snapshot(at now: Date) -> V1State { locked { memory.snapshot(at: now) } }

    public func events(after seq: Int) -> V1Replay { locked { memory.events(after: seq) } }

    /// There is no transcript to send yet: reading one is a separate ssh call
    /// (`RemoteTranscriptScript`), not part of a look at the lights.
    public func transcript(session: String, limit: Int) -> V1Transcript? { nil }

    public func perform(_ command: V1Command, by peer: V1Peer, at now: Date) -> V1Failure? {
        locked {
            if let id = command.session {
                if command.action == .rename { labels[id] = command.name ?? "" }
                if command.action == .mute { mutes[id] = command.on ?? true }
            }
            return memory.perform(command, by: peer, at: now)
        }
    }

    public func register(_ registration: V1PushRegistration, by peer: V1Peer, at now: Date) -> V1Failure? {
        V1Failure(.unavailable, "a machine read over ssh sends no notifications")
    }

    public func devices(_ request: V1DevicesRequest, by peer: V1Peer, at now: Date) -> Result<[V1Device], V1Failure> {
        .failure(V1Failure(.unavailable, "a machine read over ssh keeps no list of devices"))
    }

    // MARK: - Inside

    private func markUnreachable(at now: Date) {
        guard let answered else { return }
        for row in memory.snapshot(at: now).rows ?? [] where row.extras.hostReachable != false {
            var extras = row.extras
            extras.hostReachable = false
            extras.hostProbedAt = answered
            memory.upsert(row.with(extras: extras), at: now)
        }
        memory.confirm(rowsAt: answered)
    }

    /// `row` with what the person chose for the row it replaces.
    private func keepingChoices(_ row: V1Row, from old: V1Row?) -> V1Row {
        var extras = row.extras
        if let old {
            extras.hidden = old.extras.hidden
            extras.folded = old.extras.folded
            extras.order = old.extras.order
            extras.readAt = old.extras.readAt
        }
        let session = row.session.with(label: labels[row.id], muted: mutes[row.id])
        return V1Row(session: session, source: row.source, owner: row.owner, extras: extras)
    }

    /// The same row, whenever it was looked at.
    private static func same(_ a: V1Row, _ b: V1Row) -> Bool {
        var x = a.extras, y = b.extras
        x.hostProbedAt = nil
        y.hostProbedAt = nil
        return a.session == b.session && a.source == b.source && a.owner == b.owner && x == y
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
