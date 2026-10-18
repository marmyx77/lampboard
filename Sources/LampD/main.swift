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
//   lampd name [<name>]               the machine's name on the phones, shown or set
//   lampd look                        asks the service to look at the files now
//   lampd compare                     the service's lamps against the phone's look, now
//   lampd replay <flow.jsonl>         recorded hooks, reduced as the tee will
//   lampd mac-link                    what the Mac's tunnel runs here: beats up, the Mac's lines down (W5)
//   lampd routes                      the hooks' port's route table, as JSON
//   lampd rows                        the rows the service serves now, as JSON
//   lampd release                     the hooks' port back to the Mac, until the file it leaves is removed
//   lampd projects list | attach -- <folder> | detach -- <folder>
//                                     the projects kept in the list (JSON, as the phone reads it)
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
           status | doctor | usage | look | replay <flow.jsonl> | projects | name [<name>] |
           mac-link | routes | rows | release | version
    """)
    exit(2)
}

switch arguments.first {
case "serve":
    if let problem = configProblem { FileHandle.standardError.write(Data("lampd: \(problem)\n".utf8)) }
    let hookPort: UInt16?
    switch HookPortOverride.port(environment: environment, paths: paths) {
    case .success(let port): hookPort = port
    case .failure(let error): fail("\(error)")
    }
    let service = LampDService(paths: paths, config: config, version: version, log: LampDLog(file: nil),
                               testHooks: environment["LAMPD_TEST_HOOKS"] == "1", hookPortOverride: hookPort)
    exit(service.run())

case "mac-link":
    let client = MacLinkClient(paths: paths) { line in
        UnixSocket.sendAll(1, Array((line + "\n").utf8))
    }
    exit(client.run(lines: MacLinkClient.standardInputLines()))

case "rows":
    guard let answer = LampDStatus.ask(paths.socket, line: "rows", timeout: 10) else { fail("the service does not answer on \(paths.socket)", code: 1) }
    print(answer)

case "routes":
    print((try? HookRoutes.json()) ?? "[]")

case "release":
    // The service lets the port go and leaves the file that keeps it the Mac's;
    // the socket and its retry timer stop, when systemd is there.
    try? LampDPaths.makeDirectory(paths.stateDirectory)
    _ = FileManager.default.createFile(atPath: paths.releasedFile, contents: Data(), attributes: [.posixPermissions: 0o600])
    let answered = LampDStatus.ask(paths.socket, line: "release", timeout: 5) != nil
    if let systemctl = ["/usr/bin/systemctl", "/bin/systemctl"].first(where: FileManager.default.isExecutableFile) {
        _ = try? Command.run(systemctl, ["--user", "stop", "lampd-socket-retry.timer", "lampd.socket"], deadline: 10)
    }
    print(answered ? "the hooks' port is released: the Mac's tunnel takes it back by itself"
                   : "the service did not answer; \(paths.releasedFile) keeps the port the Mac's at its next start")
    print("to take it again: rm \(paths.releasedFile) && systemctl --user start lampd-socket-retry.timer")

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

case "name":
    // The machine's name on the phone: shown, or set (the service takes it at
    // its next start; `systemctl --user restart lampd`).
    if arguments.count < 2 {
        print(config.name)
        exit(0)
    }
    do {
        let name = try LampDConfig.setName(arguments.dropFirst().joined(separator: " "), at: paths.configFile)
        print("this machine is now «\(name)» for the phones; restart the service: systemctl --user restart lampd")
    } catch {
        fail("\(error)", code: 2)
    }

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

case "compare":
    // One rule for the files, on this machine, now: the service's rows against
    // the phone's own reading of the same files (V1ProbeSource), session by
    // session. Ids cut to eight characters; nothing of a conversation printed.
    guard LampDStatus.ask(paths.socket, line: "look", timeout: 25)?.hasPrefix("ok") == true else {
        fail("the service does not answer: nothing to compare", code: 1)
    }
    let look = LocalProbe(paths: paths).look()
    guard let reading = look.reading else { fail("the look failed: \(look.problem ?? "?")", code: 1) }
    let probe = V1ProbeSource(identity: config.identity, startedAt: Date(), journal: "compare")
    probe.absorb(reading, at: look.at)
    guard let served = LampDCompare.served(socket: paths.socket) else { fail("the service sent no state", code: 1) }
    let lines = LampDCompare.table(probe: probe.snapshot(at: Date()).rows ?? [], served: served)
    for line in lines.rows { print(line) }
    print(lines.summary)
    exit(lines.same ? 0 : 1)

case "projects":
    // What a device asks with its action key (W3): the list, as JSON, after
    // every change. The folder comes after `--`, so a name that starts with a
    // dash is a folder and never an option.
    let store = ProjectsStore(paths: paths)
    let rest = Array(arguments.dropFirst())
    let folder = rest.firstIndex(of: "--").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil }
    do {
        switch rest.first {
        case "list": break
        case "attach":
            guard let folder else { fail("projects attach -- <folder>") }
            _ = try store.attach(folder)
        case "detach":
            guard let folder else { fail("projects detach -- <folder>") }
            _ = try store.detach(folder)
        default: fail("projects list | attach -- <folder> | detach -- <folder>")
        }
    } catch {
        fail("\(error)", code: 1)
    }
    print(String(decoding: ProjectList.encode(store.list()), as: UTF8.self))

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
