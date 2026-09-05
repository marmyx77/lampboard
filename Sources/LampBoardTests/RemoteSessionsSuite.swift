import LampBoardCore
import Foundation
import TestKit

/// Sessions that run on another machine.
///
/// lampboard was built as a single-machine tool and said so by construction:
/// the hook posts to `127.0.0.1`, the server binds `127.0.0.1`, and a row exists
/// only if a local VS Code lock claims its folder. A session running over ssh on
/// the always-on node therefore never appeared — four independent barriers, all
/// measured.
///
/// The way in is not to open the local port. `POST /signal` carries no token, so
/// exposing it on the tailnet would put unauthenticated state injection on the
/// network. Instead the node is **read**: it already answers over ssh, and it is
/// the only place where the two checks that matter can be made — `kill(pid, 0)`
/// and the transcript's timestamp.
enum RemoteSessionsSuite {

    private static let host = "node"

    /// `true` when the local python3 can parse `script`. Parsing only: nothing runs.
    private static func pythonParses(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import ast, sys; ast.parse(sys.stdin.read())"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func decode(_ json: String) -> [LiveSession] {
        (try? RemoteSessionsDecoder.decode(
            Data(json.utf8), host: host
        )) ?? []
    }

    static let suite = TestSuite("Remote sessions", [

        // The shape the node actually emits, taken from a live probe.
        TestCase("A real payload decodes") { t in
            let sessions = decode("""
            [{"pid":1838232,"sessionId":"9c93b73b-1111-2222-3333-444455556666",
              "cwd":"/home/dev/.notes","entrypoint":"cli","name":"notes",
              "kind":"interactive","activityEpoch":1787223193}]
            """)
            t.expectEqual(sessions.count, 1, "sessions")
            t.expectEqual(sessions.first?.pid, 1838232, "pid")
            t.expectEqual(sessions.first?.cwd, "/home/dev/.notes", "cwd")
            t.expectEqual(sessions.first?.entrypoint, "cli", "entrypoint")
            t.expectEqual(
                sessions.first?.modifiedAt,
                Date(timeIntervalSince1970: 1787223193),
                "activity comes from the node, not from this machine's clock"
            )
        },

        TestCase("Several sessions on the same host all arrive") { t in
            let sessions = decode("""
            [{"pid":1,"sessionId":"aaaaaaaa-1111","cwd":"/home/dev/.notes",
              "entrypoint":"cli","kind":"interactive","activityEpoch":100},
             {"pid":2,"sessionId":"bbbbbbbb-2222","cwd":"/home/dev/Development/x",
              "entrypoint":"cli","kind":"interactive","activityEpoch":200}]
            """)
            t.expectEqual(sessions.count, 2, "sessions")
        },

        // A malformed entry must not take the whole read down with it: the node is
        // a machine we do not control the output of, and one bad record is not a
        // reason to lose the other two.
        TestCase("One broken record does not lose the others") { t in
            let sessions = decode("""
            [{"pid":1,"sessionId":"aaaaaaaa-1111","cwd":"/home/dev/a",
              "entrypoint":"cli","activityEpoch":100},
             {"nonsense":true},
             {"pid":3,"sessionId":"cccccccc-3333","cwd":"/home/dev/c",
              "entrypoint":"cli","activityEpoch":300}]
            """)
            t.expectEqual(sessions.map(\.pid), [1, 3], "the survivors")
        },

        TestCase("A record without a session id is dropped") { t in
            t.expectEqual(
                decode(#"[{"pid":1,"cwd":"/home/dev/a","activityEpoch":1}]"#).count,
                0, "sessions"
            )
        },

        TestCase("A relative cwd is dropped rather than resolved") { t in
            t.expectEqual(
                decode(#"[{"pid":1,"sessionId":"aaaaaaaa-1111","cwd":"marco/a","activityEpoch":1}]"#).count,
                0, "a relative path here would mean guessing whose root it is"
            )
        },

        TestCase("Rubbish in gives nothing out, and does not crash") { t in
            t.expectEqual(decode("not json at all").count, 0, "sessions")
            t.expectEqual(decode("{}").count, 0, "an object is not a list")
            t.expectEqual(decode("[]").count, 0, "empty is fine")
        },

        // MARK: The workspace of a remote session

        // Locally a row exists only if a VS Code window claims the folder. That
        // criterion is meaningless for a session in a tmux pane on a headless
        // node, and applying it there is exactly what kept these rows invisible.
        TestCase("A remote session's workspace is its own folder") { t in
            let w = Workspace(path: "/home/dev/.notes", host: host)
            t.expectEqual(w.name, ".notes", "name")
            t.expectEqual(w.host, host, "host")
            t.expect(w.isRemote, "it must know it is not here")
        },

        TestCase("A local workspace stays local") { t in
            let w = Workspace(path: "/Users/dev/project")
            t.expectNil(w.host, "host")
            t.expect(!w.isRemote, "no host means this machine")
        },

        // Two folders with the same name on two machines are two rows, not one.
        TestCase("The same path on two hosts is two workspaces") { t in
            let here = Workspace(path: "/w/project")
            let there = Workspace(path: "/w/project", host: host)
            t.expect(here != there, "they must not collapse into one row")
        },

        TestCase("And the column draws them as three rows, each with its own everything") { t in
            // The test above was the whole proof, and it proved the wrong thing.
            // `Workspace` did keep `host` in its identity; every caller that
            // needed a key threw it away and used the path. So two machines
            // holding `/w/project` drew **one** row, in whichever state the more
            // urgent member happened to be, and hiding it hid the other machine's
            // too. A value being distinct is worth nothing until something asks
            // it for its name.
            let moment = Date(timeIntervalSince1970: 1_788_000_000)
            func session(_ id: String, on host: String?, _ status: SessionStatus) -> SessionState {
                SessionState(
                    id: id, status: status,
                    workspace: Workspace(path: "/w/project", host: host),
                    updatedAt: moment, statusSince: moment
                )
            }
            let state = TrafficLightState(sessions: [
                "here": session("here", on: nil, .working),
                "one": session("one", on: "node-one", .ready),
                "two": session("two", on: "node-two", .idle),
            ])

            let rows = ColumnLayout.render(state, options: ColumnOptions()).rows
            t.expectEqual(rows.count, 3, "one folder per machine")
            t.expectEqual(Set(rows.map(\.id)).count, 3, "and three keys, not one used three times")

            // Each row must be reachable on its own terms: its state is its own,
            // and so is every preference stored against it.
            let byHost = Dictionary(uniqueKeysWithValues: rows.map { ($0.workspace.host, $0) })
            t.expectEqual(byHost[nil]?.status, .working, "the one here is working")
            t.expectEqual(byHost["node-one"]?.status, .ready, "one machine has an answer")
            t.expectEqual(byHost["node-two"]?.status, .idle, "the other has nothing")

            // Hiding one machine's folder leaves the others where they were.
            guard let hiddenKey = byHost["node-one"]?.workspace.key else {
                t.expect(false, "no key to hide")
                return
            }
            let afterHiding = ColumnLayout.render(
                state, options: ColumnOptions(hidden: [hiddenKey])
            )
            t.expectEqual(afterHiding.rows.count, 2, "one row put aside")
            t.expect(!afterHiding.rows.contains { $0.workspace.host == "node-one" }, "the right one")

            // And a name given to one is not worn by the others.
            let named = ColumnLayout.render(
                state, options: ColumnOptions(names: [hiddenKey: "Bestia"])
            )
            t.expectEqual(
                named.rows.filter { $0.displayName == "Bestia" }.count, 1,
                "the name belongs to one machine's folder"
            )
        },

        TestCase("A slot, a mute and a move each land on one machine only") { t in
            // The other half of the same proof. The row is drawn per machine and
            // named per machine; what was not covered is everything a person
            // *reaches* it with, and the slot is the sharp one — the click reads
            // `workspace.host` directly and cannot be confused by a key, but the
            // number keys address a row by exactly this string. Press 3 and the
            // wrong machine's project opens is the failure shape.
            let moment = Date(timeIntervalSince1970: 1_788_000_000)
            func session(_ id: String, on host: String?) -> SessionState {
                SessionState(
                    id: id, status: .ready,
                    workspace: Workspace(path: "/w/project", host: host),
                    updatedAt: moment, statusSince: moment
                )
            }
            let state = TrafficLightState(sessions: [
                "here": session("here", on: nil),
                "one": session("one", on: "node-one"),
                "two": session("two", on: "node-two"),
            ])
            let keys = [
                Workspace(path: "/w/project").key,
                Workspace(path: "/w/project", host: "node-one").key,
                Workspace(path: "/w/project", host: "node-two").key,
            ]
            t.expectEqual(Set(keys).count, 3, "three keys, or nothing below means anything")

            // Slots: three places, not one shared by three.
            let slots = keys.map { RowOrder.slot(of: $0, in: keys, limit: AppConfig.maxSlots) }
            t.expectEqual(slots, [1, 2, 3], "each machine's folder holds a number of its own")

            let rendered = ColumnLayout.render(state, options: ColumnOptions(order: keys)).rows
            t.expectEqual(rendered.compactMap(\.slot), [1, 2, 3], "and the column agrees")
            t.expectEqual(
                rendered.map(\.workspace.host), [nil, "node-one", "node-two"],
                "in the order the person put them in"
            )

            // Moving one moves one. The others keep the places they had.
            let moved = RowOrder.moving(keys[2], by: -2, among: keys, in: keys)
            t.expectEqual(moved, [keys[2], keys[0], keys[1]], "the second node goes to the top")
            t.expectEqual(
                RowOrder.slot(of: keys[0], in: moved, limit: AppConfig.maxSlots), 2,
                "and the local folder moved down by exactly one"
            )

            // Muting is a set of the same keys, so one machine goes quiet alone.
            let muted: Set<String> = [keys[1]]
            t.expect(!muted.contains(keys[0]), "the local folder still alerts")
            t.expect(muted.contains(keys[1]), "the one that was muted does not")
            t.expect(!muted.contains(keys[2]), "and neither does the other node inherit it")
        },

        TestCase("The name is the folder, wherever the folder is") { t in
            // There is one name and the machine is not in it. The second one that
            // used to exist — `.notes @node` — was what the column drew, and on a
            // host with a long name it ate the row: the mark and the tooltip carry
            // where it is now, and neither of them is a name.
            let w = Workspace(path: "/home/dev/.notes", host: host)
            t.expectEqual(w.name, ".notes", "the name stays the folder")
            t.expect(!w.name.contains(host), "and never carries the machine")
            t.expectEqual(w.key, "node:/home/dev/.notes", "which the key still does")
        },

        TestCase("A row on another machine reads like any other, and says where in its card") { t in
            // Reported from use, on a node called `minisforum`: the rows of that
            // machine all read `AWeve…isforum`, because the host was appended to
            // every one of them and the middle of the name was what got truncated.
            // The fix is not a wider panel — it is that the machine was never a
            // name, and belongs in the layer with room for a sentence.
            let moment = Date(timeIntervalSince1970: 1_788_000_000)
            let remote = ColumnRow(
                id: "minisforum:/srv/aworld-events",
                workspace: Workspace(path: "/srv/aworld-events", host: "minisforum"),
                sessions: [SessionState(
                    id: "s1", status: .working,
                    workspace: Workspace(path: "/srv/aworld-events", host: "minisforum"),
                    updatedAt: moment, statusSince: moment
                )]
            )

            t.expectEqual(remote.displayName, "aworld-events", "the folder, and nothing appended")
            t.expect(!remote.displayName.contains("minisforum"), "the host is not in the name")
            t.expect(remote.workspace.isRemote, "which is what the row's mark reads")
            t.expectEqual(
                RowSummary.of(remote, now: moment).subtitle, "on minisforum",
                "and the card is where the machine is spelled out"
            )
        },

        // MARK: Which hosts to ask

        TestCase("Absent or empty means the feature is off") { t in
            t.expectEqual(RemoteHostList.parse("").count, 0, "empty")
            t.expectEqual(RemoteHostList.parse("\n\n  \n").count, 0, "blank lines only")
            t.expectEqual(RemoteHostList.parse("# just a comment\n").count, 0, "comments only")
        },

        TestCase("One name per line, comments and duplicates removed") { t in
            t.expectEqual(
                RemoteHostList.parse("""
                # the always-on box
                node   # via the VPN
                mac-mini
                node
                """),
                ["node", "mac-mini"],
                "hosts"
            )
        },

        // The name becomes an argument to ssh. It never reaches a shell, but a
        // name starting with a dash would be read by ssh as *options*, and one
        // with a space would split into two arguments.
        TestCase("A name ssh would misread is refused") { t in
            t.expect(RemoteHostList.isUsable("node"), "plain")
            t.expect(RemoteHostList.isUsable("dev@192.0.2.10"), "user@host")
            t.expect(!RemoteHostList.isUsable("-oProxyCommand=curl evil"), "leading dash")
            t.expect(!RemoteHostList.isUsable("host with space"), "space")
            t.expect(!RemoteHostList.isUsable("host;rm -rf /"), "separator")
            t.expect(!RemoteHostList.isUsable(""), "empty")
        },

        TestCase("A refused name does not take the good ones with it") { t in
            t.expectEqual(
                RemoteHostList.parse("node\n-oProxyCommand=x\nmac-mini"),
                ["node", "mac-mini"],
                "hosts"
            )
        },

        // MARK: The script that runs there

        // It is a promise made to another machine: the shape it prints is what the
        // decoder above parses, and the two must not drift apart.
        TestCase("The probe emits the fields the decoder reads") { t in
            for field in ["sessionId", "cwd", "entrypoint", "name", "kind", "activityEpoch", "pid"] {
                t.expect(
                    RemoteProbeScript.script.contains("\"\(field)\""),
                    "the probe must emit \(field)"
                )
            }
        },

        // The same encoding rule as TranscriptLocator, expressed once more because
        // it has to run on the other machine. If these two ever disagree, activity
        // silently falls back to the session file — which is the frozen one.
        TestCase("The probe reads activity from the transcript, not the session file") { t in
            t.expect(RemoteProbeScript.script.contains("*.jsonl"), "it must stat transcripts")
            t.expect(
                RemoteProbeScript.script.contains("[^a-zA-Z0-9]"),
                "and encode the folder the way TranscriptLocator does"
            )
        },

        // MARK: What deserves a row

        // Found by building the remote path, and it was never about remote. An SDK
        // session that declares itself `interactive` slipped through, because the
        // check returned on `kind` and never reached the entrypoint. Locally it
        // stayed invisible for the wrong reason — no editor window claimed its
        // folder — so removing that accidental filter is what exposed it.
        //
        // Real shape, from the node: claude-mem's observer.
        TestCase("An SDK session calling itself interactive is still not a row") { t in
            let observer = LiveSession(
                pid: 1, sessionId: "aaaaaaaa-1111",
                cwd: "/home/dev/.claude-mem/observer-sessions",
                entrypoint: "sdk-cli", name: "observer-sessions-c7",
                kind: "interactive", modifiedAt: Date(), host: host
            )
            t.expect(!observer.deservesTrafficLight, "an SDK session has nobody in front of it")
        },

        TestCase("A real interactive session still gets its row") { t in
            let interactive = LiveSession(
                pid: 2, sessionId: "bbbbbbbb-2222", cwd: "/home/dev/.notes",
                entrypoint: "cli", name: "notes-32", kind: "interactive",
                modifiedAt: Date(), host: host
            )
            t.expect(interactive.deservesTrafficLight, "cli + interactive is exactly the case")
        },

        TestCase("A non-interactive kind is refused whatever started it") { t in
            let batch = LiveSession(
                pid: 3, sessionId: "cccccccc-3333", cwd: "/home/dev/x",
                entrypoint: "cli", name: nil, kind: "batch",
                modifiedAt: Date(), host: host
            )
            t.expect(!batch.deservesTrafficLight, "kind still decides when it disagrees")
        },

        TestCase("The probe checks liveness where the processes are") { t in
            t.expect(RemoteProbeScript.script.contains("os.kill(pid, 0)"), "kill(pid, 0)")
            t.expect(
                RemoteProbeScript.script.contains("PermissionError"),
                "a process owned by somebody else is still alive"
            )
        },

        // A pid outlives its process: after a reboot the same number names
        // something else, and kill(pid, 0) would keep a dead session's row alive.
        // A script that does not parse is a promise nobody can keep, and no
        // `contains` check sees it: two literals joined without a newline once
        // produced `return Nonedef bound_addresses` and a tunnel that retried
        // forever. python3 is on every Mac; let it read what the node will read.
        TestCase("Every script sent to another machine is valid Python") { t in
            for (name, script) in [
                ("probe", RemoteProbeScript.script),
                ("inspect", RemoteInstallScripts.inspect),
                ("apply", RemoteInstallScripts.apply(payloadBase64: "e30=")),
                ("prepareTunnel", RemoteInstallScripts.prepareTunnel),
                ("checkTunnel", RemoteInstallScripts.checkTunnel(port: 31000)),
            ] {
                t.expect(pythonParses(script), "\(name) does not parse")
            }
        },

        // What runs on the node to install the hooks, and the promises it keeps.
        TestCase("The install scripts check the directory, compare before writing, and keep the mode") { t in
            let apply = RemoteInstallScripts.apply(payloadBase64: "e30=")
            t.expect(apply.contains("expectedSha256"), "compare-and-swap on the settings")
            t.expect(apply.contains("shutil.copy2"), "the backup keeps the file's mode")
            t.expect(apply.contains("os.chmod(tmp, mode)") && apply.contains("os.replace(tmp, settings_path)"), "atomic write, same mode")
            t.expect(apply.contains("S_ISLNK") && apply.contains("st_uid != os.getuid()"), "a symlinked or foreign ~/.lampboard is refused")
            t.expect(RemoteInstallScripts.inspect.contains("settingsSha256"), "the inspection hands back what to compare")
            // The bind is a request; whether it was honoured is read where it is a fact.
            t.expect(RemoteInstallScripts.prepareTunnel.contains("/proc/net/tcp"), "a taken port is seen before the tunnel asks for it")
            t.expect(RemoteInstallScripts.checkTunnel(port: 31000).contains("bound_addresses(31000)"), "the tunnel check reports where the port is bound")
        },

        TestCase("The probe refuses a pid that has been reused") { t in
            t.expect(RemoteProbeScript.script.contains("/proc/%d/stat"), "reads the start time where it is")
            t.expect(
                RemoteProbeScript.script.contains("record.get(\"procStart\")"),
                "compares it with what the session file remembers"
            )
        },
    ])
}
