import Foundation
import LampBoardCore
import LampDKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// lampd: LampBoard's service on a Linux machine (ADR-65 of the node's register,
// §2.1 of the mobile plan). In this first form it reads Claude Code's files
// with the Core's rules and serves them to the phone over `v1`; it binds no
// network port and takes no hook (W3, "in the shade").
//
//   lampd serve                       the service (systemd --user)
//   lampd v1-stdio --device <id> [--role read|action]
//                                     the command a read key is forced to run
//   lampd devices add --name <name> --read '<key>' --action '<key>' [--id <id>]
//                     [--from <network,…>] [--command <path>]
//   lampd devices list
//   lampd devices revoke <id>
//   lampd status                      what the running service says of itself
//   lampd doctor                      everything lampd depends on, read only
//   lampd usage [--cached]            this machine's allowance, asked once (or as last kept)
//   lampd look                        asks the service to look at the files now
//   lampd replay <flow.jsonl>         recorded hooks, reduced as the tee will
//   lampd version

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)

let version = LampDVersion.current
let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let paths = LampDPaths.current(environment: environment)
let (config, configProblem) = LampDConfig.load(paths.configFile)

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("lampd: \(message)\n".utf8))
    exit(code)
}

func option(_ name: String, in list: [String] = arguments) -> String? {
    guard let index = list.firstIndex(of: "--\(name)"), index + 1 < list.count else { return nil }
    return list[index + 1]
}

func usage() -> Never {
    print("""
    usage: lampd serve | v1-stdio --device <id> [--role read|action] | devices add|list|revoke |
           status | doctor | usage | look | replay <flow.jsonl> | version
    """)
    exit(2)
}

switch arguments.first {
case "serve":
    if let problem = configProblem { FileHandle.standardError.write(Data("lampd: \(problem)\n".utf8)) }
    let service = LampDService(paths: paths, config: config, version: version, log: LampDLog(file: nil),
                               testHooks: environment["LAMPD_TEST_HOOKS"] == "1")
    exit(service.run())

case "v1-stdio":
    guard let device = option("device"), V1Validation.isSessionId(device) else { fail("v1-stdio needs --device <id>") }
    let role = option("role").flatMap(V1Role.init(rawValue:)) ?? .read
    exit(LampDStdio.run(paths: paths, config: config, version: version, device: device, role: role,
                        asked: environment["SSH_ORIGINAL_COMMAND"] ?? ""))

case "devices":
    let store = DevicesStore(paths: paths)
    switch arguments.dropFirst().first {
    case "add":
        guard let name = option("name"), let read = option("read"), let action = option("action") else {
            fail("devices add needs --name, --read and --action")
        }
        let id = option("id") ?? DeviceIds.make(name: name, readKey: read)
        let from = option("from").map { $0.split(separator: ",").map(String.init) } ?? LocalNetworks.defaults()
        let command = option("command") ?? LampDInstall.commandPath(home: paths.home)
        switch DevicesStore.addition(id: id, name: name, readKey: read, actionKey: action, from: from, command: command) {
        case .failure(let error):
            fail("\(error): nothing was written")
        case .success(let addition):
            do { try store.add(addition) } catch { fail("\(error)", code: 1) }
            print("added \(addition.id) (\(addition.name)) from \(addition.from)")
            print("  read key:   v1 only, through \(addition.command) v1-stdio")
            print("  action key: terminal, commands and files")
        }
    case "list":
        let listed = store.list()
        if listed.isEmpty { print("no device is paired") }
        for device in listed {
            let roles = device.roles.map(\.rawValue).joined(separator: "+")
            let entry = device.entry.map { "\($0.name), paired \(ISO8601DateFormatter().string(from: $0.pairedAt))"
                + ($0.lastSeenAt.map { ", seen \(ISO8601DateFormatter().string(from: $0))" } ?? "") } ?? "no entry in the register"
            print("\(device.id)  [\(roles.isEmpty ? "no lines" : roles)]  \(entry)")
        }
    case "revoke":
        guard arguments.count >= 3 else { fail("devices revoke <id>") }
        do {
            let had = try store.revoke(arguments[2])
            print(had ? "revoked \(arguments[2]): its lines are gone from authorized_keys" : "no device \(arguments[2])")
            exit(had ? 0 : 1)
        } catch {
            fail("\(error)", code: 1)
        }
    default:
        fail("devices add | list | revoke <id>")
    }

case "status":
    guard let answer = LampDStatus.ask(paths.socket, line: "status", timeout: 10) else {
        print("{\"running\":false,\"socket\":\"\(paths.socket)\"}")
        exit(1)
    }
    print(answer)

case "look":
    guard let answer = LampDStatus.ask(paths.socket, line: "look", timeout: 25) else { fail("the service does not answer", code: 1) }
    print(answer)
    exit(answer.hasPrefix("ok") ? 0 : 1)

case "doctor":
    let lines = LampDDoctor.run(paths: paths, config: config, configProblem: configProblem)
    for line in lines {
        let mark = line.verdict == .green ? "✓" : line.verdict == .yellow ? "⚠" : "✗"
        print("\(mark) \(line.text)")
    }
    exit(lines.contains { $0.verdict == .red } ? 1 : 0)

case "usage":
    if arguments.contains("--cached") {
        // What the service's refresher last wrote ("allowance": true in the configuration).
        guard let data = FileManager.default.contents(atPath: paths.allowanceFile),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail("no reading kept: the service asks only with \"allowance\": true in \(paths.configFile)", code: 1)
        }
        print("read at \(object["at"] as? String ?? "?")")
        for line in object["lines"] as? [String] ?? [] { print(line) }
        exit(0)
    }
    let reading = LampDUsage.read(paths: paths, name: config.name)
    for line in LampDUsage.lines(reading) { print(line) }
    exit(reading.reports.isEmpty ? 1 : 0)

case "replay":
    guard arguments.count >= 2, let text = try? String(contentsOfFile: arguments[1], encoding: .utf8) else {
        fail("replay <flow.jsonl>")
    }
    do {
        let steps = HookReplay.replay(try HookReplay.events(in: text), workspace: option("workspace") ?? "/tmp/lampd-replay",
                                      start: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder.sorted.encode(steps)
        print(String(decoding: data, as: UTF8.self))
    } catch {
        fail("\(error)", code: 1)
    }

case "version", "--version":
    print("lampd \(version)")

default:
    usage()
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}
