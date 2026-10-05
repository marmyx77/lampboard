import Foundation

/// The tutorial's tour over the invented sessions: its steps, what moves it on,
/// and where somebody who left it comes back to.
///
/// A step moves on when its gesture happens — the row clicked, the card
/// answered — never on a "Next" button: the tour is learnt by doing. A step
/// whose feature this version does not have is not shown at all, so the tour
/// follows the installed version and grows with it.
public enum Tour {

    /// What the panel can do in this version. A step names the one it teaches.
    public enum Feature: String, Codable, Sendable, CaseIterable {
        case rows, allowFromPanel, depths, plancia, commandBar, squad, allowance, focus, away, lampMaster, lampMasterAsk
    }

    /// What the panel reports when the person does something.
    public enum Event: Equatable, Sendable {
        case rowOpened(session: String)
        /// `⌘⇧L` reached its last depth: the Plancia.
        case depthReachedPlancia
        case planciaOpened(session: String)
        /// A result of the bar was chosen: a session, an action, a message.
        case barChose
        case permissionAnswered(session: String)
        case sideQuestionAnswered(session: String)
        case allowanceInspected
        /// A session put in focus.
        case focused
        case awayToggled(on: Bool)
        case lampMasterOpened
        case lampMasterAnswered
        case lampMasterAsked
    }

    /// Where the ring and the bubble point.
    public enum Anchor: Equatable, Sendable {
        case row(session: String)
        case allowance
        case lampMaster
        case bar
        case panelMenu
    }

    public struct Step: Equatable, Sendable {
        public let id: String
        public let text: String
        public let anchor: Anchor
        public let waitsFor: Event
        public let teaches: Feature
    }

    /// The longest sentence the band holds in two lines of the narrow panel.
    public static let longestText = 100

    /// What the trial can show: everything, the answers no model gives there
    /// played from the script (D120). A step the trial could not complete
    /// would stop the tour, so a new step comes with its gesture's answer.
    public static let available = Set(Feature.allCases)

    /// Every step of the tour, in order, for every version. UX §13.3, and the
    /// 0.7 and 0.8 features after it.
    public static func all(_ script: DemoScript = .standard) -> [Step] {
        let docs = script.sessions[0].id, api = script.sessions[1].id, events = script.sessions[2].id
        return [
            Step(id: "colours", text: "Yellow: working. Green: finished, with something to read. Click the green row.",
                 anchor: .row(session: docs), waitsFor: .rowOpened(session: docs), teaches: .rows),
            Step(id: "amber", text: "Amber: it is waiting for you — the only thing here that blinks. Click it to go there.",
                 anchor: .row(session: api), waitsFor: .rowOpened(session: api), teaches: .rows),
            Step(id: "allow", text: "You can answer from here, without changing window: Allow, or press A.",
                 anchor: .row(session: api), waitsFor: .permissionAnswered(session: api), teaches: .allowFromPanel),
            Step(id: "depths", text: "Three depths: the column, the panel, the Plancia to act. Press ⌘⇧L until the Plancia opens.",
                 anchor: .panelMenu, waitsFor: .depthReachedPlancia, teaches: .depths),
            Step(id: "plancia", text: "The Plancia shows one session: thread, activity, cost. Right-click events › Open in the Plancia.",
                 anchor: .row(session: events), waitsFor: .planciaOpened(session: events), teaches: .plancia),
            Step(id: "command", text: "⌘K is the door to everything: search, @ a session, ? LampMaster. Press ⌘K, type @ev, Return.",
                 anchor: .bar, waitsFor: .barChose, teaches: .commandBar),
            Step(id: "squad", text: "Ask a session without disturbing it: ⌘K, then @events ?what changed in the calendar.",
                 anchor: .bar, waitsFor: .sideQuestionAnswered(session: events), teaches: .squad),
            Step(id: "allowance", text: "Each account's allowance, and when it comes back. Point at the bar.",
                 anchor: .allowance, waitsFor: .allowanceInspected, teaches: .allowance),
            Step(id: "focus", text: "One session in focus, the others wait: right-click a row › Focus on this session.",
                 anchor: .row(session: events), waitsFor: .focused, teaches: .focus),
            Step(id: "away", text: "Going out? Panel menu › I'm away: nothing interrupts. Choose it again: one line sums it up.",
                 anchor: .panelMenu, waitsFor: .awayToggled(on: false), teaches: .away),
            Step(id: "lampmaster", text: "LampMaster looks at every session hourly and suggests at most three things. Answer its card.",
                 anchor: .lampMaster, waitsFor: .lampMasterAnswered, teaches: .lampMaster),
            Step(id: "ask", text: "Ask LampMaster about all your sessions: ⌘K, then ?who renamed the slots endpoint.",
                 anchor: .bar, waitsFor: .lampMasterAsked, teaches: .lampMasterAsk),
        ]
    }

