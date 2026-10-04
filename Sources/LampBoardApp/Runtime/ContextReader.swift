import LampBoardCore
import Foundation

/// Reads how full a session's context is, from the end of its transcript.
///
/// Shaped after `TranscriptPreviewReader`, for the same three reasons and with
/// the same three defences: only the tail is read, it widens rather than reading
/// the file, and it is cached on the file's size — a transcript only grows, so
/// an unchanged size is an unchanged answer and a refresh costs one `stat` per
/// row. The file this was measured against is 118 MB; the record it needs sits
/// about four kilobytes from the end.
///
/// It widens for a different reason than the preview does. The preview widens
/// when the tail holds nothing conversational; this widens when the tail holds
/// no **reply**, which happens during a long run of tool calls — exactly when
/// somebody is most likely to be watching the number.
///
/// WHAT IT DELIBERATELY DOES NOT DO
/// It never opens anything but the file it was given, and never globs. A
/// subagent's transcript lives in a subdirectory and carries the **parent's**
/// session id: two files, same id, and one real measurement found them reading
/// 41,990 and 987,346 within the same minute. A glob would report the subagent's
/// context as the session's, and be wrong by a factor of twenty without ever
/// looking wrong.
/// An `actor`, and that is the load-bearing word. The cache has to live
/// somewhere, and a plain class owned by the main-actor store would make every
/// `await` on it hop back to the main thread — putting a seek into a
/// hundred-megabyte file on the thread that draws the panel, which is the exact
/// defect this project spent a day removing everywhere else.
actor ContextReader {

    /// First slice: past any single reply, far short of a file.
    private static let firstSlice = 32 * 1024

    /// 32 KB, then 256 KB, then 2 MB, then give up. A sweep of twelve thousand
    /// real transcripts put the answer inside 32 KB in 96.8% of them; the
    /// widenings are for the rest, and the giving up is for the file that is one
    /// enormous record.
    private static let widenings = 3

    private struct Cached {
        let size: UInt64
        let reading: ContextReading?
    }

    private var cache: [String: Cached] = [:]

    /// The reading for a session, or `nil` when there is nothing to read yet —
    /// a session whose transcript does not exist, which is the ordinary state of
    /// one that has not answered.
    func reading(
        ofTranscriptAt path: String,
        for sessionId: String,
        harness: Harness = .claudeCode
    ) -> ContextReading? {
        guard !path.isEmpty, let size = fileSize(of: path) else { return nil }

        if let cached = cache[sessionId], cached.size == size {
            return cached.reading
        }

        let reading = read(path: path, size: size, harness: harness)
        cache[sessionId] = Cached(size: size, reading: reading)
        return reading
    }

    func forget(sessionId: String) {
        cache.removeValue(forKey: sessionId)
    }

    // MARK: - Internals

    private func read(path: String, size: UInt64, harness: Harness) -> ContextReading? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var slice = UInt64(Self.firstSlice)
        for _ in 0..<Self.widenings {
            let wholeFile = slice >= size
            let offset = wholeFile ? 0 : size - slice

            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd(),
                  !data.isEmpty
            else { return nil }

            // The two harnesses record the same fact in different shapes, and
            // the widening search around them is identical — a tail, and a
            // bigger tail if the first held no count. Only the parse differs.
            let tail = String(decoding: data, as: UTF8.self)
            let reading: ContextReading? = switch harness {
            case .claudeCode: ContextScanner.read(tail: tail)
            case .codex: CodexRolloutScanner.read(tail: tail)
            // A watched command has no transcript and no context.
            case .command: nil
            }
            if let reading { return reading }
            if wholeFile { return nil }
            slice *= 8
        }
        return nil
    }

    private func fileSize(of path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.uint64Value
    }
}
