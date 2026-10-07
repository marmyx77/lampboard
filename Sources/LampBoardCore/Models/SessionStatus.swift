import Foundation

/// The six states of a traffic light.
///
/// The semantics are deliberate: green does not mean "all good", it means
/// "there is an answer you haven't read yet".
public enum SessionStatus: String, Sendable, Equatable, CaseIterable, Codable {
    /// Session at rest: no work in progress, nothing to read. Hollow grey (U2):
    /// the dim red it used to be read as a broken session.
    case idle

    /// Claude is thinking or running tools. Yellow.
    case working

    /// The turn is over, and something Claude started is still running — a
    /// background shell, a monitor on a CI run, a subagent — and will wake it.
    /// Soft blue.
    ///
    /// Neither yellow nor green would be true. Yellow says *Claude is thinking*,
    /// and it is not: it handed control back. Green says *there is an answer and
    /// nothing more is coming*, and more is coming. This is exactly the second of
    /// the two things Claude Code says `background_tasks` exists to tell apart:
    /// "session is done" from "session is paused waiting for background work to
    /// wake it". Nothing is inferred from silence or timestamps.
    case waiting

    /// Claude is blocked waiting for a decision from you. Blinking amber.
    case awaiting

    /// The turn has finished: there is an answer to read. Green.
    case ready

    /// The turn stopped without producing an answer: quota limit, overload,
    /// authentication error. Solid red.
    ///
    /// Kept distinct from `ready` because there something is waiting to be read
    /// and here nothing is: showing them in the same color makes "it finished"
    /// indistinguishable from "it died halfway".
    case failed

    /// Sort priority: the states that demand attention rise to the top.
    /// Lower = more urgent.
    ///
    /// `failed` sits below `ready` on purpose: a ready answer is consumed right
    /// away, whereas there is nothing you can do about a rate limit until it expires.
    /// What this state is called, in the words a person reads.
    ///
    /// In Core and not in the palette next to the colours: the colour is a
    /// property of the interface, the word is a property of the state, and the
    /// tooltip's summary is assembled in Core where a test can reach it.
    public var label: String {
        switch self {
        case .idle: return "resting"
        case .working: return "working"
        case .waiting: return "waiting on background work"
        // Neutral with respect to the reason: it covers both the permission
        // request and a dialog opened by an MCP server, without having to
        // propagate the cause.
        case .awaiting: return "waiting for your answer"
        case .ready: return "answer ready"
        case .failed: return "turn interrupted"
        }
    }

    public var urgencyRank: Int {
        switch self {
        case .awaiting: return 0
        case .ready: return 1
        case .failed: return 2
        case .working: return 3
        // Below working: a session that has stopped is less worth watching than
        // one that is producing, and nothing about it needs you.
        case .waiting: return 4
        case .idle: return 5
        }
    }

    /// Only `awaiting` blinks: blinking is a scarce signal and should be spent on
    /// the one state that genuinely blocks the work.
    public var shouldBlink: Bool {
        self == .awaiting
    }

    /// The turn is over and the next move is the person's: where the prompt
    /// cache's minutes matter (R3b). Not while it works or waits on its own work.
    public var isWaitingOnPerson: Bool {
        switch self {
        case .ready, .awaiting, .failed, .idle: return true
        case .working, .waiting: return false
        }
    }

    /// States representing something the user has not seen yet, and which
    /// therefore fall back to `idle` when they open the session.
    public var clearsOnFocus: Bool {
        switch self {
        case .ready, .awaiting, .failed: return true
        // A wait is a fact about the session, not about you: a click has nothing
        // to clear, and the row stays blue until the work wakes it.
        case .idle, .working, .waiting: return false
        }
    }

    /// States that a trailing signal must not be allowed to downgrade to `working`.
    ///
    /// Distinct from `clearsOnFocus`: `failed` should be cleared by a click like
    /// the others, but it must **not** survive a restart — if the turn resumes
    /// after an error, yellow is the correct information and red would be a leftover.
    public var blocksDowngrade: Bool {
        switch self {
        // `waiting` resists for the same reason `ready` does: a wake-up always
        // begins with a prompt, so a tool event with no prompt before it is the
        // tail of the turn that already closed, and must not repaint the row yellow.
        case .ready, .awaiting, .waiting: return true
        case .idle, .working, .failed: return false
        }
    }
}
