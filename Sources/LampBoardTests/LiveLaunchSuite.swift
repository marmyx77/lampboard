import LampBoardCore
import Foundation
import TestKit

/// The live view (D130): a session's real Claude Code interface in a window of
/// LampBoard's own. What it runs is decided here, where a test can read it: the
/// command, the environment it runs in, the id a new background session prints,
/// and which leftover processes a new launch may end.
enum LiveLaunchSuite {

    static let claude = "/home/dev/.local/bin/claude"
    static let base: [String: String] = [
        "HOME": "/home/dev", "USER": "dev", "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin",
        "LANG": "it_IT.UTF-8", "SSH_AUTH_SOCK": "/tmp/agent.sock", "TMPDIR": "/tmp/dev",
        "TMUX": "/tmp/tmux-501/default,1,0", "TMUX_PANE": "%3", "TERM_PROGRAM": "vscode",
        "CLAUDECODE": "1", "CLAUDE_CODE_SSE_PORT": "41000", "LAMPBOARD_HOME": "/tmp/fake",
        "SECRET_TOKEN": "abc",
    ]

    static let suite = TestSuite("Live view: what it runs", [

        TestCase("Opening a background session attaches to it, nothing else") { t in
            let command = LiveLaunch.attach(job: "80129edd", claude: claude, environment: base, home: "/home/dev")
            t.expectEqual(command?.executable, claude)
            t.expectEqual(command?.arguments, ["attach", "80129edd"])
            t.expectNil(command?.directory, "an attach needs no folder: the session has its own")
        },

        TestCase("An id that is not a job's is refused before anything runs") { t in
            for id in ["--help", "-x", "", "a b", "abc;rm", String(repeating: "a", count: 65), "../x"] {
                t.expectNil(LiveLaunch.attach(job: id, claude: claude, environment: base, home: "/home/dev"), "refused: \(id)")
            }
        },

        TestCase("A new session starts in the background, in its folder, with its name when it has one") { t in
            let command = LiveLaunch.start(directory: "/home/dev/web", name: "web", claude: claude, environment: base, home: "/home/dev")
            t.expectEqual(command?.arguments, ["--bg", "--name", "web"])
            t.expectEqual(command?.directory, "/home/dev/web")
            let unnamed = LiveLaunch.start(directory: "/home/dev/web", name: nil, claude: claude, environment: base, home: "/home/dev")
            t.expectEqual(unnamed?.arguments, ["--bg"])
        },

        TestCase("A name that would read as an option is left out; a folder must be absolute") { t in
            let dashed = LiveLaunch.start(directory: "/home/dev/web", name: "--dangerously-skip-permissions", claude: claude,
                                          environment: base, home: "/home/dev")
            t.expectEqual(dashed?.arguments, ["--bg"], "never an option smuggled in as a name")
            t.expectNil(LiveLaunch.start(directory: "web", name: nil, claude: claude, environment: base, home: "/home/dev"))
            t.expectNil(LiveLaunch.start(directory: "", name: nil, claude: claude, environment: base, home: "/home/dev"))
        },

        TestCase("The environment: a terminal that says what it can do, and nothing borrowed from where LampBoard started") { t in
            let env = LiveLaunch.environment(base: base, home: "/home/dev")
            t.expectEqual(env["TERM"], "xterm-256color")
            t.expectEqual(env["COLORTERM"], "truecolor")
            t.expectEqual(env["LANG"], "it_IT.UTF-8", "the person's language is kept")
            t.expectEqual(env["HOME"], "/home/dev")
            t.expectEqual(env["SSH_AUTH_SOCK"], "/tmp/agent.sock", "so a session can still reach git over ssh")
            for leaked in ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "CLAUDECODE", "CLAUDE_CODE_SSE_PORT", "LAMPBOARD_HOME", "SECRET_TOKEN"] {
                t.expectNil(env[leaked], "\(leaked) does not reach the session")
            }
        },

        TestCase("What a proxy, a company CA or another config folder needs gets through; API keys do not") { t in
            var corporate = base
            corporate["CLAUDE_CONFIG_DIR"] = "/home/dev/.claude-work"
            corporate["HTTPS_PROXY"] = "http://proxy:3128"
            corporate["NO_PROXY"] = "localhost"
            corporate["NODE_EXTRA_CA_CERTS"] = "/etc/ca.pem"
            corporate["CLAUDE_CODE_USE_BEDROCK"] = "1"
            corporate["ANTHROPIC_API_KEY"] = "sk-ant-secret"
            let env = LiveLaunch.environment(base: corporate, home: "/home/dev")
            for kept in ["CLAUDE_CONFIG_DIR", "HTTPS_PROXY", "NO_PROXY", "NODE_EXTRA_CA_CERTS", "CLAUDE_CODE_USE_BEDROCK"] {
                t.expectEqual(env[kept], corporate[kept], "\(kept) reaches the session")
            }
            t.expectNil(env["ANTHROPIC_API_KEY"], "a key in LampBoard's environment is not handed on")
        },

        TestCase("PATH also holds the folder claude itself is in, so a script claude finds its node") { t in
            let env = LiveLaunch.environment(base: base, home: "/home/dev", claude: "/opt/nvm/versions/node/v22/bin/claude")
            let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
            t.expectEqual(path.first, "/opt/nvm/versions/node/v22/bin")
        },

        TestCase("PATH finds claude where people install it, before the system folders, each once") { t in
            let env = LiveLaunch.environment(base: base, home: "/home/dev")
            let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
            t.expectEqual(path.first, "/home/dev/.local/bin")
            t.expect(path.contains("/opt/homebrew/bin"), "Homebrew")
            t.expectEqual(Set(path).count, path.count, "no folder twice")
            t.expect(path.contains("/usr/bin"), "the system's still there")
        },

        TestCase("No language at all becomes UTF-8, so the interface's glyphs survive") { t in
            var bare = base
            bare["LANG"] = nil
            t.expectEqual(LiveLaunch.environment(base: bare, home: "/home/dev")["LANG"], "en_US.UTF-8")
            bare["LC_ALL"] = "de_DE.UTF-8"
            let env = LiveLaunch.environment(base: bare, home: "/home/dev")
            t.expectNil(env["LANG"], "LC_ALL already says it")
            t.expectEqual(env["LC_ALL"], "de_DE.UTF-8")
        },

        TestCase("The id a new background session prints is read back, in either of its two lines") { t in
            let printed = """
            Starting background service…
            backgrounded · 80129edd · scenario-uno
              claude agents             list sessions
              claude attach 80129edd    open in this terminal
            """
            t.expectEqual(LiveLaunch.jobId(fromBackgroundOutput: printed), "80129edd")
            t.expectEqual(LiveLaunch.jobId(fromBackgroundOutput: "backgrounded · 3b89ab82 · x"), "3b89ab82")
            t.expectNil(LiveLaunch.jobId(fromBackgroundOutput: "Workspace not trusted. Run `claude` in /x once"))
            t.expectNil(LiveLaunch.jobId(fromBackgroundOutput: "claude attach --help"), "never an option")
        },

        TestCase("A window's header names its session by its row, or by its id until a row exists") { t in
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            let job = BackgroundJob(id: "80129edd", sessionId: "s1", summary: nil, needs: nil)
            let session = SessionState(id: "s1", status: .awaiting, workspace: Workspace(path: "/home/dev/web"),
                                       updatedAt: t0, statusSince: t0, origin: .background, title: "Fix the slots test",
                                       backgroundJob: job)
            let state = TrafficLightState(sessions: ["s1": session])
            let heading = LiveHeading.of(job: "80129edd", in: state)
            t.expectEqual(heading.title, "Fix the slots test")
            t.expectEqual(heading.detail, "web · \(SessionStatus.awaiting.label)")
            t.expectEqual(heading.status, .awaiting)
            t.expectEqual(LiveHeading.of(job: "ffff0000", in: state).title, "ffff0000", "a job no row knows yet")
            t.expectNil(LiveHeading.of(job: "ffff0000", in: state).status)
        },

        TestCase("Why a start failed is said in the person's terms") { t in
            t.expectEqual(LiveLaunch.startFailure(fromOutput: "Workspace not trusted. Run `claude` in /home/dev/web once and accept"),
                          .untrusted)
            t.expectEqual(LiveLaunch.startFailure(fromOutput: "Not logged in · Please run /login"), .notLoggedIn)
            t.expectEqual(LiveLaunch.startFailure(fromOutput: "something else"), .other("something else"))
            t.expect(LiveLaunch.StartFailure.untrusted.message.contains("trust"), "says what to do")
        },
    ])
}

