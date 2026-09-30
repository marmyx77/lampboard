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

    /// Answers with `{"account": {...}, "limits": {...}, "hosted": [...]}`, or
    /// `{"error": "…", "hosted": [...]}` when the machine's own sign-in is absent,
    /// plus `"throttled": true` whenever any ask was answered 429.
    ///
    /// Never exits non-zero for an ordinary absence — a node that is signed out, or
    /// whose token has aged out, is not a fault to report to anybody. It says so in
    /// the object and the panel keeps quiet about that machine.
    ///
    /// `hosted` holds the accounts Claude Code is running as without having signed
    /// in there — the Claude application's sessions, whose credential lives only in
    /// the environment of the processes (`HostedCredentials`). Each entry is
    /// `{"account": {...}, "limits": {...}}`; one that fails is left out. It is
    /// read even when the machine itself is signed out, which is exactly the node
    /// the application alone works on.
    ///
    /// ONE ANSWER PER ACCOUNT
    /// `skipping` names the accounts the caller already has figures for this
    /// round, and no account is asked about once an answer for it is in hand: the
    /// node's own sign-in is skipped when it is one of them, and so is a hosted
    /// token whose account has already answered. A token that was **refused** does
    /// not count as an answer, and the next token of the same account is tried —
    /// measured on 29 September 2026, the limit is kept per token: the node's own
    /// token, which its Claude Code sessions ask with too, was answered 429 while
    /// the application's token for the same account was answered 200. That needs the account of a token before its figures, so
    /// the answer of the profile endpoint is remembered on the node, keyed by a
    /// hash of the token — never the token — in `~/.cache/lampboard/accounts.json`.
    /// A skipped account is not an absence: the caller already has its figures.
    ///
    /// The token reaches curl on its standard input, never on its command line: an
    /// argument is readable by every user of the machine, an input is not.
    public static func script(skipping uuids: [String]) -> String {
        // Only the characters a uuid has: this list is pasted into the program.
        let safe = uuids.map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" } }.filter { !$0.isEmpty }
        let skipping = "[" + safe.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        return """
        import hashlib, json, os, re, subprocess, sys

        home = os.path.expanduser("~")
        asked = set(\(skipping))
        throttled = False

        def ask(token, url):
            # curl rather than urllib: it is already required for the hook script,
            # so a node that can run the hooks can run this.
            global throttled
            try:
                answer = subprocess.run(
                    ["curl", "--silent", "--show-error", "--max-time", "8",
                     "--header", "@-", "--header", "Content-Type: application/json",
                     "--write-out", "\\n%{http_code}", url],
                    input="Authorization: Bearer " + token + "\\n",
                    capture_output=True, text=True, timeout=12,
                ).stdout
            except Exception as error:
                return None, "could not ask: %s" % error
            body, _, status = answer.rpartition("\\n")
            if status.strip() == "429":
                throttled = True
            if status.strip() != "200":
                return None, "answered %s" % status.strip()
            try:
                return json.loads(body), None
            except Exception:
                return None, "the answer could not be read"

        def hosted_tokens():
            # The accounts the Claude application runs Claude Code as. Only this
            # user's processes, and only Claude Code's: the entrypoint variable is
            # set by Claude Code and inherited by what it starts.
            found = []
            def keep(token):
                if token and token not in found and len(found) < \(HostedCredentials.maximumAccounts):
                    found.append(token)
            if os.path.isdir("/proc"):
                uid = os.getuid()
                for pid in os.listdir("/proc"):
                    if not pid.isdigit():
                        continue
                    try:
                        if os.stat("/proc/" + pid).st_uid != uid:
                            continue
                        with open("/proc/%s/environ" % pid, "rb") as handle:
                            raw = handle.read()
                    except Exception:
                        continue
                    env = {}
                    for item in raw.split(b"\\0"):
                        key, sep, value = item.partition(b"=")
                        if sep:
                            env[key] = value
                    if b"\(HostedCredentials.entrypointVariable)" in env:
                        keep(env.get(b"\(HostedCredentials.tokenVariable)", b"").decode("ascii", "ignore"))
            elif sys.platform == "darwin":
                try:
                    listing = subprocess.run(["ps", "-Eww", "-axo", "command="],
                                             capture_output=True, text=True, timeout=5).stdout
                except Exception:
                    listing = ""
                for line in listing.splitlines():
                    if "\(HostedCredentials.entrypointVariable)=" not in line:
                        continue
                    match = re.search(r"(?:^|\\s)\(HostedCredentials.tokenVariable)=(sk-ant-[A-Za-z0-9_-]+)", line)
                    if match:
                        keep(match.group(1))
            return found

        cache_path = os.path.join(home, ".cache", "lampboard", "accounts.json")

        def load_cache():
            try:
                with open(cache_path) as handle:
                    return json.load(handle)
            except Exception:
                return {}

        def save_cache(entries):
            # Only the tokens still running are remembered, so the file never grows.
            try:
                os.makedirs(os.path.dirname(cache_path), mode=0o700, exist_ok=True)
                temporary = cache_path + ".tmp"
                with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
                    json.dump(entries, handle)
                os.replace(temporary, cache_path)
            except Exception:
                pass

        known = load_cache()
        current = {}

        def whose(token):
            # Asked of the token, never read from ~/.claude.json: that file names
            # the last sign-in, which need not be the one that wrote the token.
            key = hashlib.sha256(token.encode()).hexdigest()[:32]
            named = known.get(key)
            if not named:
                profile, _ = ask(token, "\(HostedCredentials.profileEndpoint)")
                account = (profile or {}).get("account") or {}
                named = {"email": account.get("email"), "uuid": account.get("uuid")}
            if named.get("uuid") or named.get("email"):
                current[key] = named
            return named

        def hosted():
            reports = []
            for token in hosted_tokens():
                named = whose(token)
                uuid = named.get("uuid")
                if uuid and uuid in asked:
                    continue
                limits, _ = ask(token, "\(endpoint)")
                if limits is None:
                    continue
                if uuid:
                    asked.add(uuid)
                reports.append({"account": named, "limits": limits})
            return reports

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

        account = whose(token) if token else None
        result = {"account": account}
        own = (account or {}).get("uuid")
        if not token:
            result["error"] = "not signed in"
        elif own and own in asked:
            # Already asked by the caller this round: its figures are in hand.
            result["skipped"] = True
        else:
            limits, error = ask(token, "\(endpoint)")
            if own and limits is not None:
                asked.add(own)
            if limits is None:
                # An aged-out token is the expected ending, not a fault: only
                # Claude Code over there can replace it, and it will.
                result["error"] = error
            else:
                result["limits"] = limits
        result["hosted"] = hosted()
        if current != known:
            save_cache(current)
        if throttled:
            result["throttled"] = True
        sys.stdout.write(json.dumps(result))
        """
    }

    /// The script with nothing to skip.
    public static var script: String { script(skipping: []) }

    /// Every account a node's answer describes: its own sign-in first, then the
    /// hosted ones. What cannot be read is left out, never guessed.
    public static func reports(in object: [String: Any], host: String, readAt: Date = Date()) -> [AllowanceReport] {
        var found: [AllowanceReport] = []
        if let report = report(from: object, host: host, readAt: readAt) {
            found.append(report)
        }
        for entry in (object["hosted"] as? [[String: Any]]) ?? [] {
            if let report = report(from: entry, host: host, readAt: readAt) {
                found.append(report)
            }
        }
        return found
    }

    private static func report(from object: [String: Any], host: String, readAt: Date) -> AllowanceReport? {
        guard let payload = object["limits"],
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let limits = AccountLimits.decode(data, readAt: readAt), !limits.limits.isEmpty
        else { return nil }
        var account: ClaudeAccount?
        if let named = object["account"] as? [String: Any] {
            let email = (named["email"] as? String)?.trimmed.nilIfEmpty
            let uuid = (named["uuid"] as? String)?.trimmed.nilIfEmpty
            if email != nil || uuid != nil { account = ClaudeAccount(email: email, uuid: uuid) }
        }
        return AllowanceReport(account: account, machine: host, limits: limits)
    }
}
