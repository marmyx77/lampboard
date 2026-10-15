import Foundation

/// How a `v1` message travels on a byte stream (§2.2 of the mobile plan): the
/// length in decimal, a space, the JSON, a newline.
///
/// The stream is the stdin and stdout of an ssh channel — `lampd v1-stdio` behind
/// OpenSSH, or a channel of the Mac's own ssh server — and nothing in it marks
/// where one message ends. A newline alone would do while every writer escapes
/// its newlines; the length is there for the day one does not, and for a reader
/// that must refuse a message too large to buffer before it has buffered it.
public enum V1Frame {

    /// The largest message either side accepts. A whole state of a machine with
    /// a hundred sessions is under 200 KB; a transcript is cut long before this.
    public static let maxBytes = 4 * 1024 * 1024

    /// The largest single write. swift-nio-ssh does not split a write larger than
    /// the channel's window: 9.5 MB written at once sent nothing in 30 seconds
    /// (S-R). Every writer cuts its bytes with `pieces` before writing them.
    public static let writePiece = 32 * 1024

    /// The frame around one message's JSON.
    public static func encode(_ json: [UInt8]) -> [UInt8] {
        Array("\(json.count) ".utf8) + json + [0x0A]
    }

    /// `bytes` cut in writes of at most `size` bytes, in order.
    public static func pieces(_ bytes: [UInt8], size: Int = writePiece) -> [[UInt8]] {
        guard size > 0 else { return [bytes] }
        return stride(from: 0, to: bytes.count, by: size).map { start in
            Array(bytes[start..<min(start + size, bytes.count)])
        }
    }
}

public enum V1FrameError: Error, Equatable, Sendable {
    /// The header is not a decimal length followed by a space.
    case badLength
    /// The frame announces more than `V1Frame.maxBytes`.
    case tooLarge
    /// The byte after the announced length is not the newline.
    case lengthMismatch
}

/// Takes the bytes of a stream as they come and gives back whole frames.
///
/// Once it has failed it keeps failing: after a bad header the stream is out of
/// step, and nothing after it can be trusted to start where a frame starts. The
/// side that sees the error says so and closes.
public struct V1FrameReader: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0
    private var failure: V1FrameError?

    /// The longest header: seven digits for 4 MiB, and the space.
    private static let maxHeader = String(V1Frame.maxBytes).count + 1

    public init() {}

    public mutating func push(_ bytes: [UInt8]) {
        guard failure == nil else { return }
        buffer.append(contentsOf: bytes)
    }

    /// The next whole frame's JSON, `nil` while it has not all arrived.
    public mutating func next() throws -> [UInt8]? {
        if let failure { throw failure }
        do {
            return try take()
        } catch let error as V1FrameError {
            failure = error
            buffer = []
            start = 0
            throw error
        }
    }

    private mutating func take() throws -> [UInt8]? {
        let available = buffer.count - start
        guard available > 0 else { return nil }
        let window = buffer[start..<min(buffer.count, start + Self.maxHeader)]
        guard let space = window.firstIndex(of: 0x20) else {
            if window.count >= Self.maxHeader || window.contains(where: { !Self.isDigit($0) }) {
                throw V1FrameError.badLength
            }
            return nil
        }
        let digits = buffer[start..<space]
        guard !digits.isEmpty, digits.allSatisfy(Self.isDigit),
              let length = Int(String(decoding: digits, as: UTF8.self)) else {
            throw V1FrameError.badLength
        }
        guard length <= V1Frame.maxBytes else { throw V1FrameError.tooLarge }
        let body = space + 1
        guard buffer.count >= body + length + 1 else { return nil }
        guard buffer[body + length] == 0x0A else { throw V1FrameError.lengthMismatch }
        let frame = Array(buffer[body..<(body + length)])
        start = body + length + 1
        compact()
        return frame
    }

    /// Drops what has been read, once it is worth the copy.
    private mutating func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 64 * 1024 {
            buffer.removeFirst(start)
            start = 0
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
}
