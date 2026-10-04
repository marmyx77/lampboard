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
        case rows, allowFromPanel, depths, plancia, commandBar, squad, allowance, lampMaster
    }

    /// What the panel reports when the person does something.
    public enum Event: Equatable, Sendable {
        case rowOpened(session: String)
        case allowanceInspected
        case lampMasterOpened
        case lampMasterAnswered
    }

    /// Where the ring and the bubble point.
    public enum Anchor: Equatable, Sendable {
        case row(session: String)
        case allowance
        case lampMaster
    }

    public struct Step: Equatable, Sendable {
        public let id: String
        public let text: String
        public let anchor: Anchor
        public let waitsFor: Event
        public let teaches: Feature
    }

    /// The features 0.5 has. Each later version adds its own.
    public static let available: Set<Feature> = [.rows, .allowance, .lampMaster]

    /// Every step of the tour, in order, for every version. UX §13.3.
    public static func all(_ script: DemoScript = .standard) -> [Step] {
        let docs = script.sessions[0].id, api = script.sessions[1].id
        return [
            Step(id: "colours", text: "Yellow: working. Green: finished, with something to read. Click the green row.",
                 anchor: .row(session: docs), waitsFor: .rowOpened(session: docs), teaches: .rows),
            Step(id: "amber", text: "Amber: it is waiting for you — the only thing here that blinks. Click it to go there.",
                 anchor: .row(session: api), waitsFor: .rowOpened(session: api), teaches: .rows),
            Step(id: "allow", text: "You can answer from here, without changing window.",
                 anchor: .row(session: api), waitsFor: .rowOpened(session: api), teaches: .allowFromPanel),
            Step(id: "depths", text: "Three depths: Column at a glance, Panel, Plancia to act.",
                 anchor: .row(session: docs), waitsFor: .rowOpened(session: docs), teaches: .depths),
            Step(id: "plancia", text: "Space opens a session in the Plancia: thread, activity, cost.",
                 anchor: .row(session: docs), waitsFor: .rowOpened(session: docs), teaches: .plancia),
            Step(id: "command", text: "⌘K is the door to everything: search, @ for a session, ? for LampMaster.",
                 anchor: .row(session: docs), waitsFor: .rowOpened(session: docs), teaches: .commandBar),
            Step(id: "squad", text: "Ask a session what another knows. LampBoard carries the question and the answer.",
                 anchor: .row(session: docs), waitsFor: .rowOpened(session: docs), teaches: .squad),
            Step(id: "allowance", text: "Each account's allowance, and when it comes back. Point at the bar.",
                 anchor: .allowance, waitsFor: .allowanceInspected, teaches: .allowance),
            Step(id: "lampmaster", text: "LampMaster looks at every session once an hour and suggests at most three "
                    + "things. You decide: open its card and answer it.",
                 anchor: .lampMaster, waitsFor: .lampMasterAnswered, teaches: .lampMaster),
        ]
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
