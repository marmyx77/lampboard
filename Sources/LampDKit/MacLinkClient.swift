import Foundation
import LampBoardCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `lampd mac-link`: what the Mac's tunnel runs on this machine (W5,
/// `MacNodeLink`). Up the connection, every 0.3 s, whether the service is
/// serving from a fresh state — which decides the tunnel's port and who
/// notifies for this machine's rows — and the person's choices about the rows
/// when they change. Down it, the Mac's lines, handed to the service, or carried
/// out on the files while the service is down so that nothing the Mac said is
/// lost to a restart.
///
/// Runs as the account, in a plain ssh session of the Mac's own key; never in
/// the phone's forced command. It ends when the Mac's side closes.
public final class MacLinkClient: @unchecked Sendable {

    private let paths: LampDPaths
    private let write: (String) -> Bool
    private let lock = NSLock()
    private var lastPreferences: Data?
    private var ended = false

    /// `write` sends one line up (to standard output); `false` ends the link.
    public init(paths: LampDPaths, write: @escaping (String) -> Bool) {
        self.paths = paths
        self.write = write
    }

    /// Beats until the Mac's side ends; `lines` gives what the Mac writes,
    /// `nil` at its end.
    public func run(lines: @escaping () -> String?) -> Int32 {
        Thread.detachNewThread { [self] in
            while let line = lines() {
                take(line)
            }
            end()
        }
        while !isEnded {
            if !beat(at: Date()) { break }
            Thread.sleep(forTimeInterval: MacNodeLink.heartbeatInterval)
        }
        end()
        return 0
    }

    private var isEnded: Bool { lock.withLock { ended } }
    private func end() { lock.withLock { ended = true } }

    /// One beat, and the choices when they changed. `false` when the Mac is gone.
    @discardableResult
    public func beat(at now: Date) -> Bool {
        let beat: NodeToMac
        if let answer = LampDStatus.ask(paths.socket, line: "mac-ping", timeout: 1) {
            let words = answer.split(separator: " ").map(String.init)
            if words.first == "ok", words.count == 3 || words.count == 4 {
                beat = NodeToMac(serving: true, journal: words[1], seq: Int(words[2]), hooks: words.count == 4 && words[3] == "hooks",
                                 at: now)
            } else {
                beat = NodeToMac(serving: false, reason: words.dropFirst().joined(separator: " "), at: now)
            }
        } else {
            beat = NodeToMac(serving: false, reason: "lampd is not running", at: now)
        }
        guard let text = MacNodeLink.encode(beat), write(text) else { return false }
        let data = FileManager.default.contents(atPath: paths.preferencesFile) ?? Data()
        let changed = lock.withLock { () -> Bool in
            defer { lastPreferences = data }
            return lastPreferences != data
        }
        if changed {
            let line = NodeToMac(preferences: RowPreferencesWire(RowPreferences.decode(data)), at: now)
            guard let text = MacNodeLink.encode(line), write(text) else { return false }
        }
        return true
    }

    /// One line from the Mac: to the service when it answers, else on the files.
    public func take(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let line = MacNodeLink.decode(MacToNode.self, trimmed) else {
            FileHandle.standardError.write(Data("lampd mac-link: a line that is not one of the Mac's, dropped\n".utf8))
            return
        }
        if let problem = line.problem {
            FileHandle.standardError.write(Data("lampd mac-link: refused: \(problem)\n".utf8))
            return
        }
        let encoded = Data(trimmed.utf8).base64EncodedString()
        if let answer = LampDStatus.ask(paths.socket, line: "mac \(encoded)", timeout: 5) {
            if answer != "ok" { FileHandle.standardError.write(Data("lampd mac-link: \(answer)\n".utf8)) }
            return
        }
        if case .failure(let error) = MacLines.apply(line, paths: paths) {
            FileHandle.standardError.write(Data("lampd mac-link: not kept: \(error)\n".utf8))
        }
    }

    /// Standard input, a line at a time, at most `MacNodeLink.maxLine` long.
    public static func standardInputLines() -> () -> String? {
        var buffer: [UInt8] = []
        var finished = false
        return {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    return line
                }
                if finished {
                    guard !buffer.isEmpty else { return nil }
                    defer { buffer = [] }
                    return String(decoding: buffer, as: UTF8.self)
                }
                guard let bytes = UnixSocket.readSome(0) else { finished = true; continue }
                buffer += bytes
                if buffer.count > MacNodeLink.maxLine * 2 { buffer = []; finished = true }
            }
        }
    }
}
