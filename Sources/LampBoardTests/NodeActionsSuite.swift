import Foundation
import LampBoardCore
import TestKit

/// What a device asks of a machine with its action key (W3 of the mobile plan):
/// each action's arguments, and the scripts that end, move, take up and attach
/// run for real, under a home of their own, with processes started here.
enum NodeActionsSuite {

    // MARK: - Running a script as the machine would

    struct Ran { let output: String; let status: Int32 }

    /// `command` under `/bin/sh -c`, with `home` as its home and `path` first on PATH.
    static func sh(_ command: String, home: String, path: String? = nil, wait: Bool = true) -> (Process, Ran?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["SHELL"] = "/bin/sh"
        if let path { env["PATH"] = path + ":" + (env["PATH"] ?? "/usr/bin:/bin") }
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (process, nil) }
        guard wait else { return (process, nil) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process, Ran(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus))
    }

    static func temporaryHome() -> String {
        let path = NSTemporaryDirectory() + "lb-actions-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: path + "/.claude/sessions", withIntermediateDirectories: true)
        // The real path, as `pwd -P` gives it: Foundation's own resolving gives a
        // Mac's /private/var back as /var.
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// A process that stays, and its start as Claude Code writes it.
    static func sleeper() -> (Process, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        guard (try? process.run()) != nil else { return nil }
        let pid = process.processIdentifier
        let probe = "import os,subprocess\ntry:\n print(open('/proc/%d/stat' % \(pid)).read().rsplit(')',1)[1].split()[19])\n"
            + "except FileNotFoundError:\n print(subprocess.run(['ps','-o','lstart=','-p','\(pid)'],capture_output=True,text=True,env=dict(os.environ,TZ='UTC')).stdout.strip())\n"
        let start = sh("python3 -c " + NewSession.shellQuoted(probe), home: NSTemporaryDirectory()).1?.output
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process, start)
    }

    /// The session file Claude Code writes for `pid`.
    static func writeSession(home: String, pid: Int32, session: String, start: String, entrypoint: String = "cli") {
        let record: [String: Any] = ["pid": Int(pid), "sessionId": session, "cwd": home, "procStart": start,
                                     "entrypoint": entrypoint, "status": "idle"]
        let data = (try? JSONSerialization.data(withJSONObject: record)) ?? Data()
        _ = FileManager.default.createFile(atPath: "\(home)/.claude/sessions/\(pid).json", contents: data)
    }

    static func command(_ action: NodeAction, bypassAllowed: Bool = false) -> String? {
        try? action.command(bypassAllowed: bypassAllowed).get()
    }

    static let id = "11111111-2222-4333-8444-555555555555"
    static let other = "99999999-2222-4333-8444-555555555555"

    static let suite = TestSuite("A device's actions on a machine", [

        TestCase("No action is built from an argument that is not one") { t in
            let launch = NewSession.newLaunchTag()
            t.expectNil(command(.start(folder: "work/app", name: "app", launch: launch, start: .new(sessionId: id))),
                        "a relative folder")
            t.expectNil(command(.start(folder: "/w/app", name: "a:b", launch: launch, start: .new(sessionId: id))),
                        "a name tmux reads as a window")
            t.expectNil(command(.start(folder: "/w/app", name: "app", launch: "x; rm -rf ~", start: .new(sessionId: id))),
                        "a tag that is not one")
            t.expectNil(command(.start(folder: "/w/app", name: "app", launch: launch, start: .new(sessionId: "--help"))),
                        "an id that is not a conversation's")
            t.expectNil(command(.end(session: "x'; kill -9 1", tmux: nil)), "End of something that is not an id")
            t.expectNil(command(.end(session: id, tmux: "a.b")), "End in a tmux name tmux would not take")
            t.expectNil(command(.move(session: id, pid: 1, procStart: "123")), "never init")
            t.expectNil(command(.move(session: id, pid: 4242, procStart: "1'); import os")), "a start that is not one")
            t.expectNil(command(.browse(path: "relative")), "Browse from a relative folder")
            t.expectNil(command(.files(root: "/", relative: nil)), "the whole disk is not a project")
            t.expectNil(command(.read(root: "/w/app", relative: "../etc/passwd")), "a file out of the project")
            t.expectNil(command(.message(session: id, text: "   ")), "an empty message")
            t.expectNil(command(.message(session: id, text: String(repeating: "x", count: 70_000))), "a message past the box")
            t.expectNil(command(.projects(.attach("relative"))), "a project that is not absolute")
            t.expectNil(NodeTerminalCommand.background(job: "--help").command, "an attach of an option")
            t.expectNil(NodeTerminalCommand.shell(root: "relative").command, "a shell in a relative folder")
        },

        TestCase("Bypass from the start is refused until it is turned on where it is kept (W5)") { t in
            let launch = NewSession.newLaunchTag()
            let bypass = NodeAction.start(folder: "/w/app", name: "app", launch: launch,
                                          start: .new(sessionId: id, permissions: .bypass))
            t.expectEqual(bypass.command(), .failure(.bypassOff), "off: no command")
            t.expect(command(bypass, bypassAllowed: true)?.contains("--dangerously-skip-permissions") == true, "on: the flag")
            let offered = NodeAction.start(folder: "/w/app", name: "app", launch: launch,
                                           start: .new(sessionId: id, permissions: .allowBypass))
            t.expect(command(offered)?.contains("--allow-dangerously-skip-permissions") == true,
                     "offered on Shift+Tab is not Bypass from the start")
            t.expectEqual(offered.name, "new-session")
            t.expectEqual(NodeAction.start(folder: "/w", name: "w", launch: launch, start: .resume(sessionId: id)).name, "resume")
        },

        TestCase("A start says the tmux session it made, a held conversation, or the machine's words") { t in
            t.expectEqual(NodeAction.started(output: "app-2\n", exitCode: 0), .started(tmux: "app-2"))
            t.expectEqual(NodeAction.started(output: "lampboard:held\n", exitCode: 4), .held)
            t.expectEqual(NodeAction.started(output: "There is no folder '/x' on this machine.\n", exitCode: 1),
                          .failed("There is no folder '/x' on this machine."))
            t.expectEqual(NodeAction.notSent(#"{"ok": true, "reason": null}"#), nil)
            t.expectEqual(NodeAction.notSent(#"{"ok": false, "reason": "no box"}"#), "no box")
            t.expectEqual(NodeAction.notSent("Traceback"), "the machine did not answer")
        },

        TestCase("End: a reused pid is refused and left running; the process its file names is ended") { t in
            let home = temporaryHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            guard let (process, start) = sleeper(), !start.isEmpty else { return t.fail("no process to try") }
            defer { if process.isRunning { process.terminate() } }
            // The file names this pid with another start: a pid handed on to another program.
            writeSession(home: home, pid: process.processIdentifier, session: id, start: start + "9")
            guard let script = command(.end(session: id, tmux: nil)) else { return t.fail("no command") }
            t.expectEqual(RemoteEnd.outcome(sh(script, home: home).1?.output ?? ""), .notIt, "a reused pid: not it")
            t.expect(process.isRunning, "and the program now on that pid still runs")
            t.expectEqual(RemoteEnd.outcome(sh(command(.end(session: other, tmux: nil)) ?? "", home: home).1?.output ?? ""),
                          .notIt, "a conversation no file names: not it")
            writeSession(home: home, pid: process.processIdentifier, session: id, start: start)
            t.expectEqual(RemoteEnd.outcome(sh(script, home: home).1?.output ?? ""), .ended, "its own start: ended")
            process.waitUntilExit()
            t.expect(!process.isRunning, "ended with SIGTERM")
        },

        TestCase("Move: a second Move of the same conversation is refused while the first holds the lock") { t in
            let home = temporaryHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            guard let (first, start) = sleeper(), let (second, start2) = sleeper() else { return t.fail("no process to try") }
            defer { for p in [first, second] where p.isRunning { p.terminate() } }
            guard let move = command(.move(session: id, pid: first.processIdentifier, procStart: start)),
                  let again = command(.move(session: id, pid: second.processIdentifier, procStart: start2)),
                  let done = command(.moveDone(session: id)) else { return t.fail("no command") }
            t.expectEqual(RemoteMove.outcome(sh(move, home: home).1?.output ?? ""), .ended, "the first Move ends its process")
            t.expect(FileManager.default.fileExists(atPath: home + "/.lampboard/moving/" + id), "and keeps the lock")
            t.expectEqual(RemoteMove.outcome(sh(again, home: home).1?.output ?? ""), .locked, "the second is refused")
            t.expect(second.isRunning, "and ended nothing")
            _ = sh(done, home: home)
            t.expect(!FileManager.default.fileExists(atPath: home + "/.lampboard/moving/" + id), "taken up: the lock goes")
            // A lock left by a Move cut off half-way does not hold for ever.
            try? FileManager.default.createDirectory(atPath: home + "/.lampboard/moving/" + id, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-RemoteMove.lockLasts - 30)],
                                                   ofItemAtPath: home + "/.lampboard/moving/" + id)
            t.expectEqual(RemoteMove.outcome(sh(again, home: home).1?.output ?? ""), .ended, "a stale lock is taken over")
            second.waitUntilExit()
            // Nothing ended: no lock left behind.
            guard let (third, start3) = sleeper() else { return t.fail("no process") }
            defer { if third.isRunning { third.terminate() } }
            _ = sh(done, home: home)
            t.expectEqual(RemoteMove.outcome(sh(command(.move(session: other, pid: third.processIdentifier,
                                                              procStart: start3 + "9")) ?? "", home: home).1?.output ?? ""),
                          .notIt)
            t.expect(!FileManager.default.fileExists(atPath: home + "/.lampboard/moving/" + other), "not it: the lock went with it")
        },

        TestCase("Resume refuses a conversation a live process holds, and goes on for one nobody holds") { t in
            let home = temporaryHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            guard let (process, start) = sleeper() else { return t.fail("no process to try") }
            defer { if process.isRunning { process.terminate() } }
            writeSession(home: home, pid: process.processIdentifier, session: id, start: start)
            let guarded = NewSession.posix(NodeAction.unlessHeld(id) + "\necho free")
            let held = sh(guarded, home: home).1
            t.expectEqual(held?.output, "lampboard:held\n", "held: refused before tmux is touched")
            t.expectEqual(held?.status, 4)
            writeSession(home: home, pid: process.processIdentifier, session: id, start: start + "9")
            t.expectEqual(sh(guarded, home: home).1?.output, "free\n", "a file whose pid was reused holds nothing")
            t.expect(command(.start(folder: "/w", name: "w", launch: NewSession.newLaunchTag(),
                                    start: .resume(sessionId: id)))?.contains("lampboard:held") == true,
                     "every Resume carries the check")
            t.expect(command(.start(folder: "/w", name: "w", launch: NewSession.newLaunchTag(),
                                    start: .new(sessionId: id)))?.contains("lampboard:held") == false,
                     "a new conversation has nothing to check")
        },

        TestCase("A background session is attached once: a second attach is refused while the first is open") { t in
            let home = temporaryHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            let bin = home + "/bin"
            try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: bin + "/claude", contents: Data("#!/bin/sh\necho \"attached $2\"\nsleep 3\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
            // As on a machine: the login shell's own startup file puts `claude` on PATH
            // (a Linux /etc/profile sets PATH afresh).
            _ = FileManager.default.createFile(atPath: home + "/.profile", contents: Data("PATH=\"$HOME/bin:$PATH\"\n".utf8))
            guard let attach = NodeTerminalCommand.background(job: "1bd0d072").command else { return t.fail("no command") }
            let (first, _) = sh(attach, home: home, wait: false)
            defer { if first.isRunning { first.terminate() } }
            // The first holds the lock once its `claude` speaks.
            var waited = 0
            while waited < 50, !FileManager.default.fileExists(atPath: home + "/.lampboard/attach/1bd0d072.lock") {
                Thread.sleep(forTimeInterval: 0.1); waited += 1
            }
            Thread.sleep(forTimeInterval: 0.5)
            let second = sh(attach, home: home).1
            t.expectEqual(second?.status, Int32(BackgroundAttach.refusedStatus), "the second is refused")
            t.expect(second?.output.contains(BackgroundAttach.refusal) == true, "and says why")
            first.waitUntilExit()
            let third = sh(attach, home: home).1
            t.expect(third?.output.contains("attached 1bd0d072") == true, "the first gone, the next one attaches: \(third?.output ?? "")")
        },

        TestCase("A look names each session's process with the start its file gives: what a Move needs") { t in
            let home = temporaryHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            guard let (process, start) = sleeper() else { return t.fail("no process to try") }
            defer { if process.isRunning { process.terminate() } }
            writeSession(home: home, pid: process.processIdentifier, session: id, start: start, entrypoint: "claude-vscode")
            let out = sh("python3 -B -c " + NewSession.shellQuoted(RemoteProbeScript.script), home: home).1?.output ?? ""
            let report = try? RemoteSessionsDecoder.report(from: Data(out.utf8), host: "example-node", at: Date())
            let found = report?.sessions.first { $0.sessionId == id }
            t.expectEqual(found?.pid, Int(process.processIdentifier), "the process")
            t.expectEqual(found?.procStart, start, "and its start, so that a Move ends that process and no other")
        },

        TestCase("Attachments: the folder made inside the project, and refused when it leads out") { t in
            let home = temporaryHome()
            defer { try? FileManager.default.removeItem(atPath: home) }
            let project = home + "/app"
            try? FileManager.default.createDirectory(atPath: project + "/.git/info", withIntermediateDirectories: true)
            guard let script = command(.attachments(root: project)) else { return t.fail("no command") }
            let made = sh(script, home: home).1
            let listing = made.flatMap { RemoteProject.attachmentsListing($0.output) }
            t.expectEqual(listing?.folder, project + "/" + ProjectAttachments.folder, "the folder, resolved")
            t.expectEqual(listing?.taken, [], "empty")
            _ = FileManager.default.createFile(atPath: project + "/" + ProjectAttachments.folder + "/shot.png", contents: Data())
            t.expectEqual(sh(script, home: home).1.flatMap { RemoteProject.attachmentsListing($0.output) }?.taken, ["shot.png"])
            let exclude = (try? String(contentsOfFile: project + "/.git/info/exclude", encoding: .utf8)) ?? ""
            t.expectEqual(exclude.components(separatedBy: "\n").filter { $0 == ".lampboard/" }.count, 1, "out of git, once")
            let elsewhere = home + "/elsewhere"
            let trap = home + "/trap"
            try? FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: trap, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: trap + "/.lampboard", withDestinationPath: elsewhere)
            let refused = sh(command(.attachments(root: trap)) ?? "", home: home).1
            t.expect(refused?.status != 0, "a .lampboard that is a link out: refused")
            t.expectNil(refused.flatMap { RemoteProject.attachmentsListing($0.output) })
        },

        TestCase("A paste never ends early and never presses Enter (H1.2-10)") { t in
            let sneaky = "@src/a.swift \u{1b}[201~\rrm -rf ~\n\u{7}line two"
            let marked = LiveSurfaceText.bytes(sneaky, bracketed: true)
            let text = String(decoding: marked, as: UTF8.self)
            t.expect(text.hasPrefix("\u{1b}[200~") && text.hasSuffix("\u{1b}[201~"), "inside the marks")
            t.expectEqual(text.components(separatedBy: "\u{1b}[201~").count, 2, "the end mark only at the end")
            t.expect(!text.contains("\r") && !text.contains("\u{7}"), "no carriage return, no bell")
            let plain = String(decoding: LiveSurfaceText.bytes("@a.md\nnext", bracketed: false), as: UTF8.self)
            t.expectEqual(plain, "@a.md next", "unmarked, a line break is a space: nothing is sent")
        },

        TestCase("A folder's listing read back: folders end in a slash, . and .. are not entries") { t in
            let entries = RemoteProject.entries("./\n../\nSources/\nREADME.md\n.github/\n")
            t.expectEqual(entries.map(\.name), ["Sources", "README.md", ".github"])
            t.expectEqual(entries.map(\.isFolder), [true, false, true])
        },

        TestCase("The projects from a device's rows: attached first, then the folders sessions are in") { t in
            let now = Date()
            let attached = [AttachedProject(path: "/w/kept", host: nil, addedAt: now)]
            let seen = [ProjectList.Seen(id: "a", path: "/w/app", host: nil, updatedAt: now),
                        ProjectList.Seen(id: "b", path: "/w/app", host: nil, updatedAt: now.addingTimeInterval(-60)),
                        ProjectList.Seen(id: "c", path: "/w/kept", host: nil, updatedAt: now.addingTimeInterval(-5))]
            let entries = ProjectList.entries(attached: attached, sessions: seen)
            t.expectEqual(entries.map(\.path), ["/w/kept", "/w/app"])
            t.expectEqual(entries.map(\.attached), [true, false])
            t.expectEqual(entries.last?.sessionIds, ["a", "b"], "the most recent first")
        },
    ])
}
