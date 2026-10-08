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
