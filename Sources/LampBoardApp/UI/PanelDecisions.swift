import AppKit
import LampBoardCore

/// The decision board from a row's menu (D105, B2): pin a decision for the
/// row's repository, or take one off. The same service the command line reaches
/// through the server, so the two never disagree.
extension PanelController {

    func pinDecision(in repository: String) {
        guard let board = decisionBoard else { return }
        let pinned = board.current.decisions(for: repository)
        let listing = pinned.isEmpty
            ? ""
            : "\n\nRules now:\n" + pinned.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        guard let text = Alerts.ask(
            title: "Add a project rule for “\(repository)”",
            message: "Every session working in this repository reads it with its next prompt, through the helper, "
                + "and keeps to it unless you say otherwise. One line, at most \(DecisionBoard.maxLength) characters."
                + listing,
            initialValue: "",
            placeholder: "Every timestamp is stored in UTC.",
            confirmTitle: "Add"
        ) else { return }
        apply(.pin(repository: repository, text: text), on: board)
    }

    func unpinDecision(_ number: Int, in repository: String) {
        guard let board = decisionBoard else { return }
        let pinned = board.current.decisions(for: repository)
        guard pinned.indices.contains(number - 1) else { return }
        guard Alerts.confirm(
            title: "Remove this project rule from “\(repository)”?",
            message: "“\(pinned[number - 1].text)”\n\nSessions that were told about it read that it no longer "
                + "applies, if it was the last one; otherwise they read the rules as they now are.",
            confirmTitle: "Remove"
        ) else { return }
        apply(.remove(repository: repository, number: number), on: board)
    }

    private func apply(_ change: DecisionBoardExchange.Change, on board: DecisionBoardService) {
        switch board.apply(change) {
        case .failure(let error):
            store.reportError("The decision was not changed: \(error.sentence).")
        case .success:
            store.clearError()
        }
        rebuildContent()
    }
}
