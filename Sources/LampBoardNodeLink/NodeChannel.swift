import Foundation
import LampBoardCore

/// One open channel to a machine, as the `v1` link sees it: bytes that arrive,
/// bytes to send, and an end.
///
/// The ssh channel is one implementation; the tests give a `V1Service` in
/// memory behind the same three calls, so the link above it is verified on
/// every platform without a network.
public protocol NodeByteChannel: AnyObject {
    /// Every chunk as it arrives, in order. Finishes when the channel ends,
    /// whoever ended it.
    var inbound: AsyncStream<[UInt8]> { get }
    /// Sends `bytes`, cut in writes of at most `V1Frame.writePiece`.
    func write(_ bytes: [UInt8]) async throws
    /// Ends the channel. Closing twice, or after the machine did, is not an error.
    func close() async
}

/// Writes in pieces no larger than `V1Frame.writePiece` (32 KiB).
///
/// swift-nio-ssh does not split a write larger than the channel's window: 9.5
/// MB written at once sent nothing in 30 seconds, the same bytes in 32 KiB
/// pieces went at once (S-R). Every write of NodeLink goes through here.
enum NodeWrites {
    static func inPieces(_ bytes: [UInt8], _ write: ([UInt8]) async throws -> Void) async throws {
        for piece in V1Frame.pieces(bytes) {
            try await write(piece)
        }
    }
}
