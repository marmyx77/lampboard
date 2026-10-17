import Foundation
import LampBoardCore
@_spi(Probe) import LampBoardNodeLink
import ProtocolConformance
import TestKit

// NodeLink over a real ssh (D175): the `v1` conformance battery against the
// reference node behind OpenSSH, and the bites of the keys — a changed host key
// is refused before anything is sent, a read key that asks for anything else
// gets `v1` and nothing else, an unknown key does not get in. Then the terminal,
// the size rule of Q7 on the node's tmux, and the lights read over ssh (D176). Run by
// Scripts/test-nodelink.sh, in a container, against a node in another one.
//
//   NodeLinkCheck keys <dir>      writes read.key/.pub and action.key/.pub
//   NodeLinkCheck run --host H --port P --user U --host-key F --wrong-host-key F
//                     --keys <dir> --reference <path on the node> --socket <path on the node>
//                     --log <path on the node> --silent-port P --tmux-host H --tmux-host-key F [filter]

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("NodeLinkCheck: \(message)\n".utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { fail("--\(name) is required") }
    return arguments[index + 1]
}

func readText(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    return text
}

switch arguments.first {
case "keys":
    // `keys <dir> [prefix]`: a pair named `<prefix>read` and `<prefix>action`.
    guard arguments.count == 2 || arguments.count == 3 else { fail("keys <dir> [prefix]") }
    let dir = arguments[1]
    let prefix = arguments.count == 3 ? arguments[2] : ""
    let read = ReadKey.generate(), action = ActionKey.generate()
    for (name, raw, pub) in [(prefix + "read", read.rawRepresentation, read.publicKey),
                             (prefix + "action", action.rawRepresentation, action.publicKey)] {
        _ = FileManager.default.createFile(atPath: "\(dir)/\(name).key", contents: Data(raw.base64EncodedString().utf8),
                                           attributes: [.posixPermissions: 0o600])
        _ = FileManager.default.createFile(atPath: "\(dir)/\(name).pub", contents: Data((pub + "\n").utf8))
    }
case "run":
    guard #available(macOS 15.0, *) else { fail("needs macOS 15 or Linux") }
    let keys = option("keys")
    func raw(_ name: String) -> Data {
        guard let data = Data(base64Encoded: readText("\(keys)/\(name).key").trimmingCharacters(in: .whitespacesAndNewlines))
        else { fail("\(name).key is not base64") }
        return data
    }
    let node: CheckedNode
    do {
        node = CheckedNode(
            endpoint: NodeEndpoint(host: option("host"), port: Int(option("port")) ?? 22, user: option("user")),
            hostKey: try NodeHostKey(openSSH: readText(option("host-key"))),
            wrongHostKey: try NodeHostKey(openSSH: readText(option("wrong-host-key"))),
            readKey: try ReadKey(rawRepresentation: raw("read")),
            actionKey: try ActionKey(rawRepresentation: raw("action")),
            reference: option("reference"), socket: option("socket"), log: option("log"),
            silentPort: Int(option("silent-port")) ?? 0,
            tmuxEndpoint: NodeEndpoint(host: option("tmux-host"), port: Int(option("port")) ?? 22, user: option("user")),
            tmuxHostKey: try NodeHostKey(openSSH: readText(option("tmux-host-key")))
        )
    } catch {
        fail("\(error)")
    }
    Instrument.prove(quietly: true)
    let filter = arguments.count % 2 == 0 ? arguments.last : nil
    let target = SSHConformanceTarget(node)
    let code = TestRunner.runAndReport(
        [V1Conformance.suite(against: target), KeyBites.suite(node), TerminalChecks.suite(node)], filter: filter)
    target.finish()
    exit(code)
case "lampd":
    // The same checks against `lampd` installed on a node (W3): the conformance
    // battery, the phone's lines, one rule for the files, the service stopped.
    guard #available(macOS 15.0, *) else { fail("needs macOS 15 or Linux") }
    let keys = option("keys")
    func raw(_ name: String) -> Data {
        guard let data = Data(base64Encoded: readText("\(keys)/\(name).key").trimmingCharacters(in: .whitespacesAndNewlines))
        else { fail("\(name).key is not base64") }
        return data
    }
    let node: LampDNode
    do {
        node = LampDNode(
            endpoint: NodeEndpoint(host: option("host"), port: Int(option("port")) ?? 22, user: option("user")),
            hostKey: try NodeHostKey(openSSH: readText(option("host-key"))),
            readKey: try ReadKey(rawRepresentation: raw("read")),
            actionKey: try ActionKey(rawRepresentation: raw("action")),
            farReadKey: try ReadKey(rawRepresentation: raw("far-read")),
            lostReadKey: try ReadKey(rawRepresentation: raw("lost-read")),
            lostActionKey: try ActionKey(rawRepresentation: raw("lost-action")),
            houseKey: try ActionKey(rawRepresentation: raw("house-action")),
            houseLines: readText("\(keys)/house.txt"),
            lampd: option("lampd"), fixture: option("fixture"), log: option("log"), name: option("name")
        )
    } catch {
        fail("\(error)")
    }
    Instrument.prove(quietly: true)
    let filter = arguments.count % 2 == 0 ? arguments.last : nil
    let target = LampDTarget(node)
    let code = TestRunner.runAndReport(LampDChecks.suites(node, target), filter: filter)
    target.finish()
    exit(code)
case "real":
    // A real machine with a test key (W3's exit on the Linux machine): 10 MiB,
    // the cycles of the background rule, the first frame, all on a tmux server
    // of the check's own (`-L lb-…`), never the person's.
    //   NodeLinkCheck real --host H --port P --user U --host-key F --keys <dir> --socket lb-…
    //                      [--cycles 20] [--frames 20] [--limit 1.5] [filter]
    guard #available(macOS 15.0, *) else { fail("needs macOS 15 or Linux") }
    let socket = option("socket")
    guard socket.hasPrefix("lb-"), let server = TmuxSizeRule.Server.named(socket) else {
        fail("--socket must be a tmux server of the check's own, named lb-…: never the person's")
    }
    func optional(_ name: String, _ fallback: String) -> String {
        guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return fallback }
        return arguments[index + 1]
    }
    let keyText = readText(option("keys") + "/action.key").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: keyText) else { fail("action.key is not base64") }
    let node: RealNode
    do {
        node = RealNode(
            endpoint: NodeEndpoint(host: option("host"), port: Int(option("port")) ?? 22, user: option("user")),
            hostKey: try NodeHostKey(openSSH: readText(option("host-key"))),
            actionKey: try ActionKey(rawRepresentation: raw), server: server, socketName: socket,
            cycles: Int(optional("cycles", "20")) ?? 20, frames: Int(optional("frames", "20")) ?? 20,
            firstFrameLimit: Double(optional("limit", "1.5")) ?? 1.5)
    } catch {
        fail("\(error)")
    }
    Instrument.prove(quietly: true)
    let known = ["--host", "--port", "--user", "--host-key", "--keys", "--socket", "--cycles", "--frames", "--limit"]
    var rest = Array(arguments.dropFirst())
    var filter: String?
    while !rest.isEmpty {
        if known.contains(rest[0]), rest.count >= 2 { rest.removeFirst(2) } else { filter = rest.removeFirst() }
    }
    exit(TestRunner.runAndReport([RealNodeChecks.suite(node)], filter: filter))
default:
    fail("usage: NodeLinkCheck keys <dir> [prefix] | run … | lampd … | real …")
}
