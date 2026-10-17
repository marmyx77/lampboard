import Crypto
import Foundation
import LampBoardCore
@_spi(Probe) import LampBoardNodeLink
import TestKit

/// The phone's actions on a node with `lampd` (W3 of the mobile plan), the way
/// the app takes them: each command built by `NodeAction` in the Core, run with
/// the action key over a real OpenSSH, against Claude Code's files played by the
/// fixture and a fake `claude` that writes its session file as the real one does.
@available(macOS 15.0, *)
enum ActionChecks {

    static let home = "/home/dev"
    static let api = "/home/dev/work/api"
    static let held = "a1000000-0000-4000-8000-000000000001"     // busy-open, alive, in tmux "api"
    static let reused = "a1000000-0000-4000-8000-000000000008"   // its file names a pid now another program's
    static let editor = "a1000000-0000-4000-8000-00000000000d"   // in VS Code
    static let box = "b2000000-0000-4000-8000-000000000001"      // with a message box
    static let job = "job-example-1"

    static func suite(_ node: LampDNode, _ target: LampDTarget) -> TestSuite {
        func run(_ action: NodeAction) -> NodeCommandResult? {
            guard let command = try? action.command().get() else { return nil }
            return try? target.run(command)
        }
        func shell(_ command: String) -> String {
            (try? target.run(command).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        }
        func rows() -> [V1Row] {
            _ = try? target.run("\(node.lampd) look")
            return (try? LampDChecks.state(node))?.rows ?? []
        }

        return TestSuite("lampd over ssh: the phone's actions", [

            TestCase("The node is set for actions: frame 0, folders, a project, a fake claude, a box") { t in
                let set = try? target.run("python3 \(node.fixture) frame 0 && python3 \(node.fixture) actions && \(node.lampd) look")
                t.expectEqual(set?.exitCode, 0, "set: \(set?.output ?? "")")
            },

            TestCase("New session: a tmux session with LampBoard's tag, and lampd's row names it") { t in
                let id = UUID().uuidString.lowercased()
                let launch = NewSession.newLaunchTag()
                let action = NodeAction.start(folder: api, name: "api-new", launch: launch, start: .new(sessionId: id))
                guard let ran = run(action) else { return t.fail("no answer") }
                guard case .started(let tmux) = NodeAction.started(output: ran.output, exitCode: ran.exitCode) else {
                    return t.fail("not started: \(ran.output)")
                }
                t.expect(shell("tmux list-sessions -F '#{@lampboard} #{session_name}'").contains("\(launch) \(tmux)"),
                         "tagged \(launch)")
                let again = run(action).map { NodeAction.started(output: $0.output, exitCode: $0.exitCode) }
                t.expectEqual(again, .started(tmux: tmux), "the same tag joins the same session, never a second")
                var row: V1Row?
                for _ in 0..<20 where row?.extras.terminal != "tmux:" + tmux {
                    row = rows().first { $0.id == id }
                    if row?.extras.terminal != "tmux:" + tmux { Thread.sleep(forTimeInterval: 0.5) }
                }
                t.expectEqual(row?.extras.terminal, "tmux:" + tmux, "lampd's row opens that tmux session")
                t.expectEqual(row?.session.path, api, "in its folder")
                // End it: the tmux session holds the process its file names.
                let ended = run(.end(session: id, tmux: tmux)).flatMap { RemoteEnd.outcome($0.output) }
                t.expectEqual(ended, .ended, "End closes it")
                t.expectEqual(shell("tmux has-session -t '=\(tmux)' 2>/dev/null && echo there || echo gone"), "gone",
                              "its tmux session is gone")
            },

            TestCase("Resume of a conversation a live process holds is refused, and nothing starts") { t in
                let launch = NewSession.newLaunchTag()
                let ran = run(.start(folder: api, name: "api-again", launch: launch, start: .resume(sessionId: held)))
                t.expectEqual(ran.map { NodeAction.started(output: $0.output, exitCode: $0.exitCode) }, .held, "held")
                t.expect(!shell("tmux list-sessions -F '#{@lampboard}'").contains(launch), "no tmux session was made")
            },

            TestCase("End with a pid reused since the file was written is refused, and the program on it runs on") { t in
                let pid = shell("python3 -c \"import json,glob,os;print([json.load(open(p))['pid'] for p in glob.glob(os.path.expanduser('~/.claude/sessions/*.json')) if json.load(open(p))['sessionId']=='\(reused)'][0])\"")
                t.expect(Int(pid) != nil, "the reused file names a pid: \(pid)")
                t.expectEqual(run(.end(session: reused, tmux: nil)).flatMap { RemoteEnd.outcome($0.output) }, .notIt,
                              "refused: not it")
                t.expectEqual(shell("kill -0 \(pid) && echo alive"), "alive", "the program on that pid was not signalled")
                _ = shell("tmux new-session -d -s lbcheck-other 'sleep 600'")
                t.expectEqual(run(.end(session: held, tmux: "lbcheck-other")).flatMap { RemoteEnd.outcome($0.output) }, .notIt,
                              "a tmux session that does not hold the conversation is not closed")
                t.expectEqual(shell("tmux has-session -t '=lbcheck-other' 2>/dev/null && echo there"), "there", "and it is still there")
                _ = shell("tmux kill-session -t '=lbcheck-other'")
            },

            TestCase("End in a tmux session of several panes ends the conversation and keeps the other panes") { t in
                let id = UUID().uuidString.lowercased()
                _ = shell("tmux new-session -d -s lbcheck-two -c \(api) '$HOME/.local/bin/claude --session-id \(id)' && tmux split-window -t '=lbcheck-two:' 'sleep 600'")
                var there = false
                for _ in 0..<20 where !there {
                    there = shell("grep -l \(id) ~/.claude/sessions/*.json 2>/dev/null").isEmpty == false
                    if !there { Thread.sleep(forTimeInterval: 0.3) }
                }
                t.expect(there, "the conversation wrote its file")
                t.expectEqual(run(.end(session: id, tmux: "lbcheck-two")).flatMap { RemoteEnd.outcome($0.output) }, .ended, "ended")
                t.expectEqual(shell("tmux has-session -t '=lbcheck-two' 2>/dev/null && echo there"), "there",
                              "the tmux session and its other pane are still there")
                _ = shell("tmux kill-session -t '=lbcheck-two'")
            },

            TestCase("Move: of two Moves at once one ends the editor's process, the other is refused by the lock") { t in
                guard let look = run(.look), let reading = V1ProbeReading.parse(look.output, host: node.name, at: Date()),
                      let record = reading.report.sessions.first(where: { $0.sessionId == editor }),
                      let start = record.procStart else { return t.fail("the editor's session was not found by the look") }
                t.expectEqual(record.entrypoint, MoveHere.editorEntrypoint, "it is in VS Code")
                guard let command = try? NodeAction.move(session: editor, pid: Int32(record.pid), procStart: start).command().get()
                else { return t.fail("no command") }
                let outcomes = (try? Blocking.run(60) { () async throws -> [RemoteMove.Outcome?] in
                    async let first = Self.once(node, command)
                    async let second = Self.once(node, command)
                    return [RemoteMove.outcome(try await first), RemoteMove.outcome(try await second)]
                }) ?? []
                t.expectEqual(outcomes.filter { $0 == .ended }.count, 1, "one Move ended it: \(outcomes)")
                t.expectEqual(outcomes.filter { $0 == .locked }.count, 1, "the second Move is refused")
                let launch = NewSession.newLaunchTag()
                let resumed = run(.start(folder: record.cwd, name: "site", launch: launch, start: .resume(sessionId: editor)))
                    .map { NodeAction.started(output: $0.output, exitCode: $0.exitCode) }
                guard case .started(let tmux)? = resumed else { return t.fail("not taken up: \(String(describing: resumed))") }
                _ = run(.moveDone(session: editor))
                t.expectEqual(shell("test -d ~/\(RemoteMove.lockFolder)/\(editor) && echo held || echo free"), "free",
                              "the lock goes once it goes on in tmux")
                _ = shell("tmux kill-session -t '=\(tmux)'")
            },

            TestCase("@name: the message arrives in the conversation's box once") { t in
                let ran = run(.message(session: box, text: "Example message from the check"))
                t.expectEqual(ran.flatMap { NodeAction.notSent($0.output) }, nil, "sent: \(ran?.output ?? "")")
                Thread.sleep(forTimeInterval: 0.5)
                let log = shell("python3 \(node.fixture) box-log").split(separator: "\n")
                t.expectEqual(log.count, 1, "the message arrived once: \(log.count)")
                t.expect(log.first?.contains(PeerBox.preamble.prefix(20)) == true && log.first?.contains("Example message") == true,
                         "with the panel's preamble, as from LampBoard")
                let none = run(.message(session: held, text: "Example"))
                t.expect(none.flatMap { NodeAction.notSent($0.output) } != nil, "a conversation without a box: not sent, and said")
            },

            TestCase("claude attach: never a second one while the first is open") { t in
                guard let command = NodeTerminalCommand.background(job: job).command else { return t.fail("no command") }
                _ = shell("rm -f ~/.lampd-fixture/attach.log")
                let outcome = try? Blocking.run(60) { () async throws -> (Bool, String, Bool) in
                    let action = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
                    defer { Task { await action.close() } }
                    let size = TerminalSize(columns: 80, rows: 24)!
                    let first = try await action.openTerminal(command: command, size: size)
                    let one = Collector(first.inbound)
                    let attached = await one.wait(for: "attached \(job)", within: 15)
                    let second = try await action.openTerminal(command: command, size: size)
                    let two = Collector(second.inbound)
                    _ = await two.ended(within: 15)
                    await first.close()
                    _ = await one.ended(within: 10)
                    let third = try await action.openTerminal(command: command, size: size)
                    let three = Collector(third.inbound)
                    let again = await three.wait(for: "attached \(job)", within: 15)
                    await third.close()
                    return (attached, two.text, again)
                }
                t.expectEqual(outcome?.0, true, "the first attaches")
                t.expect(outcome?.1.contains(BackgroundAttach.refusal) == true, "the second is refused: \(outcome?.1 ?? "")")
                t.expectEqual(outcome?.2, true, "the first closed, the next one attaches")
                let attaches = shell("cat ~/.lampd-fixture/attach.log").split(separator: "\n")
                t.expectEqual(attaches.count, 2, "claude attach ran twice in all, never two at once: \(attaches)")
            },

            TestCase("Browse lists a folder's folders; the project's tree and a file, nothing out of it") { t in
                let listing = run(.browse(path: home + "/work")).flatMap { RemoteFolders.parse($0.output) }
                t.expect(listing?.folders.contains("api") == true && listing?.folders.contains("site") == true,
                         "the folders: \(listing?.folders ?? [])")
                let tree = run(.files(root: api, relative: nil)).map { RemoteProject.entries($0.output) } ?? []
                t.expect(tree.contains { $0.name == "README.md" && !$0.isFolder }, "a file")
                t.expect(tree.contains { $0.name == "src" && $0.isFolder }, "a folder")
                t.expect(run(.read(root: api, relative: "README.md"))?.output.hasPrefix("# Example API") == true, "read")
                _ = shell("ln -sf ~/.ssh/authorized_keys \(api)/keys")
                let out = run(.read(root: api, relative: "keys"))
                t.expect(out?.output.contains("lampboard-device") != true, "a link out of the project is not followed")
                _ = shell("rm -f \(api)/keys")
            },

            TestCase("Attachments go by SFTP into the project's folder, whole, and never over a file there") { t in
                guard let prepared = run(.attachments(root: api)), let listing = RemoteProject.attachmentsListing(prepared.output)
                else { return t.fail("no folder") }
                let name = ProjectAttachments.attachmentName("Screen Shot.png", taken: listing.taken)
                var bytes = [UInt8](repeating: 0, count: 1 << 20)
                for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: (i &* 2_654_435_761) >> 9) }
                let copied = Result { try Blocking.run(60) { () async throws in
                    let action = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
                    defer { Task { await action.close() } }
                    try await action.upload(bytes, toNewFile: listing.folder + "/" + name)
                } }
                t.expect((try? copied.get()) != nil, "copied: \(copied)")
                let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
                t.expectEqual(shell("sha256sum '\(listing.folder)/\(name)' | cut -d' ' -f1"), digest, "the same bytes there")
                let again = Result { try Blocking.run(60) { () async throws in
                    let action = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
                    defer { Task { await action.close() } }
                    try await action.upload([1, 2, 3], toNewFile: listing.folder + "/" + name)
                } }
                if case .failure = again { t.expect(true, "refused") } else {
                    t.expect(false, "a second copy under the same name is refused")
                }
                t.expectEqual(shell("sha256sum '\(listing.folder)/\(name)' | cut -d' ' -f1"), digest, "and the first one is untouched")
                t.expect(shell("cat \(api)/.git/info/exclude").contains(".lampboard/"), "out of git")
                t.expectEqual(ProjectAttachments.citation(of: name), "@.lampboard/allegati/\(name)", "cited as Read takes it")
            },

            TestCase("The projects kept by lampd: attached, listed, detached") { t in
                let attached = run(.projects(.attach(api))).map { ProjectList.decode(Data($0.output.utf8)) } ?? []
                t.expect(attached.contains { $0.path == api }, "attached: \(attached.map(\.path))")
                let listed = run(.projects(.list)).map { ProjectList.decode(Data($0.output.utf8)) } ?? []
                t.expectEqual(listed.map(\.path), [api], "listed")
                let refused = run(.projects(.attach(home + "/nothing-here")))
                t.expect(refused?.exitCode != 0, "a folder that is not there is refused")
                let detached = run(.projects(.detach(api))).map { ProjectList.decode(Data($0.output.utf8)) }
                t.expectEqual(detached?.count, 0, "detached")
            },

            TestCase("The project's shell opens in its folder") { t in
                guard let command = NodeTerminalCommand.shell(root: api).command else { return t.fail("no command") }
                let seen = try? Blocking.run(30) { () async throws -> Bool in
                    let action = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
                    defer { Task { await action.close() } }
                    let terminal = try await action.openTerminal(command: command, size: TerminalSize(columns: 100, rows: 24)!)
                    let screen = Collector(terminal.inbound)
                    try await terminal.write(Array("pwd; echo lb-$((40+2))\n".utf8))
                    let found = await screen.wait(for: "lb-42", within: 10)
                    await terminal.close()
                    return found && screen.text.contains(api)
                }
                t.expectEqual(seen, true, "pwd says the project")
            },

            TestCase("A low-power command through the read key reaches lampd's row") { t in
                let target = "a1000000-0000-4000-8000-000000000005"
                let renamed = try? Blocking.run(30) { () async throws -> Bool in
                    let connection = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.readKey)
                    defer { Task { await connection.close() } }
                    let channel = try await connection.openV1()
                    for message in [V1ClientMessage(id: 1, .hello(protocol: V1Protocol.version, client: "check")),
                                    V1ClientMessage(id: 2, .command(V1Command(action: .rename, session: target, name: "Example name")))] {
                        try await channel.write(V1Frame.encode(try V1Codec.encode(message)))
                    }
                    var reader = V1FrameReader()
                    for await chunk in channel.inbound {
                        reader.push(chunk)
                        while let frame = try reader.next() {
                            if case .result? = try? V1Codec.decodeReply(frame).reply { await channel.close(); return true }
                        }
                    }
                    return false
                }
                t.expectEqual(renamed, true, "lampd took it")
                t.expectEqual(rows().first { $0.id == target }?.session.label, "Example name", "the row is called so")
            },
        ])
    }

    /// One command on a connection of its own: two Moves from two devices.
    static func once(_ node: LampDNode, _ command: String) async throws -> String {
        let action = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
        defer { Task { await action.close() } }
        return try await action.run(command).output
    }
}
