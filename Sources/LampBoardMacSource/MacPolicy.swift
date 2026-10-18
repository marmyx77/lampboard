import Foundation
import LampBoardCore

/// Who is at the other end of one connection, as the server established it.
public enum MacPeer: Equatable, Sendable {
    /// The `pair` account with the right code, inside the window.
    case pairing
    /// A paired device, with the key it used.
    case device(id: String, role: V1Role)

    public var v1Peer: V1Peer? {
        guard case .device(let id, let role) = self else { return nil }
        return V1Peer(device: id, role: role)
    }
}

/// Who may ask what of the Mac's server (§2.4, §2.6, Q17), in one place.
///
/// The read key opens `v1` and nothing else. The action key opens `v1` too —
/// the devices are a `v1` message — and, only while the person has turned on
/// «Terminal and actions from iPhone & iPad», the terminals and the named
/// actions. The `pair` account opens the pairing exchange and nothing else.
/// Anything this does not name is refused: a shell, a subsystem but `v1`, an
/// exec line `MacRequest` cannot read.
public enum MacPolicy {

    public enum Verdict: Equatable, Sendable {
        case allow
        case refuse(String)
    }

    public static func decide(_ request: MacRequest?, from peer: MacPeer, terminalsOn: Bool, hasTerminal: Bool) -> Verdict {
        guard let request else { return .refuse("not a request this Mac takes") }
        switch (peer, request) {
        case (.pairing, .pair):
            return .allow
        case (.pairing, _):
            return .refuse("the pairing account only pairs")
        case (.device, .pair):
            return .refuse("a paired device does not pair again")
        case (.device, .v1):
            return hasTerminal ? .refuse("v1 is not a terminal") : .allow
        case (.device(_, .read), _):
            return .refuse("the read key opens v1 and nothing else")
        case (.device(_, .action), .attach):
            guard terminalsOn else { return .refuse(offWords) }
            return hasTerminal ? .allow : .refuse("a terminal needs a pty-req first")
        case (.device(_, .action), .action), (.device(_, .action), .background), (.device(_, .action), .palette):
            guard terminalsOn else { return .refuse(offWords) }
            return hasTerminal ? .refuse("an action is not a terminal") : .allow
        }
    }

    /// Whether a `pty-req` may be granted at all: only to the action key, with the switch on.
    public static func mayAskForTerminal(_ peer: MacPeer?, terminalsOn: Bool) -> Bool {
        guard case .device(_, .action)? = peer else { return false }
        return terminalsOn
    }

    /// The refusal while the switch is off: said, so the phone can say it.
    public static let offWords = "Terminal and actions from iPhone & iPad is turned off on this Mac"
}
