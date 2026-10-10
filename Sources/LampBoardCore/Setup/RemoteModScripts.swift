import Foundation

/// The companion mod on another machine (the bridge, B1): its files, the three
/// it reads in `~/.lampboard` there — the token and the port of the tunnel that
/// lands on this Mac's panel, and the permission key (D80) — and Claude Code's
/// own `claude plugin` there to install it.
///
/// One script, in the shape of `RemoteInstallScripts`: the data travels inside
/// the Python source as one base64 literal, no shell touches it, `~/.lampboard`
/// is checked before it is trusted, and every file is written owner-only through
/// a fresh name that cannot be a link. The files it writes are marked as the
/// tunnel's (`tunnel-mod`): a `~/.lampboard` with a token or a port and no mark
/// is a LampBoard panel's own, on a machine that runs one, and the script
/// refuses rather than point that machine's sessions at this Mac.
///
/// Measured on the test VM (B0, 5 October 2026): with these three files there
/// and the mod loaded, a session's reports and its permission asks came through
/// the tunnel to the panel, and the panel's `deny` held there.
public enum RemoteModScripts {

    /// Where the mod's files go there, under the home.
    public static let folderRelativePath = ".lampboard/mod-marketplace"

    /// The payload, as JSON: the files, the three values, the steps.
    public static func payload(token: String, port: UInt16, checkKey: String, panelKey: String? = nil) -> [String: Any] {
        [
            // The panel's public key (D152): the mod there checks the Hub's commands with it.
            "panelKey": panelKey ?? "",
            "files": ModFiles.all.map { ["path": $0.path, "content": $0.content] },
            "token": token,
            "port": String(port),
            "checkKey": checkKey,
            "installSteps": ModRegistration.installSteps(folder: folderToken),
            "uninstallSteps": ModRegistration.uninstallSteps,
        ]
    }

    /// The payload that takes it out again, and the three files with it.
    public static func removal(port: UInt16) -> [String: Any] {
        ["uninstall": true, "port": String(port), "uninstallSteps": ModRegistration.uninstallSteps]
    }

    /// Stands for the folder in the steps: its path is the other machine's.
    static let folderToken = "{folder}"

    public static func script(payloadBase64: String) -> String {
        RemoteInstallScripts.directoryGuard + "\n" + """

        import base64, json, shutil, subprocess, sys, time

        # One deadline for the whole run, inside the one the Mac gives ssh: a run
        # cut halfway would leave the key there with no mod.
        deadline = time.time() + 100

        payload = json.loads(base64.b64decode("\(payloadBase64)").decode("utf-8"))
        home = os.path.expanduser("~")
        base = os.path.join(home, ".lampboard")
        folder = os.path.join(home, "\(folderRelativePath)")

        def done(ok, reason=None):
            json.dump({"ok": ok, "reason": reason}, sys.stdout)
            sys.exit(0)

        problem = own_directory(base)
        if problem:
            done(False, "~/.lampboard there %s; nothing was changed" % problem)

        def read(name):
            try:
                with open(os.path.join(base, name), "r") as f:
                    return f.read().strip()
            except Exception:
                return None

        # A token or a port that this script did not write is a panel's own:
        # this machine runs LampBoard, and its sessions report to it, not here.
        ours = os.path.lexists(os.path.join(base, "tunnel-mod"))
        if not ours and (read("port") is not None or read("token") is not None):
            done(False, "this machine runs a LampBoard panel of its own; its mod reports to it")

        def forget():
            for name in ("token", "port", "check-key", "panel-key.pub", "tunnel-mod"):
                if os.path.lexists(os.path.join(base, name)):
                    os.unlink(os.path.join(base, name))

        def private(path, text):
            tmp = path + ".tmp-lampboard"
            if os.path.lexists(tmp):
                os.unlink(tmp)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(text)
            os.replace(tmp, path)

        def claude():
            for path in (os.path.join(home, ".local/bin/claude"), shutil.which("claude")):
                if path and os.access(path, os.X_OK):
                    return path
            return None

        tool = claude()
        if tool is None:
            done(False, "Claude Code's claude command was not found there")

        def run(step):
            words = [folder if w == "\(folderToken)" else w for w in step]
            left = deadline - time.time()
            if left < 5:
                return False, "out of time"
            try:
                r = subprocess.run([tool] + words, capture_output=True, text=True, timeout=min(60, left), stdin=subprocess.DEVNULL)
                return r.returncode == 0, (r.stdout + r.stderr).strip()[-300:]
            except Exception as e:
                return False, str(e)

        def clear():
            for step in payload["uninstallSteps"]:
                run(step)
            if os.path.islink(folder):
                os.unlink(folder)
            elif os.path.isdir(folder):
                shutil.rmtree(folder)

        # From a clean slate, as on the Mac: a marketplace left declared makes `add` refuse.
        clear()
        if payload.get("uninstall"):
            if ours:
                forget()
            done(True)

        os.mkdir(folder, 0o700)
        for entry in payload["files"]:
            path = os.path.join(folder, entry["path"])
            os.makedirs(os.path.dirname(path), 0o700, exist_ok=True)
            private(path, entry["content"])
        private(os.path.join(base, "tunnel-mod"), "written by LampBoard on the Mac this machine's tunnel reaches\\n")
        private(os.path.join(base, "token"), payload["token"])
        private(os.path.join(base, "port"), payload["port"] + "\\n")
        private(os.path.join(base, "check-key"), payload["checkKey"])
        if payload.get("panelKey"):
            private(os.path.join(base, "panel-key.pub"), payload["panelKey"] + "\\n")
        for step in payload["installSteps"]:
            ok, said = run(step)
            if not ok:
                clear()
                forget()
                done(False, "claude %s: %s" % (" ".join(step[:3]), said))
        done(True)
        """
    }
}
