import AppKit
import LampBoardCore
import Foundation

/// Commands callable from the terminal, useful for installing the hooks without
/// opening the interface and for diagnosing a configuration that isn't working.
enum CommandLineInterface {

    enum Command: Equatable {
        case run(port: UInt16, skipSetupPrompt: Bool, headless: Bool)
        case install(port: UInt16, includeToolEvents: Bool)
        case uninstall
        case status
        case codexProbe
        case selfTest(port: UInt16)
        case focus(workspaceName: String, dryRun: Bool)
        case next(port: UInt16)
        /// `nil` lists the assignments instead of opening one.
        case open(slot: Int?, port: UInt16)
        case newConversation(slot: Int?, port: UInt16)
        /// Reads a slot's conversation in a window of its own.
        case chat(slot: Int?, port: UInt16)
        case sessions(port: UInt16)
        /// The remote machines: list them, add or forget one, and install or
        /// remove the hooks over there. `verb` is the sub-command as typed.
        case remote(verb: String, host: String?)
        /// The "Show terminal sessions" switch (D25): `on`, `off`, or `status`.
        case terminal(verb: String)
        /// The name a row shows, by folder; an empty name restores the original.
        case rename(path: String?, name: String?)
        case help
    }

    static func parse(_ arguments: [String]) -> Command {
        let args = Array(arguments.dropFirst())
        let port = portOption(in: args) ?? AppConfig.listenPort

        switch args.first {
        case "install-hooks":
            return .install(port: port, includeToolEvents: args.contains("--with-tool-events"))
        case "uninstall-hooks":
            return .uninstall
        case "status":
            return .status
        case "codex-probe":
            return .codexProbe
        case "selftest", "doctor":
            return .selfTest(port: port)
        case "focus":
            return .focus(
                workspaceName: args.count > 1 && !args[1].hasPrefix("-") ? args[1] : "",
                dryRun: args.contains("--dry-run")
            )
        case "next":
            return .next(port: port)
        case "open":
            // A bare `open` lists what the slots address, which is the question
            // you have while deciding what to bind.
            return .open(
                slot: args.count > 1 ? Int(args[1]) : nil,
                port: port
            )
        case "new":
            return .newConversation(
                slot: args.count > 1 ? Int(args[1]) : nil,
                port: port
            )
        case "chat":
            return .chat(
                slot: args.count > 1 ? Int(args[1]) : nil,
                port: port
            )
        case "sessions":
            return .sessions(port: port)
        case "remote":
            return .remote(
                verb: args.count > 1 ? args[1] : "list",
                host: args.count > 2 && !args[2].hasPrefix("-") ? args[2] : nil
            )
        case "terminal":
            return .terminal(verb: args.count > 1 ? args[1] : "status")
        case "rename":
            return .rename(
                path: args.count > 1 ? args[1] : nil,
                name: args.count > 2 ? args[2...].joined(separator: " ") : nil
            )
        case "help", "--help", "-h":
            return .help
        case .some(let unknown) where unknown.hasPrefix("-") == false:
            return .help
        default:
            return .run(
                port: port,
                skipSetupPrompt: args.contains("--skip-setup-prompt"),
                headless: args.contains("--headless")
            )
        }
    }

    /// Runs the commands that don't need the interface.
    /// - Returns: the exit code, or `nil` when the app should start up.
    static func execute(_ command: Command) -> Int32? {
        switch command {
        case .run:
            return nil

        case .install(let port, let includeToolEvents):
            return runInstall(port: port, includeToolEvents: includeToolEvents)

        case .uninstall:
            return runUninstall()

        case .status:
            return runStatus()

        case .codexProbe:
            return runCodexProbe()

        case .selfTest(let port):
            return SelfTest.run(port: port)

        case .focus(let workspaceName, let dryRun):
            return runFocus(workspaceName: workspaceName, dryRun: dryRun)

        case .next(let port):
            return runNext(port: port)

        case .open(let slot, let port):
            return runOpen(slot: slot, port: port)

        case .newConversation(let slot, let port):
            return runSlotCommand(
                slot: slot, port: port, verb: "new",
                request: LocalClient.newConversation,
                describe: { "New conversation in \($0)." }
            )

        case .chat(let slot, let port):
            return runSlotCommand(
                slot: slot, port: port, verb: "chat",
                request: LocalClient.chat,
                describe: { "Reading \($0)." }
            )

        case .sessions(let port):
            return runSessions(port: port)

        case .remote(let verb, let host):
            return runRemote(verb: verb, host: host)
        case .terminal(let verb):
            return runTerminal(verb: verb)
        case .rename(let path, let name):
            return runRename(path: path, name: name)

        case .help:
            print(helpText)
            return 0
        }
    }

