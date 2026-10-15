import LampBoardCore
import Foundation
import TestKit

/// How `v1` messages travel on a byte stream: the stdin and stdout of an ssh
/// channel, where nothing marks where one message ends and the next begins.
enum V1FrameSuite {

    private static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    static let suite = TestSuite("v1 frames on a byte stream", [

        TestCase("A frame is the length, a space, the message and a newline") { t in
            t.expectEqual(V1Frame.encode(bytes(#"{"op":"state"}"#)), bytes("14 {\"op\":\"state\"}\n"), "frame")
        },

        TestCase("Frames come out whole however the stream cuts them") { t in
            let stream = V1Frame.encode(bytes(#"{"a":1}"#)) + V1Frame.encode(bytes(#"{"b":22}"#))
            // One byte at a time: the worst a pipe can do.
            var reader = V1FrameReader()
            var out: [[UInt8]] = []
            for byte in stream {
                reader.push([byte])
                while let frame = try? reader.next() { out.append(frame) }
            }
            t.expectEqual(out, [bytes(#"{"a":1}"#), bytes(#"{"b":22}"#)], "frames")
        },

        TestCase("Half a frame is not a frame yet") { t in
            var reader = V1FrameReader()
            reader.push(bytes("8 {\"a\":"))
            t.expectNil((try? reader.next()) ?? nil, "nothing yet")
            reader.push(bytes("12}\n"))
            t.expectEqual((try? reader.next()) ?? nil, bytes(#"{"a":12}"#), "the frame")
        },

        TestCase("A length that does not match what follows is an error, not a guess") { t in
            var reader = V1FrameReader()
            reader.push(bytes("3 {\"a\":1}\n"))
            t.expectThrows(V1FrameError.lengthMismatch) { _ = try reader.next() }
        },

        TestCase("A header that is not a number is an error") { t in
            var reader = V1FrameReader()
            reader.push(bytes("{\"op\":\"state\"}\n"))
            t.expectThrows(V1FrameError.badLength) { _ = try reader.next() }
        },

        TestCase("A frame larger than the limit is refused before it is buffered") { t in
            var reader = V1FrameReader()
            reader.push(bytes("\(V1Frame.maxBytes + 1) "))
            t.expectThrows(V1FrameError.tooLarge) { _ = try reader.next() }
        },

        TestCase("A reader that failed stays failed") { t in
            // After one bad header the stream is out of step: nothing after it can
            // be trusted to start where a frame starts.
            var reader = V1FrameReader()
            reader.push(bytes("x\n"))
            _ = try? reader.next()
            reader.push(V1Frame.encode(bytes("{}")))
            t.expectThrows(V1FrameError.badLength) { _ = try reader.next() }
        },

        TestCase("Writes are cut in pieces of at most 32 KiB") { t in
            // Measured in S-R: swift-nio-ssh does not split a write larger than the
            // channel's window, and 9.5 MB in one write sent nothing in 30 s.
            let big = [UInt8](repeating: 0x61, count: 100_000)
            let pieces = V1Frame.pieces(big)
            t.expectEqual(pieces.count, 4, "pieces")
            t.expect(pieces.allSatisfy { $0.count <= 32 * 1024 }, "every piece fits")
            t.expectEqual(pieces.flatMap { $0 }, big, "nothing lost or reordered")
            t.expectEqual(V1Frame.pieces([]).count, 0, "nothing to write")
        },
    ])
}