/// What a launch may end of what an earlier one left behind (D130): a process
/// LampBoard started, still running, and still the same process. A pid is reused
/// by the system, so the start time is what tells them apart.
enum LiveLedgerSuite {

    static let suite = TestSuite("Live view: the processes it leaves", [

        TestCase("Each LampBoard keeps its own ledger, named after itself; another one's is left alone while it runs") { t in
            let name = LiveLedger.fileName(owner: 4242, startedAt: 1_800_000_000.25)
            let owner = LiveLedger.owner(fromFileName: name)
            t.expectEqual(owner?.pid, 4242)
            t.expectEqual(owner?.startedAt ?? 0, 1_800_000_000.25, "its start time, to the hundredth")
            t.expectNil(LiveLedger.owner(fromFileName: "notes.txt"))
            let alive: [Int32: Double] = [4242: 1_800_000_000.3]
            t.expect(!LiveLedger.isOrphaned(owner: owner!) { alive[$0] }, "its LampBoard runs: not ours to end")
            t.expect(LiveLedger.isOrphaned(owner: owner!) { _ in nil }, "its LampBoard is gone")
            t.expect(LiveLedger.isOrphaned(owner: owner!) { _ in 5 }, "its pid belongs to another process now")
        },

        TestCase("A pid that would signal a whole group of strangers is never an entry") { t in
            let data = LiveLedger.encode([LiveLedger.Entry(pid: 0, startedAt: 1, job: "a1"), LiveLedger.Entry(pid: 1, startedAt: 1, job: "a2"),
                                          LiveLedger.Entry(pid: -5, startedAt: 1, job: "a3"), LiveLedger.Entry(pid: 77, startedAt: 1, job: "a4")])
            t.expectEqual(LiveLedger.decode(data).map(\.pid), [77])
        },

        TestCase("Only a process that is still the one we started is ended") { t in
            let entries = [
                LiveLedger.Entry(pid: 101, startedAt: 1000, job: "aaaa1111"),
                LiveLedger.Entry(pid: 102, startedAt: 2000, job: "bbbb2222"),
                LiveLedger.Entry(pid: 103, startedAt: 3000, job: "cccc3333"),
            ]
            let running: [Int32: Double] = [101: 1000.4, 102: 2500]   // 102 is another process now; 103 is gone
            let reap = LiveLedger.toEnd(entries) { running[$0] }
            t.expectEqual(reap.map(\.pid), [101])
        },

        TestCase("The ledger survives a round trip, and a damaged one is an empty one") { t in
            let entries = [LiveLedger.Entry(pid: 7, startedAt: 12.5, job: "dddd4444")]
            t.expectEqual(LiveLedger.decode(LiveLedger.encode(entries)), entries)
            t.expectEqual(LiveLedger.decode(Data("not json".utf8)), [])
        },
    ])
}

