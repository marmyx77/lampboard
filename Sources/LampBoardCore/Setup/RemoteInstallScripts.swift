import Foundation

/// The scripts that run **on** another machine: to inspect it, to install or
/// remove the hooks, to make room for the tunnel, to ask where the tunnel was
/// bound and whether it answers.
///
/// In Core, in one piece and under test, for the reason the probe is: a promise
/// made to another machine has to be readable in one place. Nothing else is
/// installed there — `python3 -` reads each script from stdin and the process
/// dies with the connection.
///
/// **No shell touches the data.** The merged settings and the hook script travel
/// *inside* the Python source as one base64 literal: no quoting rule of any shell
/// is involved, so no content of `settings.json` — however hostile — can change
/// what the script does.
///
/// **`~/.lampboard` there is checked before it is trusted.** Claude Code runs the
/// hook through a shell, so a writable `hook.sh` is code execution at every hook;
/// the directory must be the user's own, not a symlink, not somebody else's —
/// the same rule `Mailbox` applies here.
public enum RemoteInstallScripts {

    /// The Python that refuses a `~/.lampboard` that is not the user's own
    /// directory, and creates it owner-only when absent. Shared by the scripts.
    static let directoryGuard = """
    import os, stat

    def own_directory(path):
        # Returns None when the directory is safe to use, else the reason it is not.
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            os.mkdir(path, 0o700)
            return None
        if stat.S_ISLNK(info.st_mode):
            return "is a symlink"
        if not stat.S_ISDIR(info.st_mode):
            return "is not a directory"
        if info.st_uid != os.getuid():
            return "belongs to another user"
        return None
    """

    /// Reports what the machine has: its home, Claude Code's settings (`null` if
    /// unreadable, `{}` if absent) with the sha256 and mode of the file as read,
    /// the text of our hook script there (`null` when absent), the Python
    /// version, whether `curl` exists — the hook script needs it — and whether
    /// `~/.lampboard` can be trusted.
    ///
    /// The script's text comes back so the token can be judged **here**, by the
    /// same rule the local installer applies (`HookRepair`): the node knows
    /// nothing about tokens and is not told one for the sake of a comparison.
    public static let inspect = directoryGuard + "\n" + """

    import hashlib, json, platform, re, shutil, subprocess, sys

    home = os.path.expanduser("~")
    settings_path = os.path.join(home, "\(AppConfig.remoteClaudeSettingsRelativePath)")

    # Which Claude Code is over there, the same two ways the Mac reads its own:
    # the native installer's link names the version, else `claude --version`
    # with a deadline. None when neither answers, which the Mac takes as current.
    def claude_version():
        try:
            name = os.path.basename(os.path.realpath(os.path.join(home, ".local/bin/claude")))
            if re.fullmatch(r"\\d+\\.\\d+\\.\\d+", name):
                return name
        except Exception:
            pass
        try:
            env = dict(os.environ)
            env["PATH"] = os.path.join(home, ".local/bin") + ":" + env.get("PATH", "")
            words = subprocess.run(["claude", "--version"], capture_output=True, text=True,
                                   timeout=3, env=env).stdout.split()
            if words and re.fullmatch(r"\\d+\\.\\d+\\.\\d+", words[0]):
                return words[0]
        except Exception:
            pass
        return None
    def read_text(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return f.read()
        except Exception:
            return None
    hook_script = read_text(os.path.join(home, "\(AppConfig.remoteHookScriptRelativePath)"))
    legacy_hook_script = read_text(os.path.join(home, "\(AppConfig.legacyRemoteHookScriptRelativePath)"))
    settings, error, digest, mode = None, None, None, None
    try:
        with open(settings_path, "rb") as f:
            raw = f.read()
        digest = hashlib.sha256(raw).hexdigest()
        mode = stat.S_IMODE(os.stat(settings_path).st_mode)
        settings = json.loads(raw.decode("utf-8"))
        if not isinstance(settings, dict):
            settings, error = None, "not a JSON object"
    except FileNotFoundError:
        settings = {}
    except Exception as e:
        error = str(e)

    json.dump({
        "home": home,
        "uid": os.getuid(),
        "settings": settings,
        "settingsSha256": digest,
        "settingsMode": mode,
        "hookScript": hook_script,
        "legacyHookScript": legacy_hook_script,
        "claudeVersion": claude_version(),
        "python": platform.python_version(),
        "curl": shutil.which("curl") is not None,
        "directoryProblem": own_directory(os.path.join(home, "\(directoryName)")),
        "error": error,
    }, sys.stdout)
    """

