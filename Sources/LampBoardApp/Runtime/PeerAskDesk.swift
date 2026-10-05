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

    /// The question, through the session's box — over ssh when the session is
    /// on another machine (B3), the answer coming back through its tunnel; the
    /// reply, or what went wrong.
    func ask(sessionId: String, question: String, host: String? = nil) async -> String {
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
                let failed: String? = if let host {
                    RemotePeerSender.send(content: content, to: sessionId, on: host).failureText { "Not asked on \(host): \($0.short)." }
                } else {
                    sender.send(content: content, to: sessionId).failureText {
                        $0.description.prefix(1).uppercased() + $0.description.dropFirst() + "."
                    }
                }
                // Unwrapped before the hop: inside it, Swift 6 rejects the capture.
                guard let self else { return }
                await MainActor.run {
                    guard let failed else {
                        return Diagnostics.log("ask \(sessionId.prefix(8)): \(question.count) chars, without a turn")
                    }
                    self.waiting.removeValue(forKey: nonce)?.resume(returning: failed)
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

private extension Result {
    /// The failure in words, or `nil` on success.
    func failureText(_ words: (Failure) -> String) -> String? {
        if case .failure(let failure) = self { return words(failure) }
        return nil
    }
}
