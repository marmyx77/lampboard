import LampBoardCore
import Foundation

/// The text `lampboard help` prints. In a file of its own because it grows with
/// every command and the parser beside it sits near the 800-line ceiling.
extension CommandLineInterface {

    static var helpText: String {
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
          lampboard search <words>          your conversations that say them, the best first
          lampboard search --reset          take the search index away (the panel builds it again)
          lampboard week                    the last seven days in a paragraph, from the same index
          lampboard usage                   ask Anthropic how much of the allowance is gone,
                                              on this Mac and on every node, and print it
          lampboard next                    raise the window of the next waiting session
          lampboard open <n>                raise the project bound to slot n
                                              (with no argument, lists what the slots address)
          lampboard new <n>                 open a new conversation in slot n's project
          lampboard chat <n>                read slot n's conversation in its own window,
                                              without touching the editor
          lampboard remote [verb] [host]    the machines whose sessions join the column:
                                              list | add | remove | check | install | uninstall
          lampboard mcp [install|uninstall|status]
                                            the lampmaster MCP server: with no verb, the server
                                              itself, as Claude Code starts it; install registers
                                              it for every session, uninstall removes it
          lampboard mod [install|uninstall|status]
                                            the companion mod, in every Claude Code session
          lampboard watch [--name N] -- <command>
                                            run a command as a row: yellow while it runs,
                                              green when it exits 0, red otherwise
          lampboard tour [--json]           a trial panel on invented sessions, beside yours;
                                              --json prints the script it plays
          lampboard help                    show this text

        OPTIONS
          --port N              port of the local server (default \(AppConfig.listenPort))
          --with-tool-events    also register PreToolUse (PostToolUse is on by default). Makes yellow
                                more responsive mid-turn, at the cost of one process per
                                single tool call.
          --skip-setup-prompt   don't offer to install the hooks at startup.
                                Useful when launching the app automatically at login.
          --getting-started, --settings   open that window at launch.
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
}
