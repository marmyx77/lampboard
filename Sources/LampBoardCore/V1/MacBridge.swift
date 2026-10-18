import Foundation

/// The Mac as a source for the phone (§2.4 and §2.6 of the mobile plan): what
/// travels between the iPhone or iPad and the ssh server inside the Mac app,
/// besides `v1` itself.
///
/// Written once, here, because both ends need it: the Mac to read what it is
/// asked and refuse anything else, the phone to ask in words the Mac reads.
/// Nothing in it runs anything. A request is a name and checked arguments; the
/// command, when there is one, is built on the Mac from `NodeAction`, the same
/// scripts a node runs, so that no string the phone sends ever reaches a shell.
public enum MacBridge {
    /// The account a paired key opens.
    public static let user = "lampboard"
    /// The account the one-time code opens, inside its window only.
    public static let pairUser = "pair"
    /// How long a pairing code lives (§2.4: two minutes).
    public static let pairingWindow: TimeInterval = 120
    /// Wrong codes after which the window closes, whatever time is left.
    public static let maxWrongCodes = 3
    /// The Bonjour service type the Mac announces and the phone browses (§2.5).
    public static let bonjourType = "_lampboard._tcp"
}

/// One request on a channel of the Mac's server: the exec line, read whole.
///
/// The vocabulary is closed. A line that is not one of these is refused before
/// anything is looked up, and so is one whose arguments are not what they
/// claim to be: `parse` returns `nil` and the server says no.
public enum MacRequest: Equatable, Sendable {
    /// The `v1` channel: both keys.
    case v1
    /// The pairing exchange: the `pair` account only.
    case pair
    /// A terminal on one of the Mac's sessions (the PTY bridge): action key,
    /// with a `pty-req` first, and only with the switch on (Q17).
    case attach(MacTerminalTarget)
    /// One of the panel's own actions, named (§2.6): action key, switch on.
    case action(NodeAction)
    /// The rule of Q7 for this connection's own terminals (E14): the phone is
    /// going to the background, the Mac takes its size back.
    case background
    /// The colours of the Mac's terminal, *Like my VS Code* included.
    case palette

    /// What the phone sends for this request.
    public var line: String? {
        switch self {
        case .v1: return "v1"
        case .pair: return "pair"
        case .background: return "background"
        case .palette: return "palette"
        case .attach(let target):
            return Self.encode(target.wire).map { "attach " + $0 }
        case .action(let action):
            guard let call = MacActionCall(action) else { return nil }
            return Self.encode(call).map { "action " + $0 }
        }
    }

    /// The request a line asks for, or `nil` for anything the Mac does not do.
    public static func parse(_ line: String) -> MacRequest? {
        // Longer than any request this vocabulary makes: refused unread.
        guard line.utf8.count <= 16 * 1024 else { return nil }
        let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        switch (words.first ?? "", words.count) {
        case ("v1", 1): return .v1
        case ("pair", 1): return .pair
        case ("background", 1): return .background
        case ("palette", 1): return .palette
        case ("attach", 2):
            return decode(MacTerminalTarget.Wire.self, words[1]).flatMap(MacTerminalTarget.init(wire:)).map(MacRequest.attach)
        case ("action", 2):
            return decode(MacActionCall.self, words[1]).flatMap(\.action).map(MacRequest.action)
        default: return nil
        }
    }

