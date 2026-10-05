import Foundation

/// What travels to and from the decision board (D105).
///
/// Two doors. `/decisions` is the command line's and the panel's, behind the
/// token: pin, take off, list. `/mod/decisions` is the companion mod's, and
/// what it answers enters a conversation as context the model reads — so it is
/// proven both ways with the permission key, like a permission (D80): the
/// token travels with every hook, and a project that sets `LAMPBOARD_HOME` and
/// listens on the port must not be able to put words in front of a model.
public enum DecisionBoardExchange {

    public enum Change: Equatable, Sendable {
        case pin(repository: String, text: String)
        case remove(repository: String, number: Int)
    }

    /// `{"repo": …, "text": …}` pins, `{"repo": …, "remove": n}` takes off.
    public static func change(_ body: Data) -> Change? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let repository = object["repo"] as? String
        else { return nil }
        if let text = object["text"] as? String { return .pin(repository: repository, text: text) }
        if let number = object["remove"] as? Int { return .remove(repository: repository, number: number) }
        return nil
    }

    public static func proofMessage(nonce: String, session: String) -> String {
        "board:\(nonce):\(session)"
    }

    /// The session asking, when its request is proven with the key.
    public static func provenSession(_ body: Data, nonce: String?, proof: String?, key: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["v"] as? Int == 1,
              let session = object["session"] as? String, ModReport.isSessionId(session),
              let nonce, let proof,
              PermissionGate.proves(proof, PermissionGate.mac(key: key, message: proofMessage(nonce: nonce, session: session)),
                                    nonce: nonce)
        else { return nil }
        return session
    }

    /// The mod's answer: `board <version> <signature>`, a newline, the text.
    ///
    /// The version is `-` when nothing is pinned. Then the text is the sentence
    /// that withdraws what an earlier version said — the mod hands it over only
    /// to a session that was told something — or nothing, for a session with no
    /// repository. The signature covers the nonce, the version and the text.
    public static func answer(board: DecisionBoard, repository: String?, nonce: String, key: String) -> String {
        // A name no one could have pinned under is no repository at all.
        let repository = repository.flatMap { DecisionBoard.isRepositoryName($0) ? $0 : nil }
        let version = repository.flatMap { board.version(for: $0) } ?? "-"
        let text = repository.map { board.contextBlock(for: $0) ?? DecisionBoard.withdrawnBlock } ?? ""
        let signature = PermissionGate.mac(key: key, message: signedMessage(nonce: nonce, version: version, text: text))
        return "board \(version) \(signature)\n\(text)"
    }

    public static func signedMessage(nonce: String, version: String, text: String) -> String {
        "pinned:\(nonce):\(version):\(text)"
    }
}