/// How the live view looks (D130): the frame takes the theme, never the 16
/// colours, which stay Claude Code's for its syntax and diffs.
enum LiveThemeSuite {

    static let suite = TestSuite("Live view: themes", [

        TestCase("Every preset has a name, a backdrop, a card and readable text") { t in
            t.expect(LiveTheme.presets.count >= 3, "a few to choose from")
            t.expectEqual(Set(LiveTheme.presets.map(\.id)).count, LiveTheme.presets.count, "one id each")
            for theme in LiveTheme.presets {
                t.expect(!theme.name.isEmpty, "\(theme.id) has a name")
                for hex in [theme.backdropTop, theme.backdropBottom, theme.card, theme.text] {
                    t.expect(LiveTheme.rgb(hex) != nil, "\(theme.id): \(hex) is a colour")
                }
                t.expect(LiveTheme.contrast(theme.text, theme.card) >= 7, "\(theme.id): text on the card reads (AAA)")
            }
        },

        TestCase("An unknown or missing id falls back to the default") { t in
            t.expectEqual(LiveTheme.named("nonexistent").id, LiveTheme.defaultId)
            t.expectEqual(LiveTheme.named(nil).id, LiveTheme.defaultId)
            t.expectEqual(LiveTheme.named("paper").id, "paper")
        },

        TestCase("Font sizes are kept within what a window can show") { t in
            t.expectEqual(LiveTheme.clampedFontSize(4), LiveTheme.fontSizes.lowerBound)
            t.expectEqual(LiveTheme.clampedFontSize(99), LiveTheme.fontSizes.upperBound)
            t.expectEqual(LiveTheme.clampedFontSize(14), 14)
        },
    ])
}