    static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { $0.base64EncodedString() }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ word: String) -> T? {
        guard let data = Data(base64Encoded: word) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// What a terminal from the phone may open on the Mac (§2.6): a session in the
/// Mac's tmux, a background session's attach, a shell in a project. Nothing
/// else, and never a command.
public enum MacTerminalTarget: Equatable, Hashable, Sendable {
    /// A tmux session on the Mac, by its exact name.
    case tmux(session: String)
    /// A background session (`claude --bg`): its job's attach, never a second one.
    case job(String)
    /// A shell in a project's folder.
    case shell(root: String)

    struct Wire: Codable {
        var tmux: String?
        var job: String?
        var shell: String?
    }

    var wire: Wire {
        switch self {
        case .tmux(let session): return Wire(tmux: session)
        case .job(let id): return Wire(job: id)
        case .shell(let root): return Wire(shell: root)
        }
    }

    init?(wire: Wire) {
        switch (wire.tmux, wire.job, wire.shell) {
        case (let session?, nil, nil):
            guard TmuxSizeRule.isSessionName(session) else { return nil }
            self = .tmux(session: session)
        case (nil, let job?, nil):
            guard BackgroundJobParser.isSafe(id: job) else { return nil }
            self = .job(job)
        case (nil, nil, let root?):
            guard NodeTerminalCommand.shell(root: root).command != nil else { return nil }
            self = .shell(root: root)
        default:
            return nil
        }
    }
}

/// A `NodeAction` as it travels to the Mac: its name and its arguments, as
/// data. Read back into a `NodeAction` only through the same checks a node's
/// command goes through, so an argument the node would refuse is refused here.
public struct MacActionCall: Codable, Equatable, Sendable {
    public var name: String
    public var folder: String?
    public var tmuxName: String?
    public var launch: String?
    public var session: String?
    public var permissions: String?
    public var tmux: String?
    public var pid: Int32?
    public var procStart: String?
    public var path: String?
    public var root: String?
    public var relative: String?
    public var text: String?

    /// The actions the Mac takes from the phone. `projects` is a node's
    /// (`lampd` keeps them) and `attachments` needs SFTP, which the Mac's
    /// server does not open: both are refused by name.
    public static let names: Set<String> = [
        "new-session", "resume", "end", "move", "move-done", "browse", "conversations",
        "files", "read", "git-status", "peer-send", "look",
    ]

    init(name: String) { self.name = name }

    public init?(_ action: NodeAction) {
        self.init(name: action.name)
        switch action {
        case .start(let folder, let name, let launch, let start):
            self.folder = folder; tmuxName = name; self.launch = launch
            session = start.sessionId; permissions = start.permissions.rawValue
        case .end(let session, let tmux): self.session = session; self.tmux = tmux
        case .move(let session, let pid, let procStart): self.session = session; self.pid = pid; self.procStart = procStart
        case .moveDone(let session): self.session = session
        case .browse(let path): self.path = path
        case .conversations(let folder): self.folder = folder
        case .files(let root, let relative): self.root = root; self.relative = relative
        case .read(let root, let relative): self.root = root; self.relative = relative
        case .gitStatus(let root): self.root = root
        case .message(let session, let text): self.session = session; self.text = text
        case .look: break
        case .attachments, .projects: return nil
        }
    }

    /// The action, or `nil` for a name the Mac does not take or arguments that
    /// do not make one. The command it builds is checked again when it is built.
    public var action: NodeAction? {
        guard Self.names.contains(name) else { return nil }
        switch name {
        case "new-session", "resume":
            guard let folder, let tmuxName, let launch, let session, ModReport.isSessionId(session) else { return nil }
            let mode = NewSession.Permissions.named(permissions)
            let start: NewSession.Start = name == "resume" ? .resume(sessionId: session, permissions: mode)
                                                             : .new(sessionId: session, permissions: mode)
            return .start(folder: folder, name: tmuxName, launch: launch, start: start)
        case "end":
            guard let session else { return nil }
            return .end(session: session, tmux: tmux)
        case "move":
            guard let session, let pid, let procStart else { return nil }
            return .move(session: session, pid: pid, procStart: procStart)
        case "move-done":
            return session.map(NodeAction.moveDone)
        case "browse":
            return .browse(path: path)
        case "conversations":
            return folder.map(NodeAction.conversations)
        case "files":
            return root.map { NodeAction.files(root: $0, relative: relative) }
        case "read":
            guard let root, let relative else { return nil }
            return .read(root: root, relative: relative)
        case "git-status":
            return root.map(NodeAction.gitStatus)
        case "peer-send":
            guard let session, let text else { return nil }
            return .message(session: session, text: text)
        case "look":
            return .look
        default:
            return nil
        }
    }
}

/// What the Mac's QR code carries (§2.4): who the Mac is, how to reach it, the
/// key its server will present, and the one-time code. Never a host name: the
/// name is the one the person gave the Mac (S-P).
public struct MacPairingInvitation: Equatable, Sendable {
    public let name: String
    /// The server's host key, `<algorithm> <base64>`: pinned before a byte is sent.
    public let hostKey: String
    /// Where to try, in order: the Bonjour name, the LAN address, the tailnet's.
    public let addresses: [String]
    public let port: Int
    public let code: String

    public init(name: String, hostKey: String, addresses: [String], port: Int, code: String) {
        self.name = name
        self.hostKey = hostKey
        self.addresses = addresses
        self.port = port
        self.code = code
    }

    public static let scheme = "lampboard"

    /// `lampboard://pair?…`, what the QR code holds.
    public var url: String {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "pair"
        parts.queryItems = [
            URLQueryItem(name: "v", value: String(V1Protocol.version)),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "key", value: hostKey),
            URLQueryItem(name: "addr", value: addresses.joined(separator: ",")),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: code),
        ]
        return parts.string ?? ""
    }

    /// The invitation a scanned code holds, or `nil` for one that is not.
    public init?(url text: String) {
        guard let parts = URLComponents(string: text), parts.scheme == Self.scheme, parts.host == "pair" else { return nil }
        var items: [String: String] = [:]
        for item in parts.queryItems ?? [] { items[item.name] = item.value }
        guard let name = items["name"], !name.isEmpty, name.count <= 80,
              let key = items["key"], key.split(separator: " ").count == 2,
              let port = items["port"].flatMap(Int.init), (1...65535).contains(port),
              let code = items["code"], MacPairingCode.isWellFormed(code) else { return nil }
        let addresses = (items["addr"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        self.init(name: name, hostKey: key, addresses: addresses, port: port, code: code)
    }
}

/// The one-time code: twelve letters and digits nobody misreads, enough that
/// three guesses in two minutes find nothing.
public enum MacPairingCode {
    public static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    public static let length = 12

    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    public static func isWellFormed(_ code: String) -> Bool {
        code.count == length && code.allSatisfy { alphabet.contains($0) }
    }
}

/// What the phone sends on the `pair` channel: its name and its two public
/// keys (§2.4), and the relay's capability when it has one (W4).
public struct MacPairingRequest: Codable, Equatable, Sendable {
    public let name: String
    /// `ecdsa-sha2-nistp256 <base64>`: the key that reads.
    public let readKey: String
    /// The same for the key that acts, in the Secure Enclave.
    public let actionKey: String
    public let relayCapability: String?

    public init(name: String, readKey: String, actionKey: String, relayCapability: String? = nil) {
        self.name = name
        self.readKey = readKey
        self.actionKey = actionKey
        self.relayCapability = relayCapability
    }

    /// Why the Mac cannot take it, or `nil`.
    public var problem: String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean.count > 60 { return "a device's name is 1 to 60 characters" }
        if clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "a name has no control characters" }
        for key in [readKey, actionKey] {
            let parts = key.split(separator: " ")
            guard parts.count >= 2, parts[0] == "ecdsa-sha2-nistp256", Data(base64Encoded: String(parts[1])) != nil else {
                return "the keys are P-256 (ecdsa-sha2-nistp256)"
            }
        }
        if Self.blob(readKey) == Self.blob(actionKey) { return "the two keys must be different" }
        if let relayCapability, relayCapability.count > 4096 { return "the capability is too long" }
        return nil
    }

    static func blob(_ key: String) -> Substring? { key.split(separator: " ").dropFirst().first }
}

