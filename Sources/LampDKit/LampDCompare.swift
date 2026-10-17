import Foundation
import LampBoardCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `lampd compare`: the service's lamps against the phone's own reading of the
/// same files, on the machine itself. The gate proves the rule on recordings;
/// this says whether it holds on the sessions that are running now.
public enum LampDCompare {

    /// The rows the running service serves, read through its socket as a
    /// forced command would.
    public static func served(socket: String) -> [V1Row]? {
        guard let fd = UnixSocket.connect(socket) else { return nil }
        defer { close(fd) }
        UnixSocket.sendAll(fd, Array("v1 lampd-compare read\n".utf8))
        for message in [V1ClientMessage(id: 1, .hello(protocol: V1Protocol.version, client: "lampd compare")),
                        V1ClientMessage(id: 2, .state)] {
            guard let bytes = try? V1Codec.encode(message) else { return nil }
            UnixSocket.sendAll(fd, V1Frame.encode(bytes))
        }
        var reader = V1FrameReader()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard UnixSocket.readable(fd, timeout: 1) else { continue }
            guard let bytes = UnixSocket.readSome(fd) else { return nil }
            reader.push(bytes)
            while let frame = try? reader.next() {
                if case .state(let state)? = try? V1Codec.decodeReply(frame).reply { return state.rows ?? [] }
            }
        }
        return nil
    }

    /// One line per session: its id cut short, the lamp each reader gives it.
    public static func table(probe: [V1Row], served: [V1Row]) -> (rows: [String], summary: String, same: Bool) {
        let mine = Dictionary(served.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let theirs = Dictionary(probe.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines = ["session   | the phone's look       | lampd                  | same"]
        var different = 0
        for id in Set(mine.keys).union(theirs.keys).sorted() {
            let a = theirs[id].map(lamp) ?? "no row"
            let b = mine[id].map(lamp) ?? "no row"
            // A row the person took off or hid is lampd's choice, not a rule.
            let hiddenByChoice = theirs[id] != nil && mine[id] == nil
            let same = a == b || hiddenByChoice
            if !same { different += 1 }
            lines.append("\(id.prefix(8)) | \(a.padding(toLength: 22, withPad: " ", startingAt: 0)) | "
                         + "\(b.padding(toLength: 22, withPad: " ", startingAt: 0)) | \(same ? "yes" : "NO")")
        }
        let summary = "\(Set(mine.keys).union(theirs.keys).count) sessions, \(different) with another lamp"
        return (lines, summary, different == 0)
    }

    static func lamp(_ row: V1Row) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        return "\(row.session.status) \(clock.string(from: row.session.updatedAt))\(row.extras.terminal == nil ? "" : " tmux")"
    }
}
