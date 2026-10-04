import Darwin
import Foundation
import LampBoardCore

/// The panel's end of Claude Code's message box (D81): finds a session's box
/// under `~/.claude/sessions/` and puts a message into it.
///
/// Read again for every message: a session restarted has a new pid, socket and
/// key, and the file of one that died may name a pid now someone else's. So a
/// box is used only when its process is running, is this user's and started
/// when the file says (`ProcStart`), and when the session file, the key and the
/// socket are what they claim to be: a regular file and a socket of this user's,
/// never a link (a security review's findings).
struct PeerSender: Sendable {

    enum Failure: Error, Equatable, CustomStringConvertible {
        case noBox, empty, refused(String)

        var description: String {
            switch self {
            case .noBox: return "this session has no message box (Claude Code 2.1.224 or later, on this Mac)"
            case .empty: return "nothing to send, or too much"
            case .refused(let why): return "the session's box did not take it: \(why)"
            }
        }
    }

    var directory: URL = AppConfig.liveSessionsDirectory

    /// Whether the session has a box this panel can use, now.
    func hasBox(sessionId: String) -> Bool { find(sessionId) != nil }

    /// Puts the message in. Blocks for the socket's few milliseconds: call it
    /// off the main actor.
    func send(_ typed: String, to sessionId: String) -> Result<Void, Failure> {
        guard let (address, token) = find(sessionId) else { return .failure(.noBox) }
        guard let wire = PeerBox.wire(token: token, typed: typed) else { return .failure(.empty) }
        return write(wire, to: address.socketPath)
    }

    // MARK: - Internals

    private func find(_ sessionId: String) -> (PeerBox.Address, String)? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names where name.hasSuffix(".json") {
            guard let data = readOwnFile(name, private: false),
                  let address = PeerBox.address(fromSessionFile: data), address.sessionId == sessionId,
                  name == "\(address.pid).json", isLive(address),
                  let keyName = PeerBox.keyFileName(pid: address.pid, in: names),
                  let key = readOwnFile(keyName, private: true),
                  let token = PeerBox.token(fromKeyFile: key, procStart: address.procStart),
                  isOwnSocket(address.socketPath)
            else { continue }
            return (address, token)
        }
        return nil
    }

    /// Running, this user's, and the process the file was written for.
    private func isLive(_ address: PeerBox.Address) -> Bool {
        guard kill(pid_t(address.pid), 0) == 0 else { return false }
        return ProcStart.stillHolds(recorded: address.procStart,
                                    startedAt: ProcessTree.info(of: pid_t(address.pid))?.startedAt)
    }

    /// A regular file of this user's, not a link; `private` also wants it
    /// unreadable by anyone else, as Claude Code writes its keys.
    private func readOwnFile(_ name: String, private: Bool) -> Data? {
        let path = directory.appendingPathComponent(name).path
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              !`private` || info.st_mode & 0o077 == 0, info.st_size <= 65_536
        else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    private func isOwnSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid()
    }

    /// Writes, closes its half, and waits for the box to close its own: the
    /// socket says nothing back (measured), so an end of file is the receipt.
    private func write(_ data: Data, to path: String) -> Result<Void, Failure> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.refused("no socket")) }
        defer { close(fd) }
        // A box that closes early must fail this write, not kill the app.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return .failure(.refused("path too long")) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .failure(.refused(String(cString: strerror(errno)))) }
        let sent = data.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return -1 }
                offset += n
            }
            return offset
        }
        guard sent == data.count else { return .failure(.refused(String(cString: strerror(errno)))) }
        shutdown(fd, SHUT_WR)
        var sink = [UInt8](repeating: 0, count: 256)
        while read(fd, &sink, sink.count) > 0 {}
        return .success(())
    }
}