    /// Writes the hook script and the merged settings, or removes the script when
    /// asked — atomically, with a dated backup that keeps the settings' mode, and
    /// **only if the settings file is still the one that was merged**: Claude Code
    /// on that machine may write it between the two round trips, and a merge over
    /// a stale read would silently drop whatever it wrote.
    ///
    /// - Parameter payloadBase64: a JSON object with `scriptRelativePath`,
    ///   `settingsRelativePath`, `settings` (the whole merged file), `expectedSha256`
    ///   (of the bytes that were merged; `null` when the file did not exist), and
    ///   either `hookScript` (install) or `removeScript: true` (uninstall).
    public static func apply(payloadBase64: String) -> String {
        directoryGuard + "\n" + """

        import base64, hashlib, json, shutil, sys, time

        payload = json.loads(base64.b64decode("\(payloadBase64)").decode("utf-8"))
        home = os.path.expanduser("~")
        script_path = os.path.join(home, payload["scriptRelativePath"])
        settings_path = os.path.join(home, payload["settingsRelativePath"])

        problem = own_directory(os.path.dirname(script_path))
        if problem:
            json.dump({"ok": False, "reason": "%s %s" % (os.path.dirname(script_path), problem)}, sys.stdout)
            sys.exit(0)

        # Compare-and-swap on the settings: the file we are about to replace has
        # to be the file that was read and merged.
        current = None
        try:
            with open(settings_path, "rb") as f:
                current = hashlib.sha256(f.read()).hexdigest()
        except FileNotFoundError:
            pass
        if current != payload.get("expectedSha256"):
            json.dump({"ok": False, "reason": "settings.json changed since it was read; nothing was written"}, sys.stdout)
            sys.exit(0)

        if payload.get("hookScript") is not None:
            with open(script_path, "w") as f:
                f.write(payload["hookScript"])
            os.chmod(script_path, 0o755)
        elif payload.get("removeScript") and os.path.lexists(script_path):
            os.remove(script_path)

        backup = None
        mode = 0o600
        if os.path.exists(settings_path):
            mode = stat.S_IMODE(os.stat(settings_path).st_mode)
            backup = settings_path + ".bak-lampboard-" + time.strftime("%Y%m%d-%H%M%S")
            shutil.copy2(settings_path, backup)
        os.makedirs(os.path.dirname(settings_path), exist_ok=True)
        tmp = settings_path + ".tmp-lampboard"
        with open(tmp, "w") as f:
            json.dump(payload["settings"], f, indent=2, sort_keys=True)
            f.write("\\n")
        os.chmod(tmp, mode)
        os.replace(tmp, settings_path)

        json.dump({"ok": True, "backup": backup, "scriptPath": script_path}, sys.stdout)
        """
    }

    /// The Python that lists the local addresses bound on a TCP port, from
    /// `/proc/net/tcp` and `/proc/net/tcp6` — the only place the answer is a fact.
    static let boundAddresses = """
    def bound_addresses(port):
        found = []
        for table in ("/proc/net/tcp", "/proc/net/tcp6"):
            try:
                with open(table) as f:
                    next(f)
                    for line in f:
                        fields = line.split()
                        local, state = fields[1], fields[3]
                        if state != "0A":
                            continue
                        addr, hexport = local.rsplit(":", 1)
                        if int(hexport, 16) != port:
                            continue
                        if len(addr) == 8:
                            octets = [str(int(addr[i:i+2], 16)) for i in (6, 4, 2, 0)]
                            found.append(".".join(octets))
                        else:
                            found.append("::1" if addr.endswith("01000000") and set(addr[:-8]) <= {"0"} else "[" + addr + "]")
            except Exception:
                pass
        return found
    """

    /// Before the tunnel connects: the user's own directory must exist (the hook
    /// script lives there), and the port the forward will ask for must be free —
    /// a port already bound is another tunnel, a ghost of the last one, or a
    /// stranger, and binding over it would fail after the fact instead of before.
    /// Reports the uid, from which the port is derived on both sides.
    // Swift's multi-line literals end without a newline: every join says it.
    public static let prepareTunnel = directoryGuard + "\n" + boundAddresses + "\n" + """

    import json, sys

    home = os.path.expanduser("~")
    uid = os.getuid()
    port = \(portFormula)
    problem = own_directory(os.path.join(home, "\(directoryName)"))
    json.dump({"home": home, "uid": uid, "port": port, "problem": problem,
               "bound": bound_addresses(port)}, sys.stdout)
    """

    /// After the tunnel connects, and on every check: **where** the forward was
    /// bound — loopback only, or an address the machine's ssh server chose on its
    /// own — and whether it answers with HTTP. Asked *from* the node, because that
    /// is the only place the question means anything: the client's `-R 127.0.0.1`
    /// is a request, and this is the answer.
    public static func checkTunnel(port: UInt16) -> String {
        boundAddresses + "\n" + """

        import json, sys, urllib.request, urllib.error

        status = None
        try:
            urllib.request.urlopen("http://127.0.0.1:\(port)\(AppConfig.signalPath)", timeout=3)
            status = 200
        except urllib.error.HTTPError as e:
            status = e.code
        except Exception as e:
            status = "unreachable: %s" % e
        json.dump({"status": status, "bound": bound_addresses(\(port))}, sys.stdout)
        """
    }

    /// The port, as Python computes it there: kept textually identical to
    /// `AppConfig.remotePort(forUID:)` so both sides agree without a round trip.
    private static let portFormula = "30000 + max(uid, 0) % 20000"

    private static var directoryName: String {
        String(AppConfig.remoteHookScriptRelativePath.split(separator: "/").first ?? ".lampboard")
    }
}
