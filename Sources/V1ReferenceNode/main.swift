import Foundation
import LampBoardCore
import ProtocolConformance
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// The reference `v1` source as a node serves it (D175), in the shape `lampd`
// will have (E10 of the mobile plan): a daemon that holds the state and listens
// on a Unix socket, and a thin `stdio` process that sshd runs as the forced
// command of a read key, which only carries bytes between the channel and the
// socket. The state is `V1ReferenceFixture`, the one the domain suite serves in
// memory, so the conformance battery holds the same answers to the same rules
// whether it reaches them through a buffer or through a real ssh.
//
//   V1ReferenceNode serve   --socket <path>
//   V1ReferenceNode stdio   --socket <path> --device <id> --role read|action
//   V1ReferenceNode provoke --socket <path> <count>
//
// Only the checks run it (Scripts/test-nodelink.sh). Example data only.

signal(SIGPIPE, SIG_IGN)

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("V1ReferenceNode: \(message)\n".utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
guard let command = arguments.first else { fail("usage: V1ReferenceNode serve|stdio|provoke --socket <path> …") }
guard let socketPath = option("socket") else { fail("--socket is required") }

switch command {
case "serve":
    ReferenceDaemon(path: socketPath).run()
case "stdio":
    let device = option("device") ?? "unknown-device"
    let role = option("role").flatMap(V1Role.init(rawValue:)) ?? .read
    // What the client asked for, when sshd forced this command instead. A
    // datum, logged by the daemon and never run (E10).
    let asked = ProcessInfo.processInfo.environment["SSH_ORIGINAL_COMMAND"] ?? ""
    ReferenceStdio.run(path: socketPath, device: device, role: role, asked: asked)
case "provoke":
    guard let count = arguments.last.flatMap(Int.init), count > 0 else { fail("provoke wants a positive count") }
    guard let daemon = UnixSocket.connect(socketPath) else { fail("no daemon on \(socketPath)", code: 69) }
    UnixSocket.sendAll(daemon, Array("provoke \(count)\n".utf8))
    _ = UnixSocket.readSome(daemon)
    close(daemon)
default:
    fail("unknown command \(command)")
}

/// The daemon: one source, any number of connections, a clock that polls them.
final class ReferenceDaemon {
    private let path: String
    private let lock = NSLock()
    private let source: V1MemorySource
    private var made = 0
    private var services: [Int32: V1Service] = [:]

    init(path: String) {
        self.path = path
        source = V1ReferenceFixture.source(startedAt: Date())
        made = V1ReferenceFixture.provoke(source, count: 3, made: 0, at: Date())
    }

    func run() -> Never {
        guard let listener = UnixSocket.listen(path) else { fail("cannot listen on \(path)") }
        log("serving \(path)")
        DispatchQueue.global().async { [self] in
            while true {
                usleep(50_000)
                lock.lock()
                pollAll()
                lock.unlock()
            }
        }
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global().async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        guard let header = UnixSocket.readLine(fd) else { close(fd); return }
        let words = header.split(separator: " ").map(String.init)
        if words.first == "provoke", words.count == 2, let count = Int(words[1]) {
            lock.lock()
            made = V1ReferenceFixture.provoke(source, count: count, made: made, at: Date())
            pollAll()
            lock.unlock()
            UnixSocket.sendAll(fd, Array("ok\n".utf8))
            close(fd)
            return
        }
        guard words.first == "v1", words.count >= 3, let role = V1Role(rawValue: words[2]) else { close(fd); return }
        let asked = words.count >= 4 ? String(decoding: Data(base64Encoded: words[3]) ?? Data(), as: UTF8.self) : ""
        log("connection device=\(words[1]) role=\(role.rawValue) asked=\(asked.isEmpty ? "-" : asked)")
        lock.lock()
        services[fd] = V1Service(source: source, peer: V1Peer(device: words[1], role: role))
        lock.unlock()
        while let bytes = UnixSocket.readSome(fd) {
            lock.lock()
            if var service = services[fd] {
                let out = service.receive(bytes, at: Date())
                services[fd] = service
                UnixSocket.sendAll(fd, out)
                if service.isClosed { finish(fd) }
            }
            lock.unlock()
        }
        lock.lock()
        services[fd] = nil
        lock.unlock()
        close(fd)
    }

    /// Under the lock.
    private func pollAll() {
        let now = Date()
        for (fd, var service) in services {
            let out = service.poll(at: now)
            services[fd] = service
            UnixSocket.sendAll(fd, out)
            if service.isClosed { finish(fd) }
        }
    }

    /// Under the lock: the reader of `fd` sees the end and closes it.
    private func finish(_ fd: Int32) {
        services[fd] = nil
        shutdown(fd, Int32(SHUT_RDWR))
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8))
    }
}

/// The forced command's process: the channel's stdin to the daemon, the
/// daemon's answers to the channel's stdout, until either side ends.
enum ReferenceStdio {
    static func run(path: String, device: String, role: V1Role, asked: String) -> Never {
        guard let daemon = UnixSocket.connect(path) else { fail("no daemon on \(path)", code: 69) }
        let note = asked.isEmpty ? "" : " " + Data(asked.utf8).base64EncodedString()
        UnixSocket.sendAll(daemon, Array("v1 \(device) \(role.rawValue)\(note)\n".utf8))
        DispatchQueue.global().async {
            while let bytes = UnixSocket.readSome(0) { UnixSocket.sendAll(daemon, bytes) }
            shutdown(daemon, Int32(SHUT_WR))
        }
        while let bytes = UnixSocket.readSome(daemon) { UnixSocket.sendAll(1, bytes) }
        exit(0)
    }
}

/// The few socket calls this needs, the same on Linux and on the Mac.
enum UnixSocket {
    #if os(Linux)
    static let stream = Int32(SOCK_STREAM.rawValue)
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

    static func listen(_ path: String) -> Int32? {
        unlink(path)
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, stream, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Glue.listen(fd, 16) == 0 else { close(fd); return nil }
        return fd
    }

    static func connect(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, stream, 0)
        guard fd >= 0 else { return nil }
        let joined = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard joined == 0 else { close(fd); return nil }
        return fd
    }

    /// What arrived, or `nil` at the end.
    static func readSome(_ fd: Int32) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Array(buffer[0..<count]) }
            if count < 0 && errno == EINTR { continue }
            return nil
        }
    }

    static func readLine(_ fd: Int32) -> String? {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while line.count < 4096 {
            guard read(fd, &byte, 1) == 1 else { return nil }
            if byte == 0x0A { return String(decoding: line, as: UTF8.self) }
            line.append(byte)
        }
        return nil
    }

    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes[offset...].withUnsafeBytes { raw -> Int in
                fd <= 2 ? write(fd, raw.baseAddress, raw.count) : send(fd, raw.baseAddress, raw.count, noSignal)
            }
            if sent < 0 && errno == EINTR { continue }
            guard sent > 0 else { return }
            offset += sent
        }
    }
}

/// The system's `listen` and `connect`, which the names above shadow.
enum Glue {
    #if canImport(Glibc)
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Glibc.connect(fd, address, length)
    }
    #else
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(fd, backlog) }
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Darwin.connect(fd, address, length)
    }
    #endif
}
