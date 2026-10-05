import Foundation

/// What travels between the mod and the panel before a session writes a file
/// (§4.4, the radar). The answer turns an edit the engine would allow into a
/// question to the person, with a sentence that names another session, so it is
/// proven both ways with the permission key like every other word the panel puts
/// in front of a session (D80, D105).
public enum RadarExchange {

    public struct Request: Sendable, Equatable {
        public let session: String
        public let file: String
    }

    public static func proofMessage(nonce: String, session: String, file: String) -> String {
        "radar:\(nonce):\(session):\(file)"
    }

    public static func provenRequest(_ body: Data, nonce: String?, proof: String?, key: String) -> Request? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["v"] as? Int == 1,
              let session = object["session"] as? String, ModReport.isSessionId(session),
              let file = object["file"] as? String, file.hasPrefix("/"), file.count <= 1024,
              let nonce, let proof,
              PermissionGate.proves(proof, PermissionGate.mac(key: key, message: proofMessage(nonce: nonce, session: session, file: file)),
                                    nonce: nonce)
        else { return nil }
        return Request(session: session, file: file)
    }

    /// "routes.ts was written by “api” 12 minutes ago: check with it before
    /// changing it." The other session's name on one line, its controls gone.
    public static func reason(file: String, by name: String, minutesAgo: Int) -> String {
        let base = LampMasterLookup.clean((file as NSString).lastPathComponent, to: 80)
        let who = LampMasterLookup.clean(name, to: 60)
        let when = minutesAgo < 1 ? "just now" : minutesAgo == 1 ? "a minute ago" : "\(minutesAgo) minutes ago"
        return "\(base) was written by \u{201C}\(who)\u{201D} \(when): check with it before changing it."
    }

    /// `clear <sig>`, or `written <sig>` and the sentence on the next line.
    public static func answer(reason: String?, nonce: String, key: String) -> String {
        let verdict = reason == nil ? "clear" : "written"
        let signature = PermissionGate.mac(key: key, message: "radar:\(nonce):\(verdict):\(reason ?? "")")
        return reason.map { "\(verdict) \(signature)\n\($0)" } ?? "\(verdict) \(signature)"
    }
}
