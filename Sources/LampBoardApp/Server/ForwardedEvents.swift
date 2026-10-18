import Foundation
import LampBoardCore

/// What a node's `lampd` forwarded to this Mac (W5, §2.3): it carries
/// `MacNodeLink.eventHeader`. An event that arrived twice — both ways, during a
/// switch of the tunnel's port — is taken once (E3), and a route of the Mac's
/// own is refused whoever asks for it through a node (R2). The rule is
/// `ForwardedByNode`'s; this keeps the memory, from the server's threads.
final class ForwardedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var ledger = EventLedger()

    /// The answer when the request is not to be handled, or `nil` to go on.
    func answer(to request: HTTPRequest) -> Data? {
        let verdict = lock.withLock {
            ForwardedByNode.verdict(path: request.path, method: request.method,
                                    eventId: request.header(MacNodeLink.eventHeader), ledger: &ledger)
        }
        switch verdict {
        case .take:
            return nil
        case .duplicate:
            return HTTPRequestParser.response(status: 200, reason: "OK", body: "already taken")
        case .refuse(let why):
            Diagnostics.log("refused \(request.method) \(request.path) forwarded by a node: \(why)")
            return HTTPRequestParser.response(status: 403, reason: "Forbidden", body: why)
        }
    }
}