    public enum Staging: Equatable, Sendable { case stage, wait, stop }

    /// Whether the trial puts the script's permission on the desk now (D120):
    /// only while the tour stands on "allow", where answering it counts; a
    /// tour skipped or not begun may come back to it, so it waits; past the
    /// step, or finished, never again.
    public static func trialPermission(_ progress: TourProgress, steps: [Step], waiting: Bool, shown: Bool) -> Staging {
        guard let allow = steps.firstIndex(where: { $0.id == "allow" }), progress.status != .finished else { return .stop }
        guard progress.status == .inProgress, let step = progress.current(in: steps),
              let here = steps.firstIndex(of: step) else { return .wait }
        if here > allow { return .stop }
        return here == allow && waiting && !shown ? .stage : .wait
    }

    /// The steps this version shows.
    public static func steps(available: Set<Feature> = available, script: DemoScript = .standard) -> [Step] {
        all(script).filter { available.contains($0.teaches) }
    }
}

/// Where somebody is in the tour. Kept in the local preferences by step id, so
/// a version that adds steps still resumes at the right one; never sent anywhere.
public struct TourProgress: Codable, Sendable, Equatable {

    public enum Status: String, Codable, Sendable {
        case notStarted, inProgress, finished, skipped
    }

    public let status: Status
    /// The step being shown, by id.
    public let stepId: String?

    public init(status: Status = .notStarted, stepId: String? = nil) {
        self.status = status
        self.stepId = stepId
    }

    public static func start(_ steps: [Tour.Step]) -> TourProgress {
        steps.first.map { TourProgress(status: .inProgress, stepId: $0.id) } ?? TourProgress(status: .finished)
    }

    /// The step on screen, if the tour is running and its step still exists.
    public func current(in steps: [Tour.Step]) -> Tour.Step? {
        guard status == .inProgress else { return nil }
        return steps.first { $0.id == stepId } ?? steps.first
    }

    /// "Step 2 of 4".
    public func position(in steps: [Tour.Step]) -> (index: Int, count: Int)? {
        guard let step = current(in: steps), let index = steps.firstIndex(of: step) else { return nil }
        return (index + 1, steps.count)
    }

    /// The tour after something happened: the next step when it was the
    /// gesture the current one waits for, unchanged otherwise.
    public func after(_ event: Tour.Event, in steps: [Tour.Step]) -> TourProgress {
        guard let step = current(in: steps), step.waitsFor == event,
              let index = steps.firstIndex(of: step)
        else { return self }
        let next = steps.index(after: index)
        return next < steps.endIndex
            ? TourProgress(status: .inProgress, stepId: steps[next].id)
            : TourProgress(status: .finished)
    }

    public func skipped() -> TourProgress { TourProgress(status: .skipped, stepId: stepId) }

    /// Back where it was left, or from the start when it was over.
    public func resumed(in steps: [Tour.Step]) -> TourProgress {
        switch status {
        case .inProgress where current(in: steps) != nil:
            return TourProgress(status: .inProgress, stepId: current(in: steps)?.id)
        case .skipped where steps.contains(where: { $0.id == stepId }):
            return TourProgress(status: .inProgress, stepId: stepId)
        default:
            return .start(steps)
        }
    }
}