/// What can be opened in the live view, and how (D132): a background session of
/// this Mac by attaching to it, a session in tmux on another machine by attaching
/// to its tmux session over ssh. tmux keeps one process however many clients
/// look at it, so neither is a second writer; an editor's session is neither.
enum LiveTargetSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func session(origin: SessionOrigin = .editor, host: String? = nil, job: String? = nil) -> SessionState {
        SessionState(id: "4b138f7d-67ab-4d4c-9396-77adaed0f851", status: .ready,
                     workspace: Workspace(path: "/home/dev/web", host: host), updatedAt: t0, statusSince: t0, origin: origin,
                     backgroundJob: job.map { BackgroundJob(id: $0, sessionId: "4b138f7d-67ab-4d4c-9396-77adaed0f851", summary: nil, needs: nil) })
    }

    static let place = TmuxPlace(session: "awevents", window: 1, pane: 0)!

    static let suite = TestSuite("Live view: what can be opened", [

        TestCase("A background session of this Mac opens by attaching to its job") { t in
            let target = LiveTarget.of(session(origin: .background, job: "80129edd"), place: nil)
            t.expectEqual(target, .job("80129edd"))
            t.expectEqual(target?.command, "claude attach 80129edd")
        },

        TestCase("A session in tmux on another machine opens by attaching to its tmux session over ssh") { t in
            let target = LiveTarget.of(session(host: "bestia"), place: place)
            t.expectEqual(target, .tmux(host: "bestia", place: place, sessionId: "4b138f7d-67ab-4d4c-9396-77adaed0f851"))
            t.expectEqual(target?.command, "ssh -t bestia \"tmux attach -t '=awevents:1.0'\"")
        },

        TestCase("An editor's session, or a remote one outside tmux, is not opened here: the jump stays") { t in
            t.expectNil(LiveTarget.of(session(), place: nil), "VS Code on this Mac")
            t.expectNil(LiveTarget.of(session(host: "bestia"), place: nil), "remote, not in tmux")
            t.expectNil(LiveTarget.of(session(origin: .background, host: "bestia", job: "80129edd"), place: nil),
                        "a background job over there: its supervisor is not this Mac's")
            t.expectNil(LiveTarget.of(session(origin: .background, job: nil), place: nil), "no job read yet")
        },

        TestCase("The ssh that attaches: hardened, a terminal asked for, tmux's exact-name target") { t in
            let command = LiveLaunch.command(for: .tmux(host: "bestia", place: place, sessionId: "s"), claude: "/x/claude",
                                             environment: LiveLaunchSuite.base, home: "/home/dev")
            t.expectEqual(command?.executable, "/usr/bin/ssh")
            let arguments = command?.arguments ?? []
            t.expect(arguments.contains("-t"), "a terminal over there")
            t.expect(arguments.contains("ForwardAgent=no") && arguments.contains("BatchMode=yes"), "the same hardening as every ssh")
            t.expect(arguments.contains("ConnectTimeout=10"), "a dead machine says so instead of freezing the window")
            t.expectEqual(Array(arguments.suffix(3)), ["--", "bestia",
                          NewSession.posix("PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux attach-session -t '=awevents:1.0'")],
                          "under sh, whatever the login shell over there")
            t.expect(arguments.last?.hasPrefix("sh -c 'PATH=") == true, arguments.last ?? "")
        },

        TestCase("What crosses a shell carries the target quoted: zsh expands a word that begins with =") { t in
            t.expectEqual(place.quotedTarget, "'=awevents:1.0'")
            t.expect(LiveLaunch.remoteAttach(place).hasSuffix("-t '=awevents:1.0'"), "remote")
            t.expectEqual(LiveTarget.tmux(host: nil, place: place, sessionId: "s").command, "tmux attach -t '=awevents:1.0'")
        },

        TestCase("Only a terminal's session is placed in a pane: an editor started from tmux keeps its jump") { t in
            t.expect(TmuxPlace.isPlaceable(entrypoint: "cli", isBackground: false), "a terminal")
            t.expect(TmuxPlace.isPlaceable(entrypoint: nil, isBackground: false), "an older file without one")
            t.expect(!TmuxPlace.isPlaceable(entrypoint: "claude-vscode", isBackground: false), "VS Code")
            t.expect(!TmuxPlace.isPlaceable(entrypoint: "sdk-cli", isBackground: false), "the SDK")
            t.expect(!TmuxPlace.isPlaceable(entrypoint: "cli", isBackground: true), "a background job attaches as one")
        },

        TestCase("Two panes of one tmux session, or two machines with one name, are two windows") { t in
            let a = LiveTarget.tmux(host: "bestia", place: place, sessionId: "s1")
            let b = LiveTarget.tmux(host: "bestia", place: TmuxPlace(session: "awevents", window: 2, pane: 0)!, sessionId: "s2")
            let c = LiveTarget.tmux(host: "other", place: place, sessionId: "s3")
            let here = LiveTarget.tmux(host: nil, place: place, sessionId: "s4")
            let local = LiveTarget.tmux(host: "local", place: place, sessionId: "s5")
            t.expectEqual(Set([a.key, b.key, c.key, here.key, local.key]).count, 5)
        },

        TestCase("This Mac's panes are read from tmux, and a session is placed by its ancestry") { t in
            let panes = TmuxPlace.panes("411\tawevents\t1\t0\n512\tbad name\t0\t0\nnot a line\n613\tdocs\t0\t2\n")
            t.expectEqual(panes.count, 2, "the line with a space in the name is skipped")
            t.expectEqual(TmuxPlace.place(ofAncestry: [900, 850, 613, 1], in: panes), TmuxPlace(session: "docs", window: 0, pane: 2))
            t.expectNil(TmuxPlace.place(ofAncestry: [900, 850, 1], in: panes), "not under any pane")
        },

        TestCase("A tmux place is only what tmux would read as one name") { t in
            t.expectNotNil(TmuxPlace(session: "ai-act-lab", window: 0, pane: 2))
            for bad in ["", "a b", "x;rm", "a:b", "a.b", "-n", String(repeating: "a", count: 65)] {
                t.expectNil(TmuxPlace(session: bad, window: 0, pane: 0), "refused: \(bad)")
            }
            t.expectNil(TmuxPlace(session: "ok", window: -1, pane: 0))
        },

        TestCase("A host that would read as an option is no target") { t in
            t.expectNil(LiveTarget.of(session(host: "-oProxyCommand=x"), place: place))
        },

        TestCase("A session in tmux on this Mac opens with this Mac's tmux, for anyone who keeps Claude there") { t in
            let target = LiveTarget.of(session(origin: .terminal), place: place)
            t.expectEqual(target, .tmux(host: nil, place: place, sessionId: "4b138f7d-67ab-4d4c-9396-77adaed0f851"))
            t.expectEqual(target?.command, "tmux attach -t '=awevents:1.0'")
            let command = LiveLaunch.command(for: target!, claude: "/x/claude", environment: LiveLaunchSuite.base,
                                             home: "/home/dev", tmux: "/opt/homebrew/bin/tmux")
            t.expectEqual(command?.executable, "/opt/homebrew/bin/tmux")
            t.expectEqual(command?.arguments, ["attach-session", "-t", "=awevents:1.0"])
            t.expectNil(command?.environment["TMUX"], "attached, not nested")
            t.expectNil(LiveLaunch.command(for: target!, claude: "/x/claude", environment: [:], home: "/home/dev", tmux: nil),
                        "no tmux found here, nothing offered")
        },

        TestCase("The remote probe's tmux field is read; a damaged one is none") { t in
            let json = #"{"sessions":[{"pid":12,"sessionId":"s1","cwd":"/home/dev/web","kind":"interactive","activityEpoch":1,"tmux":{"session":"awevents","window":1,"pane":0}},{"pid":13,"sessionId":"s2","cwd":"/home/dev/api","tmux":{"session":"a b","window":0,"pane":0}}]}"#
            let report = try? RemoteSessionsDecoder.report(from: Data(json.utf8), host: "bestia", at: t0)
            t.expectEqual(report?.sessions.first?.tmux, place)
            t.expectNil(report?.sessions.last?.tmux, "a name tmux could not take back")
        },

        TestCase("A tmux session LampBoard started is known by its tag: one window, whatever its name over there") { t in
            let panes = TmuxPlace.panes("411\tweb-2\t1\t0\t0123456789abcdef\n412\tweb\t0\t0\t\n413\tx\t0\t0\tNOT;HEX\n")
            t.expectEqual(panes[411]?.launch, "0123456789abcdef")
            t.expectNil(panes[412]?.launch, "the person's own session has no tag")
            t.expectNotNil(panes[413], "a tag that is not one is dropped, the place kept")
            t.expectNil(panes[413]?.launch)
            let started = LiveTarget.starting(host: "box", folder: "/home/dev/web", name: "web", launch: "0123456789abcdef")
            let placed = LiveTarget.tmux(host: "box", place: panes[411]!, sessionId: "s")
            t.expectEqual(started?.key, placed.key, "the row's Open here brings forward the window that started it")
            t.expect(TmuxPlace.paneFormat.hasSuffix("\t#{@lampboard}"), "the tag is asked for")
            let json = #"{"sessions":[{"pid":12,"sessionId":"s1","cwd":"/home/dev/web","activityEpoch":1,"tmux":{"session":"web-2","window":1,"pane":0,"launch":"0123456789abcdef"}}]}"#
            let report = try? RemoteSessionsDecoder.report(from: Data(json.utf8), host: "box", at: t0)
            t.expectEqual(report?.sessions.first?.tmux?.launch, "0123456789abcdef")
        },
    ])
}

