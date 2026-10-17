import Foundation
import LampBoardCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `lampd v1-stdio`: the command sshd runs for a read key, forced in its line
/// of `authorized_keys`. The channel's bytes are its standard input and output.
///
/// With the service running, it only carries bytes between the channel and the
/// service's socket. With the service stopped it does **not** give up (E10 as
/// amended on 17 October 2026, which replaced "exit 69"): it reads Claude Code's
/// files itself, with the same `NodeSource` and the same rules, for as long as
/// the channel lasts, and `hello` says `mode: files`. The phone keeps its lights
/// with the read key alone, says "reading files", and never asks for Face ID.
public enum LampDStdio {

    /// - Parameters:
    ///   - asked: what the client asked to run when sshd forced this command
    ///     instead (`SSH_ORIGINAL_COMMAND`): a datum, logged, never run.
    /// - Returns: the exit code; 0 whenever the channel simply ended.
    public static func run(paths: LampDPaths, config: LampDConfig, version: String, device: String, role: V1Role,
                           asked: String, probeEnvironment: [String: String?] = [:]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        if let daemon = UnixSocket.connect(paths.socket) {
            return forward(daemon: daemon, device: device, role: role, asked: asked)
        }
        let log = LampDLog(file: (try? LampDPaths.makeDirectory(paths.stateDirectory)) != nil ? paths.logFile : nil)
        log.write("v1-stdio without the service: reading the files, device=\(device) role=\(role.rawValue) asked=\(asked.isEmpty ? "-" : asked)")
        return readingFiles(paths: paths, config: config, version: version, peer: V1Peer(device: device, role: role),
                            probe: LocalProbe(paths: paths, environment: probeEnvironment))
    }

    /// The service answers: bytes both ways until either side ends.
    static func forward(daemon: Int32, device: String, role: V1Role, asked: String) -> Int32 {
        let note = asked.isEmpty ? "" : " " + Data(asked.utf8).base64EncodedString()
        guard UnixSocket.sendAll(daemon, Array("v1 \(device) \(role.rawValue)\(note)\n".utf8)) else { return 0 }
        Thread.detachNewThread {
            while let bytes = UnixSocket.readSome(0) {
                if !UnixSocket.sendAll(daemon, bytes) { break }
            }
            shutdown(daemon, Int32(SHUT_WR))
        }
        while let bytes = UnixSocket.readSome(daemon) {
            if !UnixSocket.sendAll(1, bytes) { break }
        }
        close(daemon)
        return 0
    }

    /// No service: a `NodeSource` of this process, looked at every few seconds,
    /// served on the channel until it ends.
    static func readingFiles(paths: LampDPaths, config: LampDConfig, version: String, peer: V1Peer,
                             probe: LocalProbe) -> Int32 {
        let source = NodeSource(identity: config.identity, mode: .files, paths: paths, version: version, startedAt: Date())
        source.absorb(probe.look())
        var service = V1Service(source: source, peer: peer)
        var nextLook = Date().addingTimeInterval(config.probeInterval)
        while !service.isClosed {
            if UnixSocket.readable(0, timeout: 0.1) {
                guard let bytes = UnixSocket.readSome(0) else { break }
                guard write(service.receive(bytes, at: Date())) else { break }
            }
            if Date() >= nextLook {
                source.absorb(probe.look())
                nextLook = Date().addingTimeInterval(config.probeInterval)
            }
            guard write(service.poll(at: Date())) else { break }
        }
        return 0
    }

    private static func write(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        return V1Frame.pieces(bytes).allSatisfy { UnixSocket.sendAll(1, $0) }
    }
}
