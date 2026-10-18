import Foundation
import LampBoardCore

/// What the hooks say of this machine's sessions, once `lampd` holds the hooks'
/// port (W5, §2.3): the Core's reducer over the same signals the Mac reduces
/// (`HookReplay` plays them the same way, so the parity with the Mac holds),
/// the mod's reports, and the questions the Mac holds in process.
///
/// A row any hook spoke for takes its colour from here — green "to read", red,
/// amber with its question — and keeps from the file everything the file knows
/// better: where it is, its folder, its title, tmux. A row no hook spoke for
/// keeps the file's rule unchanged (the gate «Una sola regola dei file»).
///
/// The files still have the last word on two things (D177): `busy` lights a row
/// the hooks left at rest, and an `idle` that has lasted a minute with the hooks
/// as quiet rests a yellow nothing will end — a compaction Claude Code ran by
/// itself while nobody typed, whose only hook says nothing of a turn.
///
/// Thread-safe: signals arrive on the hooks' threads, looks on the main loop.
public final class NodeHooks: @unchecked Sendable {

    /// A question the Mac holds for a session (D80, D86): the row is amber
    /// with its text while the Mac has it, and the push goes out then (M9).
    public struct Held: Equatable, Sendable {
        public let session: String
        public let call: String
        public let text: String
        public let since: Date
    }

    private let lock = NSLock()
    private var state = TrafficLightState.empty
    private var ledger = ModLedger()
    private var held: [String: Held] = [:]
    /// Whether the reconciliation with the files runs. Always on; the suite's
    /// bite turns it off to show the idle compaction's yellow staying.
    let reconcilesWithFiles: Bool

    public init(reconcilesWithFiles: Bool = true) {
        self.reconcilesWithFiles = reconcilesWithFiles
    }

    // MARK: - What arrives

    /// A hook's signal, as the Mac's `SignalServer` decodes and reduces it.
    public func signal(_ signal: HookSignal, at now: Date) {
        locked {
            state = StateReducer.reduce(state, action: .signal(signal, workspace: Workspace(path: signal.cwd), origin: .editor), now: now)
        }
    }

    /// One of the mod's reports: cost, the context ring, the tool running, the
    /// Esc that rests a row (D160), as the Mac's `ModReceiver` takes them.
    public func mod(_ report: ModReport, at now: Date) {
        locked {
            ledger = ledger.applying(report, now: now)
            if case .tool(let id, _) = report {
                let start = state.sessions[id].map { $0.status == .working ? $0.statusSince : now } ?? now
                apply(.tooling(sessionId: id, tool: ledger.longestRunning(in: id, since: start)), at: now)
            }
            if case .stopped(let id, let stopped) = report, let action = stopped.action(for: state.sessions[id], now: now) {
                apply(action, at: now)
            }
            if case .measure(let id, let measure) = report {
                if let usd = measure.costUSD { apply(.costed(sessionId: id, usd: usd), at: now) }
                if let reading = measure.reading(previous: state.sessions[id]?.context, at: now) {
                    apply(.observed(sessionId: id, context: reading), at: now)
                }
            }
        }
    }

    /// The Mac has a question for `request.sessionId`; returns what to call
    /// `release` with when its answer comes back.
    public func hold(_ request: PermissionGate.Request, at now: Date) -> Held {
        let text = request.line
        let entry = Held(session: request.sessionId, call: request.callId, text: String(text.prefix(300)), since: now)
        locked { held[request.sessionId] = entry }
        return entry
    }

    /// The Mac answered, or stopped waiting: the row is what the hooks say.
    public func release(_ entry: Held) {
        locked { if held[entry.session] == entry { held[entry.session] = nil } }
    }

    public func markSeen(_ id: String, at now: Date) { locked { apply(.markSeen(sessionId: id), at: now) } }
    public func markUnread(_ id: String, at now: Date) { locked { apply(.markUnread(sessionId: id), at: now) } }

    /// The sessions any hook spoke for.
    public var heard: Set<String> { locked { Set(state.sessions.keys) } }

    public var heldQuestions: [Held] { locked { Array(held.values) } }

    // MARK: - With the files

