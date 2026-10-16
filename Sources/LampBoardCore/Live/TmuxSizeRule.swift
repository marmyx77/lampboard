import Foundation

/// Who holds the size of a tmux window that the Mac, the iPad and the iPhone
/// look at together (Q7 of the mobile plan, D176): "on the iPhone the phone
/// wins while you use it; in the background the Mac comes back; the iPad can
/// watch without resizing". As exact commands, measured in S-D on tmux 3.4 and
/// 3.7c with three clients:
///
/// - the phone attaches with a **new** client, which tmux makes `latest` at once
///   (B4): the window takes the phone's size without a key;
/// - in the background its client is set to `ignore-size` **and detached**:
///   `ignore-size` alone leaves the Mac narrow when a third client is attached
///   (B2, on 3.4 and 3.7c alike). The window goes back to the device used last;
/// - the iPad that watches attaches with `-f ignore-size`, so its keys never
///   resize (D1);
/// - never `resize-window`, which puts the window in `manual` for good, and
///   never a change to `window-size`.
///
/// The phone's client is found by its pid: the attach prints the shell's own pid
/// in an invisible OSC and then `exec`s tmux, which keeps the pid, so that pid
/// is tmux's `#{client_pid}` (S-D). `TmuxClientMark` takes it out of the bytes.
///
/// Every script is one `sh -c`, for whatever login shell the machine has, with
/// Homebrew's folders on a PATH that a non-interactive ssh keeps short on a Mac.
public enum TmuxSizeRule {

    /// How a device attaches.
    public enum Role: Sendable, Equatable {
        /// The phone in front: it takes the size, and every key confirms it.
        case takesSize
        /// The iPad watching: attached with `ignore-size`.
        case watches
    }

    /// The tmux server: the person's own, or one named with `-L` (the checks).
    public struct Server: Equatable, Sendable {
        public let socket: String?

        public static let `default` = Server(socket: nil)

        /// A server named with `-L`; `nil` for a name that is not one word.
        public static func named(_ socket: String) -> Server? {
            guard !socket.isEmpty, socket.count <= 64, !socket.hasPrefix("-"),
                  socket.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return nil }
            return Server(socket: socket)
        }

        private init(socket: String?) { self.socket = socket }

        /// `tmux -u`, and the server's name when it has one.
        var tmux: String { "tmux -u" + (socket.map { " -L " + NewSession.shellQuoted($0) } ?? "") }
    }

    /// The name in the OSC the attach prints.
    public static let markName = "LampBoardClient"

    static let path = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; "

    /// Whether tmux would take `name` back as a session's name: not empty, no
    /// `:` or `.` (tmux would rewrite them), no control character.
    public static func isSessionName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 200 && !name.contains(":") && !name.contains(".")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    /// The terminal's command for `session`: the mark with the client's pid,
    /// then tmux on exactly that session. `nil` for a name tmux would not take.
    public static func attach(session: String, role: Role, server: Server = .default) -> String? {
        guard isSessionName(session) else { return nil }
        let flags = role == .watches ? " -f ignore-size" : ""
        let script = path + "printf '\\033]1337;\(markName)=%s\\007' \"$$\"; "
            + "exec \(server.tmux) attach-session\(flags) -t \(NewSession.shellQuoted("=" + session))"
        return NewSession.posix(script)
    }

    /// The background rule for the clients with these pids (the phone's, from
    /// this attach and any left from before): `ignore-size` and `detach-client`
    /// in one call each. Prints `detached <pid> <client>` or `absent <pid>`.
    public static func background(clients pids: [Int], server: Server = .default) -> String {
        let wanted = pids.filter { $0 > 0 }
        guard !wanted.isEmpty else { return NewSession.posix("echo none") }
        let list = wanted.map(String.init).joined(separator: " ")
        let script = path + "for p in \(list); do "
            + "c=$(\(find(server))); "
            + "if [ -n \"$c\" ]; then \(server.tmux) refresh-client -t \"$c\" -f ignore-size \\; detach-client -t \"$c\" "
            + "&& echo \"detached $p $c\"; else echo \"absent $p\"; fi; done"
        return NewSession.posix(script)
    }

    /// The watching iPad wants the size back: its client drops `ignore-size`; a
    /// key from it then makes it `latest` (A6).
    public static func takeSize(client pid: Int, server: Server = .default) -> String {
        let script = path + "p=\(max(0, pid)); c=$(\(find(server))); "
            + "if [ -n \"$c\" ]; then \(server.tmux) refresh-client -t \"$c\" -f '!ignore-size' && echo \"taken $p $c\"; "
            + "else echo \"absent $p\"; fi"
        return NewSession.posix(script)
    }

    /// The server's clients: pid, name, size, flags, one per line.
    public static func clients(server: Server = .default) -> String {
        NewSession.posix(path + "\(server.tmux) list-clients -F '\(clientFormat)' 2>/dev/null; true")
    }

    static let clientFormat = "#{client_pid}\t#{client_name}\t#{client_width}\t#{client_height}\t#{client_flags}"

    /// The name of the client whose pid is `$p`.
    private static func find(_ server: Server) -> String {
        "\(server.tmux) list-clients -F '#{client_pid} #{client_name}' 2>/dev/null | awk -v p=\"$p\" '$1==p{print $2; exit}'"
    }

    /// What `background` did.
    public struct Background: Equatable, Sendable {
        /// The pids whose client let go, and that client's name.
        public let detached: [Int: String]
        /// The pids with no client: gone already, or never attached.
        public let absent: [Int]

        public init(detached: [Int: String], absent: [Int]) {
            self.detached = detached
            self.absent = absent
        }
    }

    public static func parseBackground(_ output: String) -> Background {
        var detached: [Int: String] = [:]
        var absent: [Int] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count == 3, parts[0] == "detached", let pid = Int(parts[1]) { detached[pid] = parts[2] }
            if parts.count == 2, parts[0] == "absent", let pid = Int(parts[1]) { absent.append(pid) }
        }
        return Background(detached: detached, absent: absent)
    }

    public static func parseClients(_ output: String) -> [TmuxClient] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let pid = Int(fields[0]), let width = Int(fields[2]), let height = Int(fields[3])
            else { return nil }
            return TmuxClient(pid: pid, name: fields[1], width: width, height: height,
                              ignoresSize: fields[4].split(separator: ",").contains("ignore-size"))
        }
    }
}

