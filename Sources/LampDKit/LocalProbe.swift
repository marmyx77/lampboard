import Foundation
import LampBoardCore

/// One look at this machine's Claude Code sessions, the way the phone looks at
/// it over ssh: the same command, read back by the same parser.
///
/// That is the whole point of running a shell command from a service that could
/// read the files itself. The rule of what a session file and the tail of its
/// transcript mean (M23–M25: `busy`, `shell`, `idle`, `waiting`, the turn, when
/// the session last spoke) is written once, in the Core's probe and its
/// decoder. The phone reads a machine without `lampd` with it; `lampd` reads its
/// own machine with it; a check holds the two to the same lights on the same
/// recordings (§6.2, "one rule for the files"). A second reader in Swift would
/// be the copy that drifts.
///
/// Read-only like the phone's look: the probe reads files and asks tmux for its
/// panes, `python3 -B` writes no bytecode, and no tmux server is started where
/// there is none.
public struct LocalProbe: Sendable {
    public let paths: LampDPaths
    /// Seconds before a look that has not answered is given up: it runs inside
    /// the service's main loop, which the watchdog times.
    public let deadline: TimeInterval
    /// Set over the inherited environment: the home the files are read under,
    /// and, for the checks, the directory of an isolated tmux server.
    public let environment: [String: String?]

    public init(paths: LampDPaths, deadline: TimeInterval = 8, environment: [String: String?] = [:]) {
        self.paths = paths
        self.deadline = deadline
        self.environment = environment
    }

    /// What one look found: the reading, or why there is none.
    public struct Look: Sendable {
        public let reading: V1ProbeReading?
        public let jobs: [String: BackgroundJob]
        public let problem: String?
        public let at: Date
        public let took: TimeInterval

        public init(reading: V1ProbeReading?, jobs: [String: BackgroundJob] = [:], problem: String? = nil,
                    at: Date, took: TimeInterval = 0) {
            self.reading = reading
            self.jobs = jobs
            self.problem = problem
            self.at = at
            self.took = took
        }
    }

    public func look(at now: Date = Date()) -> Look {
        let started = Date()
        var env = environment
        env["HOME"] = paths.home
        do {
            let result = try Command.run(
                "/bin/sh", ["-c", V1ProbeReading.command()], deadline: deadline,
                capturingStandardError: false, environment: env
            )
            let jobs = BackgroundJobs.read(paths.claudeDirectory + "/jobs")
            guard result.succeeded else {
                return Look(reading: nil, jobs: jobs, problem: "the probe exited \(result.status)", at: now,
                            took: Date().timeIntervalSince(started))
            }
            guard let reading = V1ProbeReading.parse(result.output, host: "", at: now) else {
                return Look(reading: nil, jobs: jobs, problem: "the probe's answer could not be read (is python3 here?)",
                            at: now, took: Date().timeIntervalSince(started))
            }
            return Look(reading: reading, jobs: jobs, problem: nil, at: now, took: Date().timeIntervalSince(started))
        } catch let failure as Command.Failure {
            return Look(reading: nil, jobs: [:], problem: failure.explanation, at: now, took: Date().timeIntervalSince(started))
        } catch {
            return Look(reading: nil, jobs: [:], problem: "\(error)", at: now, took: Date().timeIntervalSince(started))
        }
    }
}

/// The Agent View's job files (`~/.claude/jobs/<id>/state.json`, AV2), by the
/// session each names: what a background session's row says it has done and
/// what it waits for, and the id `claude attach` takes.
public enum BackgroundJobs {
    /// How many job folders are looked at, newest first: a machine that ran a
    /// thousand background sessions keeps a thousand folders.
    public static let limit = 200

    public static func read(_ directory: String) -> [String: BackgroundJob] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return [:] }
        let dated = names.compactMap { name -> (String, Date)? in
            guard BackgroundJobParser.isSafe(id: name) else { return nil }
            let path = directory + "/" + name + "/state.json"
            guard let attributes = try? manager.attributesOfItem(atPath: path),
                  let date = attributes[.modificationDate] as? Date else { return nil }
            return (name, date)
        }
        var jobs: [String: BackgroundJob] = [:]
        for (name, _) in dated.sorted(by: { $0.1 > $1.1 }).prefix(limit) {
            guard let data = manager.contents(atPath: directory + "/" + name + "/state.json"),
                  data.count <= 256 * 1024,
                  let job = BackgroundJobParser.parse(data: data, id: name),
                  jobs[job.sessionId] == nil else { continue }
            jobs[job.sessionId] = job
        }
        return jobs
    }
}
