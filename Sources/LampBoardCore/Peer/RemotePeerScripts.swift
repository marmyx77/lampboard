import Foundation

/// A message into the box of a session on another machine (the bridge, B3):
/// `@name message` and `@name ?question` for a row that came through a tunnel.
/// The box is that machine's, so the script that writes to it runs there, over
/// ssh, in the shape of `RemoteInstallScripts`: the content travels inside the
/// Python as one base64 literal, no shell touches it.
///
/// It takes a box on the same terms `PeerSender` does on this Mac: the session
/// file named after its pid, a regular file of the user's and not a link; the
/// process running, the user's, and started when the file says; the key a
/// private regular file written for that process; the socket the user's.
public enum RemotePeerScripts {

    /// The content is what goes into the box as it is: the panel's preamble and
    /// the words for a message (`PeerBox`), the provable line and the question
    /// for a side question (`PeerAsk`). The answer to a question comes back
    /// through the tunnel, as the node's reports do (D83).
    public static func payload(session: String, content: String) -> [String: Any]? {
        guard ModReport.isSessionId(session), !content.isEmpty, content.utf8.count <= PeerBox.maxBytes else { return nil }
        return ["session": session, "content": content, "from": PeerBox.sender]
    }

    public static func send(payloadBase64: String) -> String {
        """
        import base64, glob, json, os, socket, stat, sys

        payload = json.loads(base64.b64decode("\(payloadBase64)").decode("utf-8"))
        folder = os.path.expanduser("~/.claude/sessions")

        def done(ok, reason=None):
            json.dump({"ok": ok, "reason": reason}, sys.stdout)
            sys.exit(0)

        def own(path, private):
            try:
                info = os.lstat(path)
            except Exception:
                return False
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 65536:
                return False
            return not private or (info.st_mode & 0o077) == 0

        def alive(pid, proc_start):
            try:
                os.kill(pid, 0)
            except Exception:
                return False
            if proc_start:
                try:
                    with open("/proc/%d/stat" % pid) as f:
                        if f.read().rsplit(")", 1)[1].split()[19] != str(proc_start):
                            return False
                except FileNotFoundError:
                    pass
                except Exception:
                    return False
            return True

        for path in glob.glob(os.path.join(folder, "*.json")):
            if not own(path, False):
                continue
            try:
                meta = json.load(open(path))
                pid = int(meta["pid"])
            except Exception:
                continue
            if meta.get("sessionId") != payload["session"] or meta.get("peerProtocol") != 1:
                continue
            if os.path.basename(path) != "%d.json" % pid or not alive(pid, meta.get("procStart")):
                continue
            keys = [k for k in glob.glob(os.path.join(folder, "%d.*.key" % pid)) if own(k, True)]
            if not keys:
                continue
            try:
                key = json.load(open(keys[0]))
            except Exception:
                continue
            # Written for that very process, as on the Mac: no start time, no box.
            if not meta.get("procStart") or key.get("procStart") != meta["procStart"] or not isinstance(key.get("peerToken"), str):
                continue
            path = meta.get("messagingSocketPath")
            try:
                info = os.lstat(path)
            except Exception:
                continue
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                continue
            box = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            box.settimeout(3)
            try:
                box.connect(path)
                box.sendall((json.dumps({"type": "auth", "token": key["peerToken"]}) + "\\n").encode("utf-8"))
                box.sendall((json.dumps({"type": "user", "from": payload["from"], "priority": "next",
                                         "message": {"role": "user", "content": payload["content"]}}) + "\\n").encode("utf-8"))
                box.shutdown(socket.SHUT_WR)
                # The box says nothing back; a box slow to close has the message
                # all the same, and saying "not sent" would make a second one.
                try:
                    while box.recv(256):
                        pass
                except socket.timeout:
                    pass
            except Exception as e:
                done(False, "the session's box did not take it: %s" % e)
            finally:
                box.close()
            done(True)
        done(False, "no box for that session there (Claude Code 2.1.224 or later)")
        """
    }
}
