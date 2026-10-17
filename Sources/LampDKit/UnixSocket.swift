import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The few socket calls a node needs, the same on Linux and on the Mac: the
/// service listens on a Unix socket in a directory only its account can enter,
/// and the read key's forced command connects to it.
public enum UnixSocket {
    #if canImport(Glibc)
    static let stream = Int32(SOCK_STREAM.rawValue)
    static let noSignal = Int32(MSG_NOSIGNAL)
    #elseif canImport(Musl)
    static let stream = SOCK_STREAM
    static let noSignal = Int32(MSG_NOSIGNAL)
    #else
    static let stream = SOCK_STREAM
    static let noSignal: Int32 = 0
    #endif

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Listens on `path`, replacing a socket left by a run that died, with the
    /// socket file itself at `mode`.
    public static func listen(_ path: String, mode: mode_t = 0o600) -> Int32? {
        unlink(path)
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, stream, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, mode) == 0, Glue.listen(fd, 64) == 0 else { close(fd); return nil }
        return fd
    }

    public static func connect(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, stream, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let joined = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard joined == 0 else { close(fd); return nil }
        return fd
    }

    /// The next connection, or `nil` when the listener was closed.
    public static func accept(_ listener: Int32) -> Int32? {
        while true {
            let fd = Glue.accept(listener)
            if fd >= 0 {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                return fd
            }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    /// What arrived, or `nil` at the end.
    public static func readSome(_ fd: Int32) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Array(buffer[0..<count]) }
            if count < 0 && errno == EINTR { continue }
            return nil
        }
    }

    /// Whether `fd` has something to read within `timeout` seconds (or has ended).
    public static func readable(_ fd: Int32, timeout: TimeInterval) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&entry, 1, Int32(max(0, timeout * 1000)))
        return result > 0
    }

    public static func readLine(_ fd: Int32, limit: Int = 4096) -> String? {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while line.count < limit {
            let count = read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == 0x0A { return String(decoding: line, as: UTF8.self) }
            line.append(byte)
        }
        return nil
    }

    /// Writes all of `bytes`; `false` when the other end is gone.
    @discardableResult
    public static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes[offset...].withUnsafeBytes { raw -> Int in
                fd <= 2 ? write(fd, raw.baseAddress, raw.count) : send(fd, raw.baseAddress, raw.count, noSignal)
            }
            if sent < 0 && errno == EINTR { continue }
            guard sent > 0 else { return false }
            offset += sent
        }
        return true
    }
}

/// The system's `listen`, `connect` and `accept`, which the names above shadow.
enum Glue {
    #if canImport(Glibc)
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Glibc.connect(fd, address, length)
    }
    static func accept(_ fd: Int32) -> Int32 { Glibc.accept(fd, nil, nil) }
    #elseif canImport(Musl)
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Musl.listen(fd, backlog) }
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Musl.connect(fd, address, length)
    }
    static func accept(_ fd: Int32) -> Int32 { Musl.accept(fd, nil, nil) }
    #else
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(fd, backlog) }
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Darwin.connect(fd, address, length)
    }
    static func accept(_ fd: Int32) -> Int32 { Darwin.accept(fd, nil, nil) }
    #endif
}

/// `sd_notify` without libsystemd: one datagram to `$NOTIFY_SOCKET`, a path or
/// `@name` in the abstract namespace. All that `Type=notify` and `WatchdogSec`
/// need (S-G v2).
public enum SystemdNotify {
    @discardableResult
    public static func send(_ message: String) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["NOTIFY_SOCKET"], !path.isEmpty else { return false }
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        #elseif canImport(Musl)
        let fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0)
        #else
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        var bytes = Array(path.utf8)
        if bytes.first == UInt8(ascii: "@") { bytes[0] = 0 }
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + (bytes.first == 0 ? 0 : 1))
        let payload = Array(message.utf8)
        let sent = payload.withUnsafeBytes { body in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, body.baseAddress, body.count, UnixSocket.noSignal, $0, length)
                }
            }
        }
        return sent == payload.count
    }

    /// The watchdog's interval, when systemd set one for this process.
    public static var watchdogInterval: TimeInterval? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["WATCHDOG_USEC"], let usec = Double(raw), usec > 0 else { return nil }
        if let pid = environment["WATCHDOG_PID"], let value = Int32(pid), value != getpid() { return nil }
        return usec / 1_000_000
    }
}
