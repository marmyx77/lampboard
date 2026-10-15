import Foundation
import LampBoardCore
@_spi(Probe) import LampBoardNodeLink
import ProtocolConformance
import TestKit

// NodeLink over a real ssh (D175): the `v1` conformance battery against the
// reference node behind OpenSSH, and the bites of the keys — a changed host key
// is refused before anything is sent, a read key that asks for anything else
// gets `v1` and nothing else, an unknown key does not get in. Run by
// Scripts/test-nodelink.sh, in a container, against a node in another one.
//
//   NodeLinkCheck keys <dir>      writes read.key/.pub and action.key/.pub
//   NodeLinkCheck run --host H --port P --user U --host-key F --wrong-host-key F
//                     --keys <dir> --reference <path on the node> --socket <path on the node>
//                     --log <path on the node> --silent-port P [filter]

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
    guard arguments.count == 2 else { fail("keys <dir>") }
    let dir = arguments[1]
    let read = ReadKey.generate(), action = ActionKey.generate()
    for (name, raw, pub) in [("read", read.rawRepresentation, read.publicKey), ("action", action.rawRepresentation, action.publicKey)] {
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
            silentPort: Int(option("silent-port")) ?? 0
        )
    } catch {
        fail("\(error)")
    }
    Instrument.prove(quietly: true)
    let filter = arguments.count % 2 == 0 ? arguments.last : nil
    let target = SSHConformanceTarget(node)
    let code = TestRunner.runAndReport([V1Conformance.suite(against: target), KeyBites.suite(node)], filter: filter)
    target.finish()
    exit(code)
default:
    fail("usage: NodeLinkCheck keys <dir> | run …")
}
