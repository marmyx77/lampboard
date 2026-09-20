import Foundation

/// Generates the shell script a coding agent's hooks run.
///
/// The script is deliberately dumb: it reads the JSON on stdin, forwards it to
/// the traffic light and **always exits 0**. A failing hook can interrupt a
/// turn, and nobody wants their work to stop because a decorative widget wasn't
/// running. Codex is stricter still — it holds a turn for up to three seconds
/// waiting for its hooks — so the timeouts below are a promise to both.
public enum HookScriptBuilder {

    /// Where the script for `port` posts. The same string `HookConfigMerger`
    /// writes into a native hook, so the two halves of an installation can never
    /// name different listeners.
    public static func target(port: UInt16) -> String {
        "http://\(AppConfig.listenHost):\(port)\(AppConfig.signalPath)"
    }

    /// `true` when `script` posts to the listener on `port`.
    ///
    /// Read off the installed file rather than remembered, for the same reason
    /// `HookConfigMerger.isOurEndpoint` is structural: the script is the one
    /// record of where it posts, and an instance about to rewrite it has to know
    /// whether it is the listener the script was written for.
    public static func posts(_ script: String, to port: UInt16) -> Bool {
        script.contains("'\(target(port: port))'")
    }

    /// - Parameters:
    ///   - port: where to post. Locally the app's port; on another machine the
    ///     per-user loopback port the tunnel binds there (`AppConfig.remotePort`).
    ///   - host: when given, the script runs on another machine and says which in
    ///     an `X-LampBoard-Host` header, so that a signal arriving through the tunnel is
    ///     told apart from a local one. The value is embedded in single quotes; it
    ///     has passed `RemoteHostList.isUsable`, whose allow-list has no quote,
    ///     space or backslash in it, so nothing here can escape.
    ///   - harness: which agent this copy serves. One script is installed per
    ///     harness and each declares itself in a header, because the sender is
    ///     the only party that knows for certain — see `AppConfig.harnessHeader`.
    /// - Parameter token: authorizes the post, exactly as the native hooks' header
    ///   does. The script carried none for most of this project's life, which was
    ///   harmless while `POST /signal` accepted anything — and became the thing
    ///   standing between here and requiring one: `SessionStart`, `SessionEnd` and
    ///   `Stop` all run this script, and `Stop` is what turns a row green. Absent
    ///   still writes a working script, because a machine whose token could not be
    ///   read should get a panel that works rather than none.
    public static func script(
        port: UInt16 = AppConfig.listenPort,
        host: String? = nil,
        harness: Harness = .claudeCode,
        token: String? = nil
    ) -> String {
        let origin = host.map { "     --header '\(AppConfig.remoteHostHeader): \($0)' \\\n" } ?? ""
        // Single-quoted, and the value is hexadecimal by construction
        // (`AccessToken.generate`), so there is nothing in it a shell could read.
        let auth = token.map { "     --header '\(AccessToken.headerName): \($0)' \\\n" } ?? ""
        let target = target(port: port)
        let where_ = host.map {
            " It runs on \($0) and posts through the ssh tunnel lampboard keeps open."
        } ?? ""

        // Claude Code names the surface a session was started from in this
        // variable; Codex has no equivalent, and inventing one would put a lie in
        // a field the workspace resolver trusts. Codex says where it came from in
        // the rollout's `originator` instead, which is read where it belongs.
        let entrypoint = harness == .claudeCode
            ? "     --header \"\(AppConfig.entrypointHeader): ${CLAUDE_CODE_ENTRYPOINT:-}\" \\\n"
            : ""

        // Codex answers its hooks synchronously and gives them one second before
        // it starts waiting, three before it gives up. Claude Code is patient. The
        // tighter pair costs nothing to the patient one and keeps a turn from ever
        // noticing this script.
        let connect = harness == .codex ? "0.5" : "1"
        let total = harness == .codex ? "1.5" : "2"

        return """
        #!/bin/bash
        # LampBoard: forwards \(harness.displayName) events to the floating traffic light.\(where_)
        #
        # Generated automatically: hand edits are overwritten on the next
        # installation. Always exits 0, so the absence of the traffic light can
        # never block a turn.

        set -u

        BODY=$(cat)

        # The session's git identity, resolved **here** rather than by the app.
        #
        # This script runs in the user's own shell, in the session's working
        # directory, under the terminal's own permissions. The app cannot do the
        # same: macOS gates Desktop, Documents, Downloads and network volumes as
        # separate grants, so reading `<cwd>/.git/HEAD` from the app would pop a
        # folder-access prompt the first time a session appeared under any
        # not-yet-granted category — once per category, forever.
        #
        # On a session start **and** at the end of each turn, and both are needed.
        #
        # A start alone is not enough: a brand new session has written no transcript
        # yet, so its start earns no row at all (D44) and the identity would be
        # thrown away with it. `Stop` lands on a row that certainly exists.
        #
        # `Stop` rather than `UserPromptSubmit` for the turn: that one sits between
        # the person pressing enter and Claude starting, which is exactly where a
        # hook must not add work. `Stop` fires when the session is idle by
        # definition. The bonus is that a `git checkout` half way through a session
        # reaches the row within one turn.
        #
        # It costs one `git` invocation per turn, off the critical path. Resolving
        # per event would pay it on every tool call for a fact that changes a
        # handful of times a day.
        GIT_HEADERS=()
        case "$BODY" in
          *'"hook_event_name":"SessionStart"'*|*'"hook_event_name": "SessionStart"'*|\
          *'"hook_event_name":"Stop"'*|*'"hook_event_name": "Stop"'*)
            # `\\/` is JSON's optional escaping of a forward slash, and it is legal.
            # Claude Code does not use it, Foundation does — so a payload that
            # arrives from anything but Claude Code hands this a path full of
            # backslashes and `git -C` fails on every one of them, silently, with
            # the row simply never showing a branch. Undone here rather than
            # assumed away.
            CWD=$(printf '%s' "$BODY" \\
                  | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' \\
                  | sed 's|\\\\/|/|g')
            if [ -n "$CWD" ] && command -v git >/dev/null 2>&1; then
              # `symbolic-ref`, not `rev-parse --abbrev-ref`: the second prints the
              # literal word HEAD both for a detached head and for a repository
              # whose first commit does not exist yet, which would put the word
              # "HEAD" on the row in place of a perfectly good branch name.
              BRANCH=$(git -C "$CWD" symbolic-ref --short HEAD 2>/dev/null || true)
              # `--path-format=absolute` is load-bearing, not tidiness. Without it,
              # from a directory *below* the repository root, --git-dir comes back
              # absolute and --git-common-dir relative — so the comparison below
              # would call every subdirectory a worktree.
              PATHS=$(git -C "$CWD" rev-parse --path-format=absolute \\
                        --show-toplevel --git-dir --git-common-dir 2>/dev/null || true)
              if [ -n "$PATHS" ]; then
                TOP=$(printf '%s\\n' "$PATHS" | sed -n 1p)
                GDIR=$(printf '%s\\n' "$PATHS" | sed -n 2p)
                GCOMMON=$(printf '%s\\n' "$PATHS" | sed -n 3p)
                if [ "$GDIR" != "$GCOMMON" ]; then
                  # A linked worktree: named after the **main** repository, which is
                  # the name the person thinks in. A submodule has the two equal, so
                  # it stays unflagged.
                  REPO=$(basename "$(dirname "$GCOMMON")")
                  GIT_HEADERS+=(--header '\(AppConfig.worktreeHeader): true')
                else
                  REPO=$(basename "$TOP")
                fi
                [ -n "$REPO" ] && GIT_HEADERS+=(--header "\(AppConfig.repoHeader): $REPO")
              fi
              [ -n "$BRANCH" ] && GIT_HEADERS+=(--header "\(AppConfig.branchHeader): $BRANCH")
            fi
            ;;
        esac

        curl --silent --show-error --output /dev/null \\
             --connect-timeout \(connect) --max-time \(total) \\
             --request POST \\
             --header 'Content-Type: application/json' \\
             --header '\(AppConfig.harnessHeader): \(harness.rawValue)' \\
        \(entrypoint)\(origin)\(auth)     "${GIT_HEADERS[@]+"${GIT_HEADERS[@]}"}" \\
             --data-binary "$BODY" \\
             '\(target)' \\
             2>/dev/null || true

        exit 0

        """
    }
}