/// One client of a tmux server, as `list-clients` says.
public struct TmuxClient: Equatable, Sendable {
    public let pid: Int
    public let name: String
    public let width: Int
    public let height: Int
    public let ignoresSize: Bool

    public init(pid: Int, name: String, width: Int, height: Int, ignoresSize: Bool) {
        self.pid = pid
        self.name = name
        self.width = width
        self.height = height
        self.ignoresSize = ignoresSize
    }
}

/// Finds the mark the attach prints — `ESC ] 1337 ; LampBoardClient = <pid> BEL`
/// — in the first bytes of a terminal, keeps the pid, and passes everything
/// else on in order. Bytes are held back only while they could still be the
/// start of the mark; after `limit` bytes without one it gives up and holds
/// nothing back again.
public struct TmuxClientMark {
    public private(set) var pid: Int?

    private static let opening = Array("\u{1B}]1337;\(TmuxSizeRule.markName)=".utf8)
    private let limit: Int
    private var held: [UInt8] = []
    private var seen = 0
    private var done = false

    public init(limit: Int = 64 * 1024) { self.limit = limit }

    /// What of `bytes` (and of what was held back) is not the mark.
    public mutating func pass(_ bytes: [UInt8]) -> [UInt8] {
        guard !done else { return bytes }
        held += bytes
        seen += bytes.count
        if let start = Self.index(of: Self.opening, in: held) {
            let after = start + Self.opening.count
            if let bell = held[after...].firstIndex(of: 0x07) {
                let digits = held[after..<bell]
                if !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ (0x30...0x39).contains($0) }) {
                    pid = Int(String(decoding: digits, as: UTF8.self))
                    let out = Array(held[..<start]) + Array(held[(bell + 1)...])
                    return giveUp(out)
                }
                return giveUp(held)
            }
            if held.count - after > 12 || seen > limit { return giveUp(held) }
            let out = Array(held[..<start])
            held.removeFirst(start)
            return out
        }
        if seen > limit { return giveUp(held) }
        // Keep only the tail that could still grow into the opening.
        let keep = Self.partialTail(of: held)
        let out = Array(held.dropLast(keep))
        held = Array(held.suffix(keep))
        return out
    }

    /// Whatever is still held back, when the stream ends.
    public mutating func finish() -> [UInt8] { giveUp(held) }

    private mutating func giveUp(_ out: [UInt8]) -> [UInt8] {
        held = []
        done = true
        return out
    }

    private static func index(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }

    /// The length of the longest end of `bytes` that is a beginning of the opening.
    private static func partialTail(of bytes: [UInt8]) -> Int {
        var length = min(bytes.count, opening.count - 1)
        while length > 0 {
            if Array(bytes.suffix(length)) == Array(opening.prefix(length)) { return length }
            length -= 1
        }
        return 0
    }
}