    /// One look at the files: the file's `busy` lights a row the hooks left at
    /// rest, its long `idle` rests a yellow nothing ends (D177), and a session
    /// whose process is gone leaves (an empty look is a look that failed).
    public func reconcile(with sessions: [LiveSession], at now: Date) {
        guard reconcilesWithFiles else { return }
        locked {
            for session in sessions where state.sessions[session.sessionId] != nil {
                let status = session.statusForAHeardRow
                if status == .working || status == .waiting {
                    apply(.busy(sessionId: session.sessionId, status: status), at: now)
                }
            }
            for session in sessions {
                guard let idleSince = session.idleSince, let row = state.sessions[session.sessionId],
                      row.baseStatus == .working || (row.baseStatus == .waiting && row.litByFile) else { continue }
                apply(.fileRest(sessionId: session.sessionId, idleSince: idleSince,
                                turnIsOpen: session.turnIsOpen, readAt: now), at: now)
            }
            let alive = Set(sessions.map(\.sessionId))
            if !alive.isEmpty { apply(.reconcile(alive: alive), at: now) }
        }
    }

    /// `rows` (the file's, before the person's choices) with what the hooks
    /// say: the colour of each row a hook spoke for, the question the Mac holds.
    public func overlaid(_ rows: [V1Row], at now: Date) -> [V1Row] {
        locked {
            rows.map { row in
                guard let session = state.sessions[row.id] else { return heldOverlay(row) }
                let heard = SessionsCodec.snapshot(of: session)
                var extras = row.extras
                extras.stateBasis = .hooks
                return heldOverlay(V1Row(session: Self.colour(of: heard, on: row.session), source: row.source,
                                         owner: row.owner, extras: extras))
            }
        }
    }

    /// While the Mac holds a question the row is amber with it, whatever the
    /// file says (during the hook the file may still say `busy`, W4).
    private func heldOverlay(_ row: V1Row) -> V1Row {
        guard let entry = held[row.id] else { return row }
        var extras = row.extras
        extras.heldByMac = true
        let s = row.session
        let session = SessionSnapshot(
            id: s.id, status: SessionStatus.awaiting.rawValue, workspace: s.workspace, path: s.path,
            updatedAt: max(s.updatedAt, entry.since), statusSince: entry.since, activeSubagents: s.activeSubagents,
            harness: s.harness, pendingAsk: entry.text, waitingOn: s.waitingOn,
            contextPercent: s.contextPercent, contextTokens: s.contextTokens, contextWindow: s.contextWindow,
            contextModel: s.contextModel, contextConfidence: s.contextConfidence, costUSD: s.costUSD,
            failureReason: nil, lastMessage: s.lastMessage, muted: s.muted, slot: s.slot,
            transcriptPath: s.transcriptPath, git: s.git, host: s.host, entrypoint: s.entrypoint, origin: s.origin,
            title: s.title, jobId: s.jobId, summary: s.summary, needs: s.needs, unreadAnswers: s.unreadAnswers, label: s.label
        )
        return V1Row(session: session, source: row.source, owner: row.owner, extras: extras)
    }

    /// The file's row with the hooks' colour: what the hooks know (state, when
    /// it began, the question, the failure, the answer to read, the cost and
    /// the ring the mod reported) over what the file knows (where and what).
    static func colour(of heard: SessionSnapshot, on file: SessionSnapshot) -> SessionSnapshot {
        SessionSnapshot(
            id: file.id, status: heard.status, workspace: file.workspace, path: file.path,
            updatedAt: max(file.updatedAt, heard.updatedAt), statusSince: heard.statusSince,
            activeSubagents: heard.activeSubagents, harness: file.harness, pendingAsk: heard.pendingAsk,
            waitingOn: heard.waitingOn,
            contextPercent: heard.contextPercent ?? file.contextPercent, contextTokens: heard.contextTokens ?? file.contextTokens,
            contextWindow: heard.contextWindow ?? file.contextWindow, contextModel: heard.contextModel ?? file.contextModel,
            contextConfidence: heard.contextConfidence ?? file.contextConfidence, costUSD: heard.costUSD ?? file.costUSD,
            failureReason: heard.failureReason, lastMessage: heard.lastMessage ?? file.lastMessage, muted: file.muted,
            slot: file.slot, transcriptPath: file.transcriptPath ?? heard.transcriptPath, git: file.git ?? heard.git,
            host: file.host, entrypoint: file.entrypoint, origin: file.origin, title: file.title ?? heard.title,
            jobId: file.jobId, summary: file.summary, needs: file.needs, unreadAnswers: heard.unreadAnswers, label: file.label
        )
    }

    /// Under the lock.
    private func apply(_ action: ReducerAction, at now: Date) {
        state = StateReducer.reduce(state, action: action, now: now)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