/// Starting a session from LampBoard (D133): on this Mac in the background, on
/// another machine inside tmux, where it outlives the window and the ssh.
enum NewSessionSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func session(_ id: String, _ path: String, host: String? = nil, minutes: Double) -> SessionState {
        SessionState(id: id, status: .idle, workspace: Workspace(path: path, host: host),
                     updatedAt: t0.addingTimeInterval(minutes * 60), statusSince: t0)
    }

    static let suite = TestSuite("New session", [

        TestCase("The places offered: each machine's folders, the most recent first, each once") { t in
            let state = TrafficLightState(sessions: [
                "a": session("a", "/Users/dev/web", minutes: 1),
                "b": session("b", "/Users/dev/api", minutes: 5),
                "c": session("c", "/Users/dev/web", minutes: 9),
                "d": session("d", "/home/dev/awevents", host: "box", minutes: 3),
            ])
            let here = NewSession.recentFolders(in: state, host: nil)
            t.expectEqual(here, ["/Users/dev/web", "/Users/dev/api"])
            t.expectEqual(NewSession.recentFolders(in: state, host: "box"), ["/home/dev/awevents"])
        },

        TestCase("A tmux name from a folder: what tmux reads as one name, and not one already there") { t in
            t.expectEqual(NewSession.tmuxName(for: "/home/dev/ai-act lab", taken: []), "ai-act-lab")
            t.expectEqual(NewSession.tmuxName(for: "/home/dev/web", taken: ["web", "web-2"]), "web-3")
            t.expectEqual(NewSession.tmuxName(for: "/home/dev/.hidden", taken: []), "hidden")
            t.expectEqual(NewSession.tmuxName(for: "/", taken: []), "claude")
            t.expectEqual(NewSession.tmuxName(for: "/x/" + String(repeating: "a", count: 90), taken: []).count, 40)
        },

        TestCase("A word for a remote shell is single-quoted, a quote inside it closed and reopened") { t in
            t.expectEqual(NewSession.shellQuoted("/home/dev/web"), "'/home/dev/web'")
            t.expectEqual(NewSession.shellQuoted("/home/dev/it's here"), #"'/home/dev/it'\''s here'"#)
        },

        TestCase("On another machine a session is born in tmux, in its folder, and keeps a shell when Claude ends") { t in
            let script = NewSession.remoteCommand(folder: "/home/dev/my web", name: "my-web", launch: "0123456789abcdef")
            t.expect(script.contains("tmux new-session -d -s \"$n\" -c '/home/dev/my web' "), script)
            t.expect(script.contains("n='my-web'; i=2; while tmux has-session -t \"=$n\""), "a name already there is never joined")
            t.expect(script.contains(NewSession.shellQuoted(#""$SHELL" -ilc 'claude; exec "$SHELL" -l'"#)),
                     "the person's shell, interactive so its startup files find claude, then stays: \(script)")
            t.expect(script.contains("test -d '/home/dev/my web' ||"), "a folder that is not there is said, not replaced by home")
            t.expect(script.hasPrefix("export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"\n"), "Homebrew's tmux found")
            t.expect(script.hasSuffix("exec tmux attach-session -t \"=$n:\""), script)
        },

        TestCase("A reattach finds the session it started by its tag, and never starts a second one") { t in
            let script = NewSession.remoteCommand(folder: "/home/dev/web", name: "web", launch: "0123456789abcdef")
            let lines = script.split(separator: "\n").map(String.init)
            t.expect(lines.contains("l=0123456789abcdef"), script)
            let look = lines.firstIndex { $0.contains("#{@lampboard} #{session_name}") } ?? -1
            let create = lines.firstIndex { $0.contains("tmux new-session") } ?? -1
            t.expect(look >= 0 && look < create, "the tag is looked for before anything is created")
            t.expect(lines.contains("if [ -z \"$n\" ]; then"), "and only a missing one creates")
            t.expect(lines.contains("  tmux set-option -t \"=$n:\" @lampboard \"$l\""), "the new session carries the tag")
        },

        TestCase("What goes over ssh runs under sh, whatever shell the person has there") { t in
            let target = LiveTarget.starting(host: "box", folder: "/home/dev/it's", name: "its", launch: "0123456789abcdef")!
            let command = LiveLaunch.command(for: target, claude: "/x/claude", environment: LiveLaunchSuite.base, home: "/home/dev")
            let last = command?.arguments.last ?? ""
            t.expect(last.hasPrefix("sh -c '"), last)
            t.expectEqual(Array(command?.arguments.suffix(3).prefix(2) ?? []), ["--", "box"])
            t.expect(target.command.hasPrefix("ssh -t box 'sh -c '"), target.command)
        },

        TestCase("Only a usable start: an absolute folder, a host that is not an option, a tag of hex") { t in
            t.expectNil(LiveTarget.starting(host: "box", folder: "relative/path", name: "x"), "an absolute folder only")
            t.expectNil(LiveTarget.starting(host: "-oProxyCommand=x", folder: "/x", name: "x"))
            t.expectNil(LiveTarget.starting(host: "box", folder: "/x", name: "x", launch: "$(reboot)0123456789"))
            t.expect(NewSession.isLaunchTag(NewSession.newLaunchTag()), "a fresh tag is one")
            t.expect(NewSession.newLaunchTag() != NewSession.newLaunchTag(), "and fresh")
        },
    ])
}

/// «Move to LampBoard» (D135): a conversation in VS Code goes on as a
/// background session here; everything that can fail is checked first.
enum MoveHereSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let id = "4b138f7d-67ab-4d4c-9396-77adaed0f851"

    static func session(entrypoint: String?, origin: SessionOrigin = .editor, host: String? = nil) -> SessionState {
        SessionState(id: id, status: .ready, workspace: Workspace(path: "/Users/dev/web", host: host),
                     updatedAt: t0, statusSince: t0, entrypoint: entrypoint, origin: origin)
    }

    static func config(_ projects: [String: Bool]) -> Data {
        let object = ["projects": projects.mapValues { ["hasTrustDialogAccepted": $0] }]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static let suite = TestSuite("Move to LampBoard", [

        TestCase("Offered for this Mac's conversations in VS Code, and no other") { t in
            t.expect(MoveHere.isMovable(session(entrypoint: "claude-vscode")), "VS Code, Cursor, Windsurf")
            t.expect(!MoveHere.isMovable(session(entrypoint: "cli", origin: .terminal)), "a terminal keeps its own")
            t.expect(!MoveHere.isMovable(session(entrypoint: "claude-vscode", host: "box")), "another machine's")
            t.expect(!MoveHere.isMovable(session(entrypoint: "claude-vscode", origin: .background)), "already in the background")
            t.expect(!MoveHere.isMovable(session(entrypoint: nil)), "an editor that does not say which")
        },

        TestCase("Only between turns: a turn or a question would be cut where it stands") { t in
            for status in [SessionStatus.idle, .ready, .waiting, .failed] { t.expect(MoveHere.isBetweenTurns(status), "\(status)") }
            t.expect(!MoveHere.isBetweenTurns(.working), "working")
            t.expect(!MoveHere.isBetweenTurns(.awaiting), "waiting for an answer")
        },

        TestCase("Trust is checked before anything ends: the folder, or a folder above it") { t in
            t.expect(MoveHere.isTrusted(folder: "/Users/dev/web", config: config(["/Users/dev/web": true])), "itself")
            t.expect(MoveHere.isTrusted(folder: "/Users/dev/web/app", config: config(["/Users/dev": true, "/Users/dev/web": false])),
                     "a trusted parent covers a child marked false (measured)")
            t.expect(!MoveHere.isTrusted(folder: "/Users/dev/web", config: config(["/Users/dev/webby": true])), "not a sibling")
            t.expect(!MoveHere.isTrusted(folder: "/Users/dev/web", config: config([:])), "nothing trusted")
            t.expect(!MoveHere.isTrusted(folder: "/Users/dev/web", config: nil), "no settings file")
            t.expect(!MoveHere.isTrusted(folder: "relative", config: config(["/": true])), "a relative folder")
        },

        TestCase("Claude Code's settings file: its config folder when set, the home's otherwise") { t in
            t.expectEqual(MoveHere.configPath(environment: [:], home: "/Users/dev"), "/Users/dev/.claude.json")
            t.expectEqual(MoveHere.configPath(environment: ["CLAUDE_CONFIG_DIR": "/Users/dev/.cc"], home: "/Users/dev"),
                          "/Users/dev/.cc/.claude.json")
            t.expectEqual(MoveHere.configPath(environment: ["CLAUDE_CONFIG_DIR": "rel"], home: "/Users/dev"), "/Users/dev/.claude.json")
        },

        TestCase("The new process resumes the same conversation, under its name, in the background") { t in
            let command = LiveLaunch.start(directory: "/Users/dev/web", name: "web", resume: id, claude: "/x/claude",
                                           environment: LiveLaunchSuite.base, home: "/Users/dev")
            t.expectEqual(command?.arguments, ["--bg", "--resume", id, "--name", "web"])
            t.expectNil(LiveLaunch.start(directory: "/Users/dev/web", name: nil, resume: "--help", claude: "/x/claude",
                                         environment: [:], home: "/Users/dev"), "an id that is an option")
            t.expectEqual(MoveHere.fallback(sessionId: id, folder: "/Users/dev/it's"),
                          #"cd '/Users/dev/it'\''s' && claude --resume "# + id, "what to type if the start fails")
        },
    ])
}

extension MoveHereSuite {
    static let outcomes = TestSuite("Move to LampBoard: what is said after", [
        TestCase("Nobody is told to resume a conversation that may already have a process") { t in
            let unknown = MoveHere.message(.unknown, sessionId: id, folder: "/Users/dev/web")
            t.expect(!unknown.contains("claude --resume"), "no answer: look first, resume nothing")
            t.expect(unknown.contains("claude agents"), unknown)
            let refused = MoveHere.message(.refused("Not signed in."), sessionId: id, folder: "/Users/dev/web")
            t.expect(refused.contains("cd '/Users/dev/web' && claude --resume \(id)"), "a refusal: nothing runs, the line is given")
            let started = MoveHere.message(.started(job: "80129edd"), sessionId: id, folder: "/Users/dev/web")
            t.expect(started.contains("claude attach 80129edd") && !started.contains("--resume"), started)
        },
    ])
}

/// The live view's files (D136): the tree, the file the agent is on, and a
/// citation the session reads as an attachment.
enum ProjectFilesSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static let suite = TestSuite("Live view: files and citations", [

        TestCase("A citation is the path from the session's folder, a space escaped, the lines after #L") { t in
            t.expectEqual(ProjectFiles.citation(path: "/Users/dev/web/src/app.ts", root: "/Users/dev/web"), "@src/app.ts ")
            t.expectEqual(ProjectFiles.citation(path: "/Users/dev/web/my notes.md", root: "/Users/dev/web", lines: 2...2),
                          #"@my\ notes.md#L2-2 "#, "measured: quotes do not work, a backslash does")
            t.expectEqual(ProjectFiles.citation(path: "/Users/dev/web/a.swift", root: "/Users/dev/web/", lines: 3...7), "@a.swift#L3-7 ")
            t.expectEqual(ProjectFiles.citation(path: "/etc/hosts", root: "/Users/dev/web"), "@/etc/hosts ", "outside the folder, whole")
            t.expectEqual(ProjectFiles.citation(path: "/Users/dev/webby/x", root: "/Users/dev/web"), "@/Users/dev/webby/x ", "a sibling is outside")
        },

        TestCase("The lines a selection covers, one ending at a line's start not taking that line") { t in
            let text = "one\ntwo\nthree\nfour"
            t.expectEqual(ProjectFiles.lines(in: text, selection: 0..<3), 1...1)
            t.expectEqual(ProjectFiles.lines(in: text, selection: 4..<13), 2...3)
            t.expectEqual(ProjectFiles.lines(in: text, selection: 4..<8), 2...2, "the newline after two is still line 2")
            t.expectEqual(ProjectFiles.lines(in: "é\nb", selection: 2..<3), 2...2, "counted in UTF-16, as a text view does")
            t.expectNil(ProjectFiles.lines(in: text, selection: 0..<99))
        },

        TestCase("The tree: folders first, Finder's order, the heavy folders left out") { t in
            let sorted = ProjectFiles.sorted([("file10", false), ("node_modules", true), ("src", true), ("file2", false),
                                              (".git", true), (".github", true), ("README.md", false)])
            t.expectEqual(sorted.map(\.name), [".github", "src", "file2", "file10", "README.md"])
        },

        TestCase("The file the agent is on: a file tool's whole path, inside the folder") { t in
            let edit = RunningTool(tool: "Edit", detail: "/Users/dev/web/src/app.ts", since: t0)
            t.expectEqual(ProjectFiles.followed(edit, root: "/Users/dev/web"), "/Users/dev/web/src/app.ts")
            t.expectNil(ProjectFiles.followed(RunningTool(tool: "Bash", detail: "/Users/dev/web/x", since: t0), root: "/Users/dev/web"))
            t.expectNil(ProjectFiles.followed(RunningTool(tool: "Read", detail: "/etc/hosts", since: t0), root: "/Users/dev/web"))
            let long = "/Users/dev/web/" + String(repeating: "a", count: 110)
            t.expectNil(ProjectFiles.followed(RunningTool(tool: "Read", detail: long, since: t0), root: "/Users/dev/web"),
                        "a detail the helper may have cut")
            t.expectNil(ProjectFiles.followed(nil, root: "/Users/dev/web"))
        },

        TestCase("The preview: text up to a megabyte, nothing else") { t in
            t.expectEqual(ProjectFiles.previewText(Data("let x = 1\n".utf8)), "let x = 1\n")
            t.expectNil(ProjectFiles.previewText(Data([0x89, 0x50, 0x4E, 0x47, 0x00])), "binary")
            t.expectNil(ProjectFiles.previewText(Data(repeating: 0x61, count: ProjectFiles.previewLimit + 1)), "too large")
        },

        TestCase("A window's header carries the folder and the file only for a session of this Mac") { t in
            let here = SessionState(id: "4b138f7d-67ab-4d4c-9396-77adaed0f851", status: .working, workspace: Workspace(path: "/Users/dev/web"),
                                    updatedAt: t0, statusSince: t0, origin: .background,
                                    runningTool: RunningTool(tool: "Read", detail: "/Users/dev/web/a.swift", since: t0),
                                    backgroundJob: BackgroundJob(id: "80129edd", sessionId: "4b138f7d-67ab-4d4c-9396-77adaed0f851", summary: nil, needs: nil))
            let heading = LiveHeading.of(.job("80129edd"), in: TrafficLightState(sessions: [here.id: here]))
            t.expectEqual(heading.folder, "/Users/dev/web")
            t.expectEqual(heading.following, "/Users/dev/web/a.swift")
            let place = TmuxPlace(session: "web", window: 0, pane: 0)!
            let away = SessionState(id: "s2", status: .working, workspace: Workspace(path: "/home/dev/web", host: "box"),
                                    updatedAt: t0, statusSince: t0)
            t.expectNil(LiveHeading.of(.tmux(host: "box", place: place, sessionId: "s2"), in: TrafficLightState(sessions: ["s2": away])).folder,
                        "another machine's files are not read from here")
        },
    ])
}

/// The sessions resting on other machines get their rows back after a restart
/// (D137), by the rule this Mac's own sessions follow.
enum RemoteAdoptionSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let reading = ContextReading(tokens: 1, model: "m", window: nil, confidence: .exact, at: t0, cacheLifetime: 3_600)

    static func live(_ id: String, entrypoint: String? = "cli", kind: String? = "interactive", host: String? = "box",
                     talked: Bool = true) -> LiveSession {
        LiveSession(pid: 12, sessionId: id, cwd: "/home/dev/web", entrypoint: entrypoint, name: "web", kind: kind,
                    modifiedAt: t0, host: host, context: talked ? reading : nil,
                    tmux: TmuxPlace(session: "web", window: 0, pane: 0), hasTranscript: talked)
    }

    static let suite = TestSuite("Sessions resting on other machines", [

        TestCase("A terminal's session with a conversation is a row before it speaks") { t in
            let found = RemoteAdoption.adoptable([live("a")], showsTerminalSessions: true)
            t.expectEqual(found.map(\.sessionId), ["a"])
        },

        TestCase("Not one in the background, an editor's, the SDK's, a headless one, one with no conversation, nor this Mac's") { t in
            let none = RemoteAdoption.adoptable([
                live("bg", kind: "bg"), live("editor", entrypoint: "claude-vscode"), live("sdk", entrypoint: "sdk-cli"),
                live("silent", talked: false), live("here", host: nil), live("headless", kind: "print"),
            ], showsTerminalSessions: true)
            t.expectEqual(none.map(\.sessionId), [])
        },

        TestCase("A session just resumed is one too, though no context can be read from its tail") { t in
            // Found the evening 1.3.1 shipped: the always-on box rebooted and resumed
            // its sessions, whose transcripts then ended in system records only.
            let json = #"{"sessions":[{"pid":12,"sessionId":"s1","cwd":"/home/dev/web","entrypoint":"cli","kind":"interactive","activityEpoch":1,"contextTail":"{\"type\": \"system\", \"timestamp\": \"2026-10-08T17:16:13.001Z\"}"}]}"#
            let session = try? RemoteSessionsDecoder.report(from: Data(json.utf8), host: "box", at: t0).sessions.first
            t.expectNil(session?.context, "nothing to read a context from")
            t.expectEqual(session?.hasTranscript, true, "but a transcript all the same")
            t.expectEqual(RemoteAdoption.adoptable(session.map { [$0] } ?? [], showsTerminalSessions: true).count, 1)
            let none = #"{"sessions":[{"pid":12,"sessionId":"s1","cwd":"/home/dev/web","entrypoint":"cli","activityEpoch":1,"contextTail":""}]}"#
            t.expectEqual(try? RemoteSessionsDecoder.report(from: Data(none.utf8), host: "box", at: t0).sessions.first?.hasTranscript, false)
        },

        TestCase("Nothing while terminal sessions are not shown") { t in
            t.expectEqual(RemoteAdoption.adoptable([live("a")], showsTerminalSessions: false).count, 0)
        },
    ])
}


/// Whose ask it is (D139): Claude Code's `ask` goes to the mode's decider.
enum PermissionModeSuite {
    static let suite = TestSuite("Permission asks and the session's mode", [

        TestCase("The person's in the modes that show a dialog, and while no mode was heard") { t in
            for mode in [nil, "default", "acceptEdits", "plan"] { t.expect(PermissionGate.isPersons(mode: mode), "\(mode ?? "none")") }
        },

        TestCase("Nobody's to ask in Auto, dontAsk or bypassPermissions") { t in
            for mode in ["auto", "dontAsk", "bypassPermissions"] { t.expect(!PermissionGate.isPersons(mode: mode), mode) }
        },

        TestCase("The hook's permission_mode is read, and kept by a copy of the signal") { t in
            let json = #"{"session_id":"s1","cwd":"/tmp/x","hook_event_name":"PreToolUse","permission_mode":"auto","tool_name":"Bash"}"#
            let signal = try? HookPayloadDecoder.decode(Data(json.utf8))
            t.expectEqual(signal?.permissionMode, "auto")
            t.expectEqual(signal?.withApprovalReviewer(nil).permissionMode, "auto")
        },
    ])
}

/// A click on a row whose session has a live window raises the window (D140).
enum LiveClickSuite {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func session(_ id: String) -> SessionState {
        SessionState(id: id, status: .idle, workspace: Workspace(path: "/home/dev/\(id)", host: "box"), updatedAt: t0, statusSince: t0)
    }
    static func target(_ s: SessionState) -> LiveTarget? {
        TmuxPlace(session: s.id, window: 0, pane: 0).map { .tmux(host: "box", place: $0, sessionId: s.id) }
    }

    static let suite = TestSuite("Live view: a click finds its window", [

        TestCase("The member with a window open is the one raised, the most urgent first") { t in
            let rows = [session("a"), session("b"), session("c")]
            let open: Set<String> = [target(rows[1])!.key, target(rows[2])!.key]
            t.expectEqual(LiveClick.openWindow(for: rows, target: target, isOpen: { open.contains($0.key) })?.key, target(rows[1])!.key)
        },

        TestCase("No window open: the click does what it did") { t in
            t.expectNil(LiveClick.openWindow(for: [session("a")], target: target, isOpen: { _ in false }))
            t.expectNil(LiveClick.openWindow(for: [session("a")], target: { _ in nil }, isOpen: { _ in true }), "nothing the live view opens")
        },
    ])
}

/// Claude Code's own "busy" lights a row the panel only knew as idle (D141).
enum EngineBusySuite {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func state(_ status: SessionStatus) -> TrafficLightState {
        TrafficLightState(sessions: ["s": SessionState(id: "s", status: status, workspace: Workspace(path: "/Users/dev/web"),
                                                         updatedAt: t0, statusSince: t0)])
    }

    static let suite = TestSuite("A session Claude Code says is busy", [

        TestCase("The session file's status is read") { t in
            let busy = try? LiveSessionParser.parse(data: Data(#"{"sessionId":"s","cwd":"/x","status":"busy"}"#.utf8), modifiedAt: t0)
            let idle = try? LiveSessionParser.parse(data: Data(#"{"sessionId":"s","cwd":"/x","status":"idle"}"#.utf8), modifiedAt: t0)
            t.expectEqual(busy?.isBusy, true)
            t.expectEqual(idle?.isBusy, false)
        },

        TestCase("An idle row turns working; a row that knows better is left alone") { t in
            let now = t0.addingTimeInterval(60)
            t.expectEqual(StateReducer.reduce(state(.idle), action: .busy(sessionId: "s"), now: now).sessions["s"]?.status, .working)
            for status in [SessionStatus.awaiting, .ready, .failed, .waiting] {
                t.expectEqual(StateReducer.reduce(state(status), action: .busy(sessionId: "s"), now: now).sessions["s"]?.status, status, "\(status)")
            }
            t.expect(StateReducer.reduce(state(.idle), action: .busy(sessionId: "nobody"), now: now).sessions["nobody"] == nil, "no row made")
        },
    ])
}