    // MARK: - Commands


    /// The state of the features that start out switched off.
    ///
    /// They exist, but until somebody turns them on they never run — and that is
    /// the condition which, in this project, has produced more defects than any
    /// other. Making them visible is the first step towards testing them.
    static func printOptionalFeatures() {
        let preferences = Preferences()
        print()
        print("OPTIONAL FEATURES (off by default)")

        print("  Notifications:    \(preferences.notificationsEnabled ? "on" : "off")")
        if let until = preferences.mutedUntil {
            print("                    muted until \(shortTime(until))")
        }
        if !preferences.mutedWorkspaces.isEmpty {
            print("                    \(preferences.mutedWorkspaces.count) projects muted")
        }


        print("  Terminal rows:    \(preferences.showsTerminalSessions ? "on" : "off")  (sessions in folders no editor claims)")
        print("  Presence:         \(preferences.presenceEnabled ? "on" : "off")")
        let presenceVariable = ProcessInfo.processInfo.environment["CLAUDE_CLIENT_PRESENCE_FILE"]
        if preferences.presenceEnabled && presenceVariable == nil {
            // On without the variable is the combination that does nothing and
            // doesn't say so: the file gets created and nobody reads it.
            print("                    WARNING: CLAUDE_CLIENT_PRESENCE_FILE is not set,")
            print("                    so Claude Code never reads the file and the feature is inert.")
            print("                    export CLAUDE_CLIENT_PRESENCE_FILE=\"\(AppConfig.presenceFileURL.path)\"")
        }

        switch LaunchAtLogin.availability {
        case .available:
            print("  Launch at login:  \(LaunchAtLogin.isEnabled ? "enabled" : "available, not enabled")")
        case .needsStableSignature:
            print("  Launch at login:  BLOCKED: a stable signature is required")
        case .needsBundle:
            print("  Launch at login:  not applicable (you are running the binary, not the app)")
        }

        print()
        print("  Turn them on from the panel menu (right-click on the margins).")
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Reproduces exactly what clicking a traffic light does, and reports which
    /// of the two strategies worked.
    ///
    /// Needed because the click, by its nature, cannot explain itself: either the
    /// window comes to the front or it doesn't, and the reason stays invisible.
    private static func runFocus(workspaceName: String, dryRun: Bool) -> Int32 {
        let windows = IDEWindowReader().readWindows()
        let open = windows
            .filter { $0.isSupported }
            .flatMap(\.workspaceFolders)
            .map { Workspace(path: $0) }

        guard !workspaceName.isEmpty else {
            print("Usage: lampboard focus <workspace-name>\n")
            print("Workspaces currently open in VS Code:")
            for workspace in open.sorted(by: { $0.name < $1.name }) {
                print("  \(workspace.name)")
            }
            return 1
        }

        guard let workspace = open.first(where: {
            $0.name.caseInsensitiveCompare(workspaceName) == .orderedSame
        }) else {
            FileHandle.standardError.write(
                Data("No open workspace named “\(workspaceName)”.\n".utf8)
            )
            return 1
        }

        print("Trying to activate “\(workspace.name)” (\(workspace.path))\n")

        // The titles are the only handle on the window: printing them makes
        // visible the case where the read returns nothing, which otherwise shows
        // up only as a click that does nothing.
        switch VSCodeFocuser.windowTitles() {
        case .failure(let error):
            print("✗ cannot read the window titles: \(error.shortDescription)\n")
        case .success(let titles) where titles.isEmpty:
            print("✗ accessibility sees no editor window at all")
            print("  This does not mean the project isn't open: it means macOS")
            print("  is not letting us read other applications' windows.")
            print("  Most frequent cause: the screen is locked.\n")
        case .success(let titles):
            print("VS Code windows seen (\(titles.count)):")
            for (index, title) in titles.enumerated() {
                let match = WindowTitleMatcher.bestMatch(
                    workspaceName: workspace.name, titles: titles
                )
                print("  \(match == index ? "→" : " ") [\(index + 1)] \(title)")
            }
            print()
        }

        if dryRun {
            // Deliberately stops here: this is for diagnosing without moving any
            // windows. Useful when you want to find out whether recognition works
            // without interrupting whatever the user is doing.
            print("(--dry-run: no window was activated)")
            return 0
        }

        switch VSCodeFocuser.focus(workspace: workspace) {
        case .raised:
            print("✓ window raised with AppleScript, which is the correct behaviour")
            return 0

        case .activatedOnly(let reason):
            print("△ VS Code activated, but not the right window")
            print("  reason: \(reason.shortDescription)")
            print()
            print(reason.errorDescription ?? "")
            return 1

        case .failed(let error):
            print("✗ no activation at all")
            print("  reason: \(error.shortDescription)")
            print()
            print(error.errorDescription ?? "")
            return 1
        }
    }

    /// Raises the next waiting session by asking the running instance.
    private static func runNext(port: UInt16) -> Int32 {
        switch LocalClient.next(port: port) {
        case .success(let description):
            print(description.isEmpty ? "No session is waiting." : description)
            return description.isEmpty ? 1 : 0
        case .failure(let error):
            FileHandle.standardError.write(
                Data("\(error.localizedDescription)\n".utf8)
            )
            return 1
        }
    }

    /// Raises the project bound to a slot, or lists what the slots address.
    ///
    /// This is the command a keyboard shortcut binds to. It answers in three
    /// distinct ways on purpose — raised, empty, unreachable — because a key you
    /// press without looking has to tell you which of the three happened.
    private static func runOpen(slot: Int?, port: UInt16) -> Int32 {
        guard let slot else {
            return listSlots(port: port)
        }

        guard (1...AppConfig.maxSlots).contains(slot) else {
            FileHandle.standardError.write(
                Data("Slot must be a number from 1 to \(AppConfig.maxSlots).\n".utf8)
            )
            return 2
        }

        switch LocalClient.open(slot: slot, port: port) {
        case .success(let description):
            if description.isEmpty {
                // Not a failure: the slot exists, nothing is bound to it or the
                // project has no live session. Exit 1 so a shortcut can tell
                // "nothing happened" from "it worked".
                print("Slot \(slot) is empty.")
                return 1
            }
            print(description)
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Opens a new conversation in the project bound to a slot.
    ///
    /// Same three answers as `open`, for the same reason: bound to a key, it has
    /// to say which of them happened.
    /// The shape every slot-addressed command shares.
    ///
    /// `new` and `chat` differ only in which endpoint they call and what they say
    /// afterwards; everything else — the missing argument, the range, the empty
    /// slot, the three exit codes — is identical, and identical code written twice
    /// is identical code that drifts. `open` stays on its own because a bare
    /// `open` lists the assignments, which is a different command wearing the same
    /// name.
    ///
    /// The exit codes are the contract for whoever binds this to a key:
    /// `0` something happened · `1` the slot is empty or the panel isn't running ·
    /// `2` you asked for something impossible.
    private static func runSlotCommand(
        slot: Int?,
        port: UInt16,
        verb: String,
        request: (Int, UInt16) -> Result<String, LocalClient.ClientError>,
        describe: (String) -> String
    ) -> Int32 {
        guard let slot else {
            let usage = "Usage: lampboard \(verb) <slot>. "
                + "See `lampboard open` for the assignments.\n"
            FileHandle.standardError.write(Data(usage.utf8))
            return 2
        }
        guard (1...AppConfig.maxSlots).contains(slot) else {
            FileHandle.standardError.write(
                Data("Slot must be a number from 1 to \(AppConfig.maxSlots).\n".utf8)
            )
            return 2
        }

        switch request(slot, port) {
        case .success(let name):
            if name.isEmpty {
                print("Slot \(slot) is empty.")
                return 1
            }
            print(describe(name))
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// What each slot currently opens, read from the running instance.
    private static func listSlots(port: UInt16) -> Int32 {
        switch LocalClient.sessions(port: port) {
        case .failure(let error):
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        case .success(let response):
            // One entry per slot: with grouping off a project has several
            // sessions and they all carry its slot, but a key opens one thing.
            var bySlot: [Int: SessionSnapshot] = [:]
            for session in response.sessions {
                guard let slot = session.slot else { continue }
                if bySlot[slot] == nil { bySlot[slot] = session }
            }
            let slotted = bySlot.keys.sorted().compactMap { bySlot[$0] }

            guard !slotted.isEmpty else {
                print("No slots occupied.")
                print()
                print("The first nine rows of the panel are slots 1 to 9, in the order you")
                print("arranged them: drag a row by its handle, or right-click → Move up /")
                print("Move down. The column never reorders itself: that is what makes a")
                print("bound key reliable.")
                return 0
            }

            let nameWidth = max(12, slotted.map(\.label.count).max() ?? 12)
            for session in slotted {
                print(
                    "\(session.slot ?? 0)  "
                        + session.label.padded(to: nameWidth + 2)
                        + session.status
                )
            }
            print()
            print("Bind these with: lampboard open <n>")
            return 0
        }
    }

    /// Prints the column state exactly as the running instance sees it.
    private static func runSessions(port: UInt16) -> Int32 {
        switch LocalClient.sessions(port: port) {
        case .success(let response):
            guard !response.sessions.isEmpty else {
                print("No sessions in the column.")
                return 0
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "dd/MM HH:mm"

            // The padding is explicit because `String(format:)` ignores the width
            // on `%@` placeholders: the columns came out jammed together, and a
            // ten-row list that doesn't line up cannot be read.
            // A terminal row is named the way the panel names it — by its
            // conversation — and says what it is, since its click leads to a
            // tab and not to an editor window.
            func name(of session: SessionSnapshot) -> String {
                session.origin == SessionOrigin.terminal.rawValue ? "\(session.label) [terminal]" : session.label
            }
            let nameWidth = max(12, response.sessions.map { name(of: $0).count }.max() ?? 12)

            for session in response.sessions {
                let subagents = session.activeSubagents > 0 ? "  ×\(session.activeSubagents)" : ""
                print(
                    session.status.padded(to: 9)
                        + name(of: session).padded(to: nameWidth + 2)
                        + formatter.string(from: session.updatedAt)
                        + subagents
                )
            }
            return 0
        case .failure(let error):
            FileHandle.standardError.write(
                Data("\(error.localizedDescription)\n".utf8)
            )
            return 1
        }
    }

    // MARK: - Help

    private static var helpText: String {
        """
        LampBoard: floating traffic lights for Claude Code and Codex sessions.

        USAGE
          lampboard [--port N]              start the floating panel
          lampboard install-hooks [options] register the hooks in ~/.claude/settings.json
          lampboard uninstall-hooks         remove the registrations
          lampboard status                  show the detected configuration
          lampboard selftest                check the whole chain and report what's missing
          lampboard focus <workspace>       reproduce the click and report which strategy worked
                                              (with no argument it lists the open workspaces,
                                               with --dry-run it diagnoses without activating anything)
          lampboard sessions                print the column as the running app sees it
          lampboard next                    raise the window of the next waiting session
          lampboard open <n>                raise the project bound to slot n
                                              (with no argument, lists what the slots address)
          lampboard new <n>                 open a new conversation in slot n's project
          lampboard chat <n>                read slot n's conversation in its own window,
                                              without touching the editor
          lampboard remote [verb] [host]    the machines whose sessions join the column:
                                              list | add | remove | check | install | uninstall
          lampboard help                    show this text

        OPTIONS
          --port N              port of the local server (default \(AppConfig.listenPort))
          --with-tool-events    also register PreToolUse (PostToolUse is on by default). Makes yellow
                                more responsive mid-turn, at the cost of one process per
                                single tool call.
          --skip-setup-prompt   don't offer to install the hooks at startup.
                                Useful when launching the app automatically at login.
          --headless            start without the panel: server and realignment only.
                                Used by the end-to-end tests.

        ENVIRONMENT
          \(AppConfig.homeOverrideVariable)      moves every path the app uses under a different root.
                                Used by the tests so they never touch the real ~/.claude.

        SLOTS
          The first \(AppConfig.maxSlots) rows are slots 1 to \(AppConfig.maxSlots). The column keeps the order you
          gave it: drag a row by its handle, or right-click → Move up / Move down.
          and never reorders itself. That is what makes `lampboard open 3` worth
          binding to a key.

        REMOTE MACHINES
          `lampboard remote add <host>` (a name ssh understands, key login only) and
          `lampboard remote install <host>` register the hooks over there. The panel
          keeps an ssh tunnel open so those hooks reach this Mac; a remote session
          gets its row when it speaks, and clicking it raises its Remote-SSH window.

        TERMINAL SESSIONS
          `lampboard terminal on` shows sessions started with `claude` in a terminal,
          in folders no editor window has open, named by their conversation. Off by
          default; `off` takes those rows away at once.

        NAMES
          Right-click a row → Rename… gives it the name you want to read; the session,
          its window and its folder keep theirs. `lampboard rename <folder> [name]`
          does the same from here; no name restores the original.

        STATES
          red        the session is at rest
          yellow     Claude is working
          amber      Claude is waiting for your permission (blinks)
          green      there is an answer to read

        READING WITHOUT SWITCHING
          ⌘+click on a row (or `lampboard chat <n>`) opens the conversation in
          a window of its own, one per session, leaving VS Code where it is. It is
          read-only: the extension refuses to deliver a prompt to a session whose
          panel is already open, so answering still happens in the editor.

        Click a traffic light to open the corresponding VS Code window.
        Right-click on the panel for the menu.
        """
    }

    // MARK: - Remote machines

    /// `lampboard rename <folder> [name]`: the panel's word for a row.
    ///
    /// Writes the preferences; the running panel picks it up within one poll.
    /// No name, or an empty one, restores the original.
    private static func runRename(path: String?, name: String?) -> Int32 {
        guard let path, path.hasPrefix("/") else {
            print("Usage: lampboard rename </absolute/folder> [name]   (no name restores the original)")
            return 2
        }
        let preferences = Preferences()
        preferences.rowNames = RowNames.renaming(path, to: name, in: preferences.rowNames)
        if let given = RowNames.name(of: path, in: preferences.rowNames) {
            print("“\(given)” is now the panel's word for \(path).")
        } else {
            print("\(path) shows its own name again.")
        }
        return 0
    }

    /// `lampboard terminal on|off|status`: the "Show terminal sessions" switch.
    ///
    /// The running panel follows it within one poll: off takes the terminal rows
    /// away, on lets the next pass adopt what is there.
    private static func runTerminal(verb: String) -> Int32 {
        let preferences = Preferences()
        switch verb {
        case "on", "off":
            preferences.showsTerminalSessions = verb == "on"
            print("Terminal sessions \(verb). The panel follows within five seconds.")
            return 0
        case "status":
            print("Terminal sessions: \(preferences.showsTerminalSessions ? "on" : "off")")
            return 0
        default:
            print("Usage: lampboard terminal [on | off | status]")
            return 2
        }
    }

    /// `lampboard remote …`: the Settings window's buttons, from a terminal.
    ///
    /// The list lives in the preferences, and the running panel follows it — a
    /// host added here gets its tunnel without a restart. Installing the hooks
    /// needs no running panel at all: it is two ssh round trips.
    private static func runRemote(verb: String, host: String?) -> Int32 {
        let preferences = Preferences()

        func requireHost() -> String? {
            guard let host, RemoteHostList.isUsable(host) else {
                print("Usage: lampboard remote \(verb) <host>   (a name ssh understands)")
                return nil
            }
            return host
        }

        switch verb {
        case "list":
            let hosts = preferences.remoteHosts
            if hosts.isEmpty {
                print("No remote machines. Add one: lampboard remote add <host>")
            } else {
                for host in hosts { print(host) }
            }
            return 0

        case "add":
            guard let host = requireHost() else { return 2 }
            var hosts = preferences.remoteHosts
            guard !hosts.contains(host) else {
                print("\(host) is already in the list.")
                return 0
            }
            hosts.append(host)
            preferences.remoteHosts = hosts
            print("Added \(host). The panel opens its tunnel now; install the hooks there with")
            print("  lampboard remote install \(host)")
            return 0

        case "remove", "forget":
            guard let host = requireHost() else { return 2 }
            preferences.remoteHosts = preferences.remoteHosts.filter { $0 != host }
            print("Forgot \(host). Its hooks, if installed, stay until `lampboard remote uninstall \(host)`.")
            return 0

        case "check":
            guard let host = requireHost() else { return 2 }
            switch RemoteHookInstaller.inspect(host) {
            case .success(let inspection):
                print("\(host): python \(inspection.pythonVersion), curl \(inspection.hasCurl ? "present" : "MISSING"), "
                      + "hooks \(inspection.hooksInstalled ? "installed" : "not installed")")
                if let error = inspection.error { print("  settings.json unreadable: \(error)") }
                if let problem = inspection.directoryProblem { print("  ~/.lampboard there \(problem)") }
                // Read-only here: the panel rewrites stale hooks itself when it
                // connects, and a person asking from a terminal is told what it
                // will find rather than having the file changed under them.
                if let token = TokenStore().read(), let verdict = inspection.repairVerdict(token: token) {
                    switch verdict {
                    case .current:
                        print("  token: the hooks there carry this panel's token")
                    case .stale:
                        print("  token: the hooks there carry no token; the panel rewrites them when it "
                              + "connects, or run `lampboard remote install \(host)`")
                    case .addressedElsewhere:
                        print("  token: the hooks there post to another port, so they are not this panel's to repair")
                    case .nothingInstalled:
                        break
                    }
                }
                switch RemoteHookInstaller.tunnelStatus(on: host, port: inspection.port) {
                case .success(let tunnel): print("  tunnel (127.0.0.1:\(inspection.port) there): \(tunnel.sentence)")
                case .failure(let error): print("  tunnel: could not ask (\(error.short))")
                }
                return 0
            case .failure(let error):
                print("\(host): \(error.short)")
                return 1
            }

        case "install":
            guard let host = requireHost() else { return 2 }
            switch RemoteHookInstaller.install(on: host) {
            case .success(let message): print(message); return 0
            case .failure(let error): print("\(host): \(error.short)"); return 1
            }

        case "uninstall":
            guard let host = requireHost() else { return 2 }
            switch RemoteHookInstaller.uninstall(on: host) {
            case .success(let message): print(message); return 0
            case .failure(let error): print("\(host): \(error.short)"); return 1
            }

        default:
            print("Usage: lampboard remote [list | add <host> | remove <host> | check <host> | install <host> | uninstall <host>]")
            return 2
        }
    }

    // MARK: - Helpers

    private static func portOption(in args: [String]) -> UInt16? {
        guard let index = args.firstIndex(of: "--port"),
              index + 1 < args.count,
              let value = UInt16(args[index + 1]) else {
            return nil
        }
        return value
    }

    /// What the other machines are saying, if any were configured.
    ///
    /// Printed because there is otherwise no way to tell "no remote sessions" from
    /// "the node never answered" — and those need opposite reactions.
    static func reportRemoteHosts() {
        let hosts = Preferences().remoteHosts
        guard !hosts.isEmpty else {
            print("\nRemote hosts: none configured (panel menu → Settings…)")
            return
        }
        print("\nRemote hosts (their hooks reach this Mac through the tunnel; presence read over ssh):")
        for host in hosts {
            guard let sessions = RemoteSessionReader(host: host).readLiveSessions() else {
                print("  · \(host): NO ANSWER: asleep, or ssh cannot reach it")
                continue
            }
            let shown = sessions.filter(\.deservesTrafficLight)
            print("  · \(host): \(shown.count) sessions in the column"
                  + (sessions.count == shown.count ? "" : " (\(sessions.count - shown.count) not interactive)"))
            for session in shown {
                print("      \(session.cwd)")
            }
        }
    }

}