/// The Mac's answer on the `pair` channel.
public struct MacPairingReply: Codable, Equatable, Sendable {
    public let ok: Bool
    /// The id the Mac gave the device: what its rows and its revocation name.
    public let device: String?
    public let mac: String?
    public let error: String?
    /// The nodes the Mac carried the device's keys to (§2.4, W5), each with the
    /// host key the Mac already trusts for it: trust carried, never guessed.
    /// Absent from a Mac one version behind.
    public let nodes: [MacPairedNode]?

    public init(ok: Bool, device: String? = nil, mac: String? = nil, error: String? = nil, nodes: [MacPairedNode]? = nil) {
        self.ok = ok
        self.device = device
        self.mac = mac
        self.error = error
        self.nodes = nodes
    }
}

/// A node the Mac put a phone's keys on, at pairing (W5, §2.4): `lampd devices
/// add` ran there over the Mac's own ssh, and the phone is handed what it needs
/// to reach it without a second pairing.
public struct MacPairedNode: Codable, Equatable, Sendable {
    /// The node as the Mac names it (its ssh host): the name the rows carry.
    public let name: String
    /// Where the Mac's ssh reaches it (`HostName`), its port and account.
    public let address: String
    public let port: Int
    public let user: String
    /// The node's host keys as the Mac's `known_hosts` holds them,
    /// `<type> <base64>`: the phone pins these, never what it is first shown.
    public let hostKeys: [String]
    /// The id `lampd` gave the phone there, for its revocation.
    public let device: String?

    public init(name: String, address: String, port: Int, user: String, hostKeys: [String], device: String?) {
        self.name = name
        self.address = address
        self.port = port
        self.user = user
        self.hostKeys = hostKeys
        self.device = device
    }
}

/// What the Mac reads of its own ssh, to hand a node over (W5): the address,
/// port and account `ssh -G` resolves, and the host keys `ssh-keygen -F` finds.
public enum MacSSHFacts {

    /// `ssh -G <host>`'s answer: lowercase keys, one per line.
    public static func resolved(_ text: String) -> (address: String, port: Int, user: String)? {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            if words.count == 2, values[words[0]] == nil { values[words[0]] = words[1] }
        }
        guard let address = values["hostname"], !address.isEmpty, let user = values["user"], !user.isEmpty else { return nil }
        return (address, values["port"].flatMap(Int.init) ?? 22, user)
    }

    /// The `[host]:port` or `host` that `known_hosts` keys an entry by.
    public static func knownHostsName(address: String, port: Int) -> String {
        port == 22 ? address : "[\(address)]:\(port)"
    }

    /// `ssh-keygen -F`'s lines: `<host or hash> <type> <base64>`, comments
    /// skipped; each key once, as `<type> <base64>`.
    public static func hostKeys(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let words = line.split(separator: " ").map(String.init)
            // A marked line is a revoked key or a certificate authority: never a pin.
            if words.first?.hasPrefix("@") == true { continue }
            guard words.count >= 3, words[1].hasPrefix("ssh-") || words[1].hasPrefix("ecdsa-"),
                  Data(base64Encoded: words[2]) != nil else { continue }
            let key = words[1] + " " + words[2]
            if !out.contains(key) { out.append(key) }
        }
        return out
    }
}
