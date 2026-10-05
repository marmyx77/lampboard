import Foundation
import LampBoardCore

/// Allow and Deny from the panel (D73, D80): the asks the companion mod puts to
/// the panel, waiting, and the answers that release them.
///
/// The rules are `PermissionGate`'s. This keeps the book on the main actor,
/// holds each asking connection on the server's queue until its answer or its
/// 55 seconds, and publishes what waits for the queue to draw.
@MainActor
final class PermissionDesk: ObservableObject {

    @Published private(set) var pending: [PermissionGate.Request] = []
    /// The asks that went back to their dialog, by `WaitingQueue.heldKey`:
    /// expired, or given up on. The latest few, so the queue can say so.
    private(set) var returned: Set<String> = []

    private let preferences: Preferences
    private var book = PermissionGate.Book() { didSet { box.publish(book.pending) } }
    private let box = Listing()
    private var replies: [String: Reply] = [:]
    private var timer: Timer?

    /// An answer handed from the main actor to the waiting connection; the
    /// semaphore orders the write before the read.
    private final class Reply: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var verdict: PermissionGate.Verdict = .ask
        /// A question's chosen option (D86); `nil` sends it to the dialog.
        var choice: Int?
    }

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    /// The server's side: a body and its proof in, a signed verdict out.
    /// Called on the server's queue, never on the main actor, since it waits.
    /// An ask not proven with the permission key is answered `ask`, unsigned:
    /// the mod trusts only a signed answer, so that is its dialog either way.
    nonisolated func check(_ body: Data, nonce: String?, proof: String?, key: String) -> String {
        let ask = PermissionGate.Verdict.ask.rawValue
        guard let request = PermissionGate.decode(body, at: Date()) else {
            Diagnostics.log("check: an ask that does not read")
            return ask
        }
        guard let nonce, let proof,
              PermissionGate.isGenuine(key: key, nonce: nonce, proof: proof, session: request.sessionId, call: request.callId)
        else {
            Diagnostics.log("check: \(request.callId) not proven with the key (nonce \(nonce != nil), proof \(proof?.count ?? 0))")
            return ask
        }
        let admitted = DispatchSemaphore(value: 0)
        let box = Box()
        Task { @MainActor in
            if !box.abandoned { box.reply = self.admit(request) }
            admitted.signal()
        }
        guard admitted.wait(timeout: .now() + 2) == .success, let reply = box.reply else {
            // Gave up on a busy main actor: the ask must not be booked later,
            // for nobody; and if it was, only this connection's own booking is
            // withdrawn, never another's for the same call (review findings).
            Task { @MainActor in
                box.abandoned = true
                if let mine = box.reply { self.withdraw(mine, session: request.sessionId, call: request.callId) }
            }
            return PermissionGate.signed(.ask, key: key, nonce: nonce)
        }
        // Past the once-a-second expiry, so a late answer is never taken by an
        // ask whose connection has already gone back to the dialog.
        _ = reply.done.wait(timeout: .now() + PermissionGate.answerWithin + 2)
        return PermissionGate.signed(reply.verdict, key: key, nonce: nonce)
    }

    /// The server's side of a question (D86): proven with the key under its
    /// own prefix, held like a permission, answered with the chosen option's
    /// index — or `ask`, the session's own dialog.
    nonisolated func question(_ body: Data, nonce: String?, proof: String?, key: String) -> String {
        let ask = PermissionGate.Verdict.ask.rawValue
        guard let request = QuestionGate.decode(body, at: Date()) else {
            Diagnostics.log("question: one that does not read")
            return ask
        }
        guard let nonce, let proof,
              QuestionGate.isGenuine(key: key, nonce: nonce, proof: proof, session: request.sessionId, call: request.callId)
        else {
            Diagnostics.log("question: \(request.callId) not proven with the key")
            return ask
        }
        guard let reply = hold(request) else { return QuestionGate.signed(choice: nil, key: key, nonce: nonce) }
        _ = reply.done.wait(timeout: .now() + QuestionGate.answerWithin + 2)
        return QuestionGate.signed(choice: reply.choice, key: key, nonce: nonce)
    }

    /// Books the request on the main actor and hands back its reply, or `nil`
    /// when it is not the panel's to answer — switched off, full, or a main
    /// actor too busy to say, where a booking made late is withdrawn.
    nonisolated private func hold(_ request: PermissionGate.Request) -> Reply? {
        let admitted = DispatchSemaphore(value: 0)
        let box = Box()
        Task { @MainActor in
            if !box.abandoned { box.reply = self.admit(request) }
            admitted.signal()
        }
        guard admitted.wait(timeout: .now() + 2) == .success, let reply = box.reply else {
            Task { @MainActor in
                box.abandoned = true
                if let mine = box.reply { self.withdraw(mine, session: request.sessionId, call: request.callId) }
            }
            return nil
        }
        return reply
    }

    /// One of a held question's options, from a click or a digit (D86).
    @discardableResult
    func choose(session: String, call callId: String, index: Int) -> Bool {
        guard let held = book.pending.first(where: { $0.sessionId == session && $0.callId == callId }),
              held.options.indices.contains(index),
              book.answer(session: session, call: callId, .allow) != nil,
              let reply = replies.removeValue(forKey: Self.key(session, callId)) else { return false }
        reply.choice = index
        reply.done.signal()
        pending = book.pending
        return true
    }

    /// `{"session","id","verdict"}` from the server; `false` when nothing waits
    /// under that session and call.
    nonisolated func answer(body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let session = object["session"] as? String,
              let id = object["id"] as? String
        else { return false }
        let choice = object["choice"] as? Int
        let verdict = (object["verdict"] as? String).flatMap(PermissionGate.Verdict.init(rawValue:))
        guard choice != nil || verdict != nil else { return false }
        let done = DispatchSemaphore(value: 0)
        let result = Flag()
        Task { @MainActor in
            if let choice {
                result.value = self.choose(session: session, call: id, index: choice)
            } else if let verdict {
                result.value = self.answer(session: session, call: id, verdict)
            }
            done.signal()
        }
        return done.wait(timeout: .now() + 2) == .success && result.value
    }

    /// The panel's answer: a click, a key, or `/check/answer` on a test's fake home.
    @discardableResult
    func answer(session: String, call callId: String, _ verdict: PermissionGate.Verdict) -> Bool {
        // A question is answered by a choice, never by Allow or Deny; `ask`
        // sends either back to its dialog.
        if verdict != .ask, book.pending.contains(where: { $0.sessionId == session && $0.callId == callId && !$0.options.isEmpty }) {
            return false
        }
        guard let given = book.answer(session: session, call: callId, verdict),
              let reply = replies.removeValue(forKey: Self.key(session, callId)) else { return false }
        reply.verdict = given
        reply.done.signal()
        if given == .ask { remember(returned: [WaitingQueue.heldKey(session: session, call: callId)]) } else { onAnswered?(session) }
        pending = book.pending
        return true
    }

    /// Told when an ask is answered from the panel, Allow or Deny: the
    /// tour's "allow" step (D120).
    var onAnswered: ((String) -> Void)?

    /// The trial's permission (D120): booked like a mod's ask, with nobody
    /// waiting on a connection for its answer.
    func stage(_ request: PermissionGate.Request) {
        // Booked again after its time ran out: it never went back to a dialog.
        returned.remove(WaitingQueue.heldKey(session: request.sessionId, call: request.callId))
        _ = admit(request)
    }

    private func withdraw(_ reply: Reply, session: String, call callId: String) {
        guard replies[Self.key(session, callId)] === reply else { return }
        answer(session: session, call: callId, .ask)
    }

    private func admit(_ request: PermissionGate.Request) -> Reply? {
        guard preferences.permissionsFromPanel, book.add(request) else { return nil }
        let reply = Reply()
        replies[Self.key(request.sessionId, request.callId)] = reply
        pending = book.pending
        return reply
    }

    /// Asks whose time is up go back to their dialog: `ask`, the default.
    private func expire() {
        let gone = book.expired(at: Date())
        guard !gone.isEmpty else { return }
        for request in gone { replies.removeValue(forKey: Self.key(request.sessionId, request.callId))?.done.signal() }
        remember(returned: gone.map { WaitingQueue.heldKey(session: $0.sessionId, call: $0.callId) })
        pending = book.pending
    }

    private func remember(returned keys: [String]) {
        returned = Set(keys).union(returned.count > 32 ? [] : returned)
    }

    /// What waits, as JSON, readable from the server's queue without a hop.
    nonisolated var listing: Data { box.current() }

    private final class Listing: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data("[]".utf8)
        func publish(_ pending: [PermissionGate.Request]) {
            let rows = pending.map { ["session": $0.sessionId, "id": $0.callId, "tool": $0.tool, "line": $0.line, "options": $0.options] as [String: Any] }
            let encoded = (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
            lock.lock(); data = encoded; lock.unlock()
        }
        func current() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private static func key(_ session: String, _ call: String) -> String { WaitingQueue.heldKey(session: session, call: call) }

    private final class Box: @unchecked Sendable { var reply: Reply?; var abandoned = false }
    private final class Flag: @unchecked Sendable { var value = false }
}
