import AppKit
import Combine
import LampBoardCore

/// What LampMaster's cards do to the panel: raise a session, end one, take a row
/// off, copy a question.
///
/// A file of its own for the reason `PanelAllowance.swift` is one: the
/// controller is at the size this project refuses to pass, and this is a whole
/// subject. Every action reuses what the rows already do — the same raise, the
/// same confirmation before ending a process, the same dismissal — so a card
/// can never do something a row could not.
extension PanelController {

    func lampMasterActions(for service: LampMasterService) -> LampMasterActions {
        LampMasterActions(
            perform: { [weak self, weak service] shown in
                guard let self, let service else { return }
                if self.carryOut(shown.suggestion) { service.react(to: shown.id, with: .accepted) }
            },
            open: { [weak self] id in self?.openLampMasterSession(id) },
            name: { [weak self] id in self?.lampMasterName(of: id) ?? id },
            askQuietly: { [weak self] shown in self?.quietQuestion(shown.suggestion) }
        )
    }

    /// The line appears and goes with the switch, and the window is sized by
    /// formula: it has to be remeasured, as for the allowance strip.
    func observeLampMaster() {
        guard let lampMaster else { return }
        lampMaster.$snapshot
            .map(\.enabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.resizeToFit(self.store.state)
            }
            .store(in: &cancellables)
    }

    var showsLampMaster: Bool { lampMaster?.snapshot.enabled == true }

    // MARK: - Carrying out

    /// `true` when the action happened; a refusal or a cancelled dialog is not
    /// an acceptance.
    private func carryOut(_ suggestion: LampMasterAdvice.Suggestion) -> Bool {
        guard let id = LampMasterLine.subject(of: suggestion) else { return false }
        switch suggestion.action.kind {
        case .open, .handoff:
            return openLampMasterSession(id)
        case .ask, .reply:
            // The row first: a question copied for a session that has gone would
            // have replaced whatever was on the clipboard for nothing.
            guard let member = rowSession(id) else { return tellGone(id) }
            if let text = suggestion.action.question {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            // Into the Plancia's composer, to read, change and send: LampMaster
            // proposes, the person sends (D61, D73, D85). A session on another
            // machine has no Plancia here: raised, with the text copied.
            guard let text = suggestion.action.question, !member.session.workspace.isRemote else {
                activate(session: member)
                return true
            }
            openPlancia(sessionId: member.session.id)
            // Only into that session's Plancia: one that did not open leaves the
            // text where the person can see it, on the clipboard.
            guard plancia.sessionId == member.session.id else { return true }
            plancia.thread?.proposed = text
            return true
        case .close:
            guard let member = rowSession(id) else { return tellGone(id) }
            terminate(session: member)
            return store.sessions.first { $0.id == member.id } == nil
        case .archive:
            guard let member = rowSession(id) else { return tellGone(id) }
            dismiss(session: member)
            return true
        case .none:
            return false
        }
    }

    /// The card's question put to its session as a side question (D82): only
    /// when the action asks something, that session's mod can answer, and
    /// sending is on — the switch every word into a session goes behind.
    private func quietQuestion(_ suggestion: LampMasterAdvice.Suggestion) -> (@MainActor () async -> String)? {
        guard suggestion.action.kind == .ask || suggestion.action.kind == .reply,
              let question = suggestion.action.question,
              preferences.messageSendingEnabled,
              let id = LampMasterLine.subject(of: suggestion), let member = rowSession(id),
              let desk = askDesk, desk.askable.contains(member.session.id) else { return nil }
        let host = member.session.workspace.host
        let session = member.session.id
        return { await desk.ask(sessionId: session, question: question, host: host) }
    }

    /// Raises the session if it has a row; a closed one has nothing to raise,
    /// and saying so beats a click that does nothing.
    @discardableResult
    func openLampMasterSession(_ id: String) -> Bool {
        guard let member = rowSession(id) else { return tellGone(id) }
        activate(session: member)
        return true
    }

    func lampMasterName(of id: String) -> String {
        guard let member = rowSession(id) else { return id }
        return member.name
    }

    /// The row's conversation with this short id, as the row menu would hand it.
    /// Eight characters, as the frame gave them: the validator accepts an id the
    /// model wrote longer ("aaaaaaaa (the exporter)") by its first eight, and so
    /// must the lookup.
    private func rowSession(_ id: String) -> RowSession? {
        let short = String(id.prefix(8))
        guard short.count == 8, let session = store.sessions.first(where: { $0.id.hasPrefix(short) }) else { return nil }
        let name = RowNames.name(ofSession: session.id, in: preferences.rowNames)
            ?? session.title ?? session.workspace.name
        return RowSession(id: session.id, ordinal: 1, name: name, session: session)
    }

    private func tellGone(_ id: String) -> Bool {
        Alerts.tell(
            title: "That session is not in the panel",
            message: "Session \(id) has closed, or is on a machine this panel does not show. "
                + "Claude Code can resume it with claude --resume, from its folder."
        )
        return false
    }
}
