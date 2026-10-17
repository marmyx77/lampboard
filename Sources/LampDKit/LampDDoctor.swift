import Foundation
import LampBoardCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `lampd doctor`: everything `lampd` depends on, each said in a sentence, read
/// without changing anything. Green, yellow or red per line; red if any is red.
///
/// It runs nothing of Claude Code's: `claude` is looked for on the `PATH`, not
/// executed (S-G: the `PATH` of `systemd --user` on this machine does not have
/// `~/.local/bin`, and that alone turned every light grey).
public enum LampDDoctor {

    public enum Verdict: String, Sendable { case green, yellow, red }

    public struct Line: Equatable, Sendable {
        public let verdict: Verdict
        public let text: String
    }

    public static func run(paths: LampDPaths, config: LampDConfig, configProblem: String?,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           at now: Date = Date()) -> [Line] {
        var lines: [Line] = []
        func say(_ verdict: Verdict, _ text: String) { lines.append(Line(verdict: verdict, text: text)) }

        // The tools the look needs.
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let python = find("python3", in: path) { say(.green, "python3 is \(python): the look at the files can run") }
        else { say(.red, "python3 is not on PATH: lampd cannot read Claude Code's files") }
        if let tmux = find("tmux", in: path) { say(.green, "tmux is \(tmux)") }
        else { say(.yellow, "tmux is not on PATH: rows will not say which tmux session holds them") }
        let localBin = paths.home + "/.local/bin"
        if let claude = find("claude", in: path) {
            say(.green, "claude is \(claude) (found, not run)")
        } else if FileManager.default.isExecutableFile(atPath: localBin + "/claude") {
            say(.red, "claude is in \(localBin) but PATH does not have \(localBin): the unit must set it")
        } else {
            say(.yellow, "claude is not on PATH: no session will be found until it is installed")
        }
        if let problem = configProblem { say(.yellow, problem) }

        // The service, and how old what it knows is.
        if let answer = LampDStatus.ask(paths.socket, line: "status", timeout: 5),
           let object = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any] {
            let age = (object["stateAgeSeconds"] as? NSNumber)?.doubleValue
            let limit = config.probeInterval * 3 + 5
            if let age, age <= limit {
                say(.green, "the service answers (pid \(object["pid"] ?? "?")), its state is \(Int(age)) s old")
            } else {
                say(.red, "the service answers but its state is \(age.map { "\(Int($0)) s" } ?? "of no age") old (limit \(Int(limit)) s): alive on an old state")
            }
            if let problem = object["lastProbeProblem"] as? String { say(.red, "its last look failed: \(problem)") }
            let started = (object["startedAt"] as? String).flatMap(ISO8601DateFormatter().date)
            if let started, let binary = LampDBinary.modified(paths.home + "/.local/bin/lampd"), binary > started {
                say(.yellow, "the installed lampd is newer than the running one: restart the service")
            }
            if let started, let config = LampDBinary.modified(paths.configFile), config > started {
                say(.yellow, "the configuration changed after the service started: restart it")
            }
        } else {
            say(.red, "the service does not answer on \(paths.socket): phones read the files through v1-stdio until it is back")
        }

        // The phones' lines.
        lines += devices(paths: paths)

        // The contract of Claude Code's events on this machine.
        if let stamp = ContractStamp.load(paths.contractFile) {
            let verdict: Verdict = stamp.outcome == "pass" ? .green : stamp.outcome == "fail" ? .red : .yellow
            say(verdict, "contract \(stamp.outcome) for Claude Code \(stamp.claudeVersion), checked \(ISO8601DateFormatter().string(from: stamp.checkedAt))\(stamp.live ? " with a live probe" : "")")
        } else {
            say(.yellow, "the contract has not been checked on this machine yet")
        }
        return lines
    }

    /// The marked lines and the register agree, the command they force exists,
    /// and sshd's `StrictModes` would accept the file.
    static func devices(paths: LampDPaths) -> [Line] {
        var out: [Line] = []
        let listed = DevicesStore(paths: paths).list()
        if listed.isEmpty { out.append(Line(verdict: .yellow, text: "no device is paired: run `lampd devices add` with the keys the app shows")) }
        for device in listed {
            let roles = Set(device.roles)
            if device.entry == nil {
                out.append(Line(verdict: .yellow, text: "\(device.id) has lines in authorized_keys and no entry in the register"))
            } else if roles != [.read, .action] {
                out.append(Line(verdict: .red, text: "\(device.id) is registered but its lines are \(roles.isEmpty ? "missing" : roles.map(\.rawValue).sorted().joined(separator: ", ") + " only")"))
            } else {
                out.append(Line(verdict: .green, text: "\(device.id) (\(device.entry?.name ?? "")): read and action lines in place"))
            }
        }
        let text = (try? String(contentsOfFile: paths.authorizedKeys, encoding: .utf8)) ?? ""
        for line in text.components(separatedBy: "\n") where AuthorizedKeys.owner(of: line)?.role == .read {
            if let range = line.range(of: "command=\""), let end = line[range.upperBound...].firstIndex(of: " ") {
                let command = String(line[range.upperBound..<end])
                if !FileManager.default.isExecutableFile(atPath: command) {
                    out.append(Line(verdict: .red, text: "a read key's line runs \(command), which is not there: that phone cannot connect"))
                }
            }
        }
        for (path, name) in [(paths.home + "/.ssh", "~/.ssh"), (paths.authorizedKeys, "authorized_keys")] {
            var info = stat()
            if stat(path, &info) == 0, Int(info.st_mode) & 0o022 != 0 {
                out.append(Line(verdict: .red, text: "\(name) can be written by others: sshd's StrictModes refuses every key in it"))
            }
        }
        return out
    }

    static func find(_ tool: String, in path: [String]) -> String? {
        path.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
