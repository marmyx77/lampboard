import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The hooks' port, on loopback and nowhere else (§2.3; §6.2, the hooks' port
/// on loopback): taken from systemd (`lampd.socket`, E1), or, for the checks,
/// bound here; and the connection to the Mac's tunnel on the next port.
public enum LoopbackTCP {

    /// The first file descriptor systemd passes (`sd_listen_fds`).
    static let firstPassedFD: Int32 = 3

    /// The listening socket systemd passed this process, when it passed one
    /// (`LISTEN_PID` is this process, `LISTEN_FDS` at least one). The variables
    /// are cleared so a child never takes them for its own.
    public static func passedBySystemd(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32? {
        guard let pid = environment["LISTEN_PID"].flatMap(Int32.init), pid == getpid(),
              let count = environment["LISTEN_FDS"].flatMap(Int.init), count >= 1 else { return nil }
        unsetenv("LISTEN_PID")
        unsetenv("LISTEN_FDS")
        unsetenv("LISTEN_FDNAMES")
        _ = fcntl(firstPassedFD, F_SETFD, FD_CLOEXEC)
        return firstPassedFD
    }

    /// Binds and listens on 127.0.0.1:`port` (0: any free one, for the suite).
    public static func listen(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, UnixSocket.stream, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = loopback(port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Glue.listen(fd, 128) == 0 else { close(fd); return nil }
        return fd
    }

    /// The address a listening socket is bound to, as `127.0.0.1:31000`.
    public static func boundAddress(_ fd: Int32) -> (host: String, port: UInt16)? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard ok == 0, address.sin_family == sa_family_t(AF_INET) else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var raw = address.sin_addr
        guard inet_ntop(AF_INET, &raw, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return (String(cString: text), UInt16(bigEndian: address.sin_port))
    }

    /// A connection to 127.0.0.1:`port`, or `nil` within `timeout` seconds:
    /// nothing listening is the Mac away, not a fault.
    public static func connect(port: UInt16, timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_INET, UnixSocket.stream, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var address = loopback(port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { close(fd); return nil }
            var entry = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&entry, 1, Int32(timeout * 1000)) == 1 else { close(fd); return nil }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else { close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    /// Reads and writes on `fd` give up after `seconds`.
    public static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: .init((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Everything until the other end closes, at most `limit` bytes.
    public static func readAll(_ fd: Int32, limit: Int = 8 * 1024 * 1024) -> [UInt8] {
        var out: [UInt8] = []
        while out.count < limit, let bytes = UnixSocket.readSome(fd) { out += bytes }
        return out
    }

    static func loopback(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }
}
