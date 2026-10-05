import AppKit
import LampBoardCore

/// The governor from a row's menu (G3): a session one model lower until the
/// session window resets, and back. Only on a click; never the session in focus.
extension PanelController {

    /// When a session window resets, as the strip has it: the nearest one still
    /// ahead. With two accounts a session's own is not known here, and the nearer
    /// reset is the one that cannot lower a session for longer than its window.
    var windowResetsAt: Date? {
        let now = Date()
        return allowance.reports
            .compactMap { $0.limits.limits.first { $0.span == .session }?.resetsAt }
            .filter { $0 > now }
            .min()
    }

    /// What the row's menu offers: "Use Sonnet until 13:10", or the model it runs
    /// on now when lowered; `nil` when nothing can be offered.
    func governorOffer(for row: ColumnRow) -> GovernorOffer? {
        let session = row.primary
        guard !row.workspace.isRemote, session.harness == .claudeCode, let governor else { return nil }
        if let lowered = governor.model(for: session.id) { return .lowered(PlanciaHeader.model(lowered)) }
        guard session.id != preferences.focusedSession, let until = windowResetsAt, until > Date(),
              let model = session.context?.model, let target = GovernorPlan.lowered(from: model) else { return nil }
        return .lower(PlanciaHeader.model(target), until: until)
    }

    func lowerModel(for row: ColumnRow) {
        let session = row.primary
        guard let governor, let until = windowResetsAt, let model = session.context?.model,
              let target = GovernorPlan.lowered(from: model) else { return }
        governor.lower(session.id, to: target, until: until, focused: preferences.focusedSession)
        rebuildContent()
    }

    func releaseModel(for row: ColumnRow) {
        governor?.release(row.primary.id)
        rebuildContent()
    }
}

/// What a row's menu says about the governor.
enum GovernorOffer: Equatable {
    case lower(String, until: Date)
    case lowered(String)

    var title: String {
        switch self {
        case .lower(let model, let until):
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            return "Use \(model) until the window resets (\(clock.string(from: until)))"
        case .lowered(let model):
            return "✓ On \(model) until the reset — back to its own model"
        }
    }
}
