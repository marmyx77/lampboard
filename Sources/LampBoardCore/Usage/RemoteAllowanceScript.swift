import Foundation

/// The Python that reads another machine's allowance, run there over ssh.
///
/// WHY THE REQUEST IS MADE ON THE FAR SIDE
/// The obvious shape is to fetch that machine's token and ask from here. It is the
/// wrong one. A token pulled back over ssh exists in two places instead of one, in
/// this app's memory and in whatever ssh buffered, for a figure that is decoration.
/// Asking there costs nothing extra — the node already has the credential and a
/// network — and what crosses the wire is the answer, which is three percentages.
///
/// The script never reads the refresh token, for the same reason the Mac's reader
/// does not: spending it could rotate the pair and sign that machine out of Claude
/// Code. It reads `accessToken` and nothing else in the file.
///
/// **On Linux the credential is a file**, `~/.claude/.credentials.json` at mode
/// 0600, not a keychain — measured on the node this was written against, where
/// gnome-keyring is installed and Claude Code does not use it. The macOS branch is
/// here anyway, for a node that is itself a Mac.
public enum RemoteAllowanceScript {

    /// Where the figures come from. The same address the local reader asks, named
    /// once so the two can never drift apart.
    public static let endpoint = "https://api.anthropic.com/api/oauth/usage"

    /// Answers with `{"account": {...}, "limits": {...}}`, or `{"error": "…"}`.
    ///
    /// Never exits non-zero for an ordinary absence — a node that is signed out, or
    /// whose token has aged out, is not a fault to report to anybody. It says so in
    /// the object and the panel keeps quiet about that machine.
    public static var script: String {
        """
        import json, os, subprocess, sys

        def out(obj):
            sys.stdout.write(json.dumps(obj))
            sys.exit(0)

        home = os.path.expanduser("~")

        # The identity. Free to read and never secret: the token is needed for the
        # figures, never for the name.
        account = None
        try:
            with open(os.path.join(home, ".claude.json")) as handle:
                config = json.load(handle)
            oauth = config.get("oauthAccount") or {}
            cached = (config.get("cachedUsageUtilization") or {}).get("accountUuid")
            account = {
                "email": oauth.get("emailAddress"),
                "uuid": oauth.get("accountUuid") or cached,
            }
        except Exception:
            pass

        # The credential. A file on Linux; on a Mac node, the login keychain.
        token = None
        try:
            with open(os.path.join(home, ".claude", ".credentials.json")) as handle:
                blob = json.load(handle)
            token = (blob.get("claudeAiOauth") or blob).get("accessToken")
        except Exception:
            pass
        if not token and sys.platform == "darwin":
            try:
                raw = subprocess.run(
                    ["security", "find-generic-password", "-s", "Claude Code-credentials",
                     "-a", os.environ.get("USER", ""), "-w"],
                    capture_output=True, text=True, timeout=5,
                ).stdout.strip()
                token = (json.loads(raw).get("claudeAiOauth") or {}).get("accessToken")
            except Exception:
                pass

        if not token:
            out({"account": account, "error": "not signed in"})

        # curl rather than urllib: it is already required for the hook script, so a
        # node that can run the hooks can run this, and one that cannot says so in
        # a way the installer already knows how to report.
        try:
            answer = subprocess.run(
                ["curl", "--silent", "--show-error", "--max-time", "8",
                 "--header", "Authorization: Bearer " + token,
                 "--header", "Content-Type: application/json",
                 "--write-out", "\\n%{http_code}", "\(endpoint)"],
                capture_output=True, text=True, timeout=12,
            ).stdout
        except Exception as error:
            out({"account": account, "error": "could not ask: %s" % error})

        body, _, status = answer.rpartition("\\n")
        if status.strip() != "200":
            # An aged-out token is the expected ending, not a fault: only Claude
            # Code over there can replace it, and it will.
            out({"account": account, "error": "answered %s" % status.strip()})

        try:
            out({"account": account, "limits": json.loads(body)})
        except Exception:
            out({"account": account, "error": "the answer could not be read"})
        """
    }
}
