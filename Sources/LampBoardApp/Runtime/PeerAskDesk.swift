import Foundation
import LampBoardCore

/// Questions to live sessions without disturbing them (D82): which sessions can
/// be asked — their mod said `ask` when they started — and the questions
/// waiting for the fork's reply.
@MainActor
final class PeerAskDesk: ObservableObject {

    /// The sessions whose mod can answer, by full id.
    @Published private(set) var askable: Set<String> = []

    private var waiting: [String: CheckedContinuation<String, Never>] = [:]
    private let sender = PeerSender()

    /// Every mod report passes here: a start or an end says who can be asked,
    /// an answer is a reply to one of ours.
    func heard(_ report: ModReport) {
        switch report {
        case .start(let session, let start):
            if start.features.contains(PeerAsk.feature) { askable.insert(session) } else { askable.remove(session) }
        case .end(let session, _):
            askable.remove(session)
        case .answer(_, let answer):
            waiting.removeValue(forKey: answer.id)?.resume(returning: Self.said(answer))
        case .measure, .tool:
            break
        }
    }

    /// The question, through the session's box; the reply, or what went wrong.
    func ask(sessionId: String, question: String) async -> String {
        guard askable.contains(sessionId) else { return "This session's LampBoard mod cannot answer yet." }
        guard let key = TokenStore(url: AppConfig.checkKeyURL).read() else { return "LampBoard has no key to ask with." }
        let nonce = UUID().uuidString
        guard let content = PeerAsk.message(question: question, nonce: nonce, session: sessionId, key: key) else {
            return "Nothing to ask, or too long for a side question."
        }
        let sender = self.sender
        // Waiting before it is sent, so an answer can never arrive to nobody.
        return await withCheckedContinuation { continuation in
            waiting[nonce] = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + PeerAsk.answerWithin) { [weak self] in
                self?.waiting.removeValue(forKey: nonce)?.resume(returning: "No answer within a minute.")
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                let sent = sender.send(content: content, to: sessionId)
                // Unwrapped before the hop: inside it, Swift 6 rejects the capture.
                guard let self else { return }
                await MainActor.run {
                    guard case .failure(let failure) = sent else {
                        return Diagnostics.log("ask \(sessionId.prefix(8)): \(question.count) chars, without a turn")
                    }
                    let said = failure.description.prefix(1).uppercased() + failure.description.dropFirst() + "."
                    self.waiting.removeValue(forKey: nonce)?.resume(returning: said)
                }
            }
        }
    }

    private static func said(_ answer: ModReport.Answer) -> String {
        if let text = answer.text { return text }
        switch answer.reason {
        case "nothing-to-fork": return "It has nothing to answer from yet: no reply in its conversation."
        case let reason?: return "It could not answer (\(reason))."
        case nil: return "It gave no answer."
        }
    }
}
