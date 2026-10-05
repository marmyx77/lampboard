import Foundation

/// A node's transcripts, read for LampMaster's cards (D4): the Python run
/// there over ssh, once per node and round, for the Claude Code sessions the
/// panel's rows say are running there.
///
/// Each file is read from where the last read stopped, like this Mac's: the
/// first read takes the tail, a file that shrank is read again from its tail,
/// and no read brings back more than half a megabyte. Only a transcript is
/// read — a regular file ending in `.jsonl`, under that machine's own
/// `~/.claude/projects`, its real path checked there — whatever path a hook
/// reported. The asks reach the program as base64: a path pasted into
/// Python source as text could end the string it sits in (D83's lesson).
public enum RemoteTranscriptScript {

    /// `id` names the ask in the answer: the panel uses the path, so two rows
    /// can never share one.
    public struct Ask: Sendable, Equatable {
        public let id: String
        public let path: String
        public let offset: UInt64

        public init(id: String, path: String, offset: UInt64) {
            self.id = id
            self.path = path
            self.offset = offset
        }
    }

    public struct Read: Sendable, Equatable {
        public let id: String
        public let size: UInt64
        /// Where `data` starts in the file.
        public let start: UInt64
        public let data: Data

        public init(id: String, size: UInt64, start: UInt64, data: Data) {
            self.id = id
            self.size = size
            self.start = start
            self.data = data
        }
    }

    /// The most one read brings back of one file.
    public static let maxBytes = 512 * 1024

    /// A path a transcript can have; anything else is not asked for.
    public static func isTranscriptPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".jsonl") && path.contains("/.claude/projects/") && path.count < 1_024
            && !path.split(separator: "/").contains("..")
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The program, answering `{"<session>": {"size", "start", "data"}}` for
    /// every file it could read; nothing for the others.
    public static func script(_ asks: [Ask], tail: UInt64) -> String {
        let objects = asks.filter { isTranscriptPath($0.path) }
            .map { ["id": $0.id, "path": $0.path, "offset": $0.offset] as [String: Any] }
        let json = (try? JSONSerialization.data(withJSONObject: objects)) ?? Data("[]".utf8)
        return """
        import base64, json, os, stat, sys
        asks = json.loads(base64.b64decode('\(json.base64EncodedString())').decode('utf-8'))
        TAIL = \(tail)
        MAX = \(maxBytes)
        root = os.path.join(os.path.realpath(os.path.expanduser('~')), '.claude', 'projects') + os.sep
        out = {}
        for ask in asks:
            try:
                path = ask['path']
                if not os.path.realpath(path).startswith(root) or not path.endswith('.jsonl'):
                    continue
                # Opened without following a link or waiting on a pipe, then
                # checked as opened: nothing swapped in between is read.
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                try:
                    info = os.fstat(fd)
                    if not stat.S_ISREG(info.st_mode):
                        continue
                    size = info.st_size
                    offset = int(ask['offset'])
                    start = offset if 0 < offset <= size else max(0, size - TAIL)
                    os.lseek(fd, start, os.SEEK_SET)
                    data = os.read(fd, MAX)
                finally:
                    os.close(fd)
                out[ask['id']] = {'size': size, 'start': start, 'data': base64.b64encode(data).decode('ascii')}
            except Exception:
                pass
        sys.stdout.write(json.dumps(out))
        """
    }

    /// What came back, only for what was asked, and only what adds up: a node
    /// is another machine, and its answer is read as anything from outside is
    /// (a review finding: one huge `start` would have overflowed the offset).
    public static func decode(_ data: Data, asked: Set<String>) -> [Read] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.compactMap { id, value -> Read? in
            guard asked.contains(id), let entry = value as? [String: Any],
                  let size = count(entry["size"]), let start = count(entry["start"]),
                  let text = entry["data"] as? String, let bytes = Data(base64Encoded: text), bytes.count <= maxBytes
            else { return nil }
            let (end, overflow) = start.addingReportingOverflow(UInt64(bytes.count))
            guard !overflow, end <= size else { return nil }
            return Read(id: id, size: size, start: start, data: bytes)
        }.sorted { $0.id < $1.id }
    }

    /// A whole, non-negative number: never a boolean, a fraction or a sign.
    static func count(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let exact = Int64(exactly: number.doubleValue), exact >= 0, Double(exact) == number.doubleValue
        else { return nil }
        return UInt64(exact)
    }

    /// The part of a read made of whole lines, and how many bytes it is: a
    /// line cut by the read's end — or a character cut in two — waits for the
    /// next read, which starts at it.
    public static func wholeLines(_ data: Data) -> Data {
        guard let last = data.lastIndex(of: 0x0A) else { return Data() }
        return data.subdata(in: data.startIndex..<data.index(after: last))
    }
}
