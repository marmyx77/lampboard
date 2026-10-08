import Foundation

/// Claude Code's look (D134): where the helper draws the conversation like the
/// VS Code panel. The helper asks `GET /mod/look` for its session before it
/// draws, and draws its own only on `{"v":1,"on":true}`; any other answer, or
/// none, leaves Claude Code's drawing untouched.
public enum ModLook {

    /// Where the look is on.
    public enum Reach: String, CaseIterable, Sendable {
        /// Never: Claude Code's own drawing everywhere.
        case off
        /// In the sessions open in a LampBoard window, where nobody chose a
        /// terminal's look: the default.
        case live
        /// In every session the helper runs in, whatever terminal shows it.
        case everywhere

        public var label: String {
            switch self {
            case .off: return "Off"
            case .live: return "In LampBoard's windows"
            case .everywhere: return "Everywhere"
            }
        }

        public static func named(_ raw: String?) -> Reach { raw.flatMap(Reach.init(rawValue:)) ?? .live }
    }

    /// Whether `session` is drawn with the look. A session id the helper could
    /// not have sent is never on.
    public static func isOn(session: String?, reach: Reach, inLiveView: Set<String>) -> Bool {
        guard let session, ModReport.isSessionId(session) else { return false }
        switch reach {
        case .off: return false
        case .live: return inLiveView.contains(session)
        case .everywhere: return true
        }
    }

    /// The answer, in the one shape the helper reads.
    public static func answer(on: Bool) -> String { on ? #"{"v":1,"on":true}"# : #"{"v":1,"on":false}"# }
}
