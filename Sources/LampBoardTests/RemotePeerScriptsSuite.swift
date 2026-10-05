import LampBoardCore
import Foundation
import TestKit

/// A message into the box of a session on another machine (B3), run for real:
/// `python3` on a temporary home whose sessions folder names a box a listener
/// holds, the way Claude Code lays it out.
enum RemotePeerScriptsSuite {

    private static let session = "2f6153b6-0bd2-4458-a22c-ab24d7aca8cd"

    /// A home with this process as the "session": its pid, a key, and a socket
    /// a Python listener holds, writing down what it receives.
    private static func home() -> (URL, Process)? {
        // Under /tmp: a socket path must fit `sun_path`.
        let home = URL(fileURLWithPath: "/tmp/lbrp-\(UUID().uuidString.prefix(8))")
        let folder = home.appendingPathComponent(".claude/sessions")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let socket = home.appendingPathComponent("box.sock").path
        let meta: [String: Any] = ["pid": Int(pid), "sessionId": session, "peerProtocol": 1, "messagingSocketPath": socket,
                                   "procStart": "start-1"]
        try? JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("\(pid).json"))
        let key = folder.appendingPathComponent("\(pid).abc123.key")
        try? Data(#"{"peerToken":"tok_9f2c4e6a8b","procStart":"start-1"}"#.utf8).write(to: key)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        listener.arguments = ["python3", "-c", """
            import socket, sys
            s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
            open(sys.argv[2], "w").write("ready")
            c, _ = s.accept(); data = b""
            while True:
                chunk = c.recv(4096)
                if not chunk: break
                data += chunk
            c.close(); open(sys.argv[2], "wb").write(data)
            """, socket, home.appendingPathComponent("received").path]
        do { try listener.run() } catch { return nil }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: home.appendingPathComponent("received").path) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return (home, listener)
    }

    private static func run(_ payload: [String: Any], home: URL) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        input.fileHandleForWriting.write(Data(RemotePeerScripts.send(payloadBase64: data.base64EncodedString()).utf8))
        try? input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ((try? JSONSerialization.jsonObject(with: printed)) as? [String: Any]) ?? [:]
    }

    static let suite = TestSuite("A message into a node session's box", [

        TestCase("The two lines reach the box of that session, and nothing is said back") { t in
            guard let (home, listener) = home() else { return t.fail("no listener") }
            defer { listener.terminate(); try? FileManager.default.removeItem(at: home) }
            guard let payload = RemotePeerScripts.payload(session: session, content: PeerBox.preamble + "\nrun the tests") else {
                return t.fail("no payload")
            }
            let result = run(payload, home: home)
            t.expectEqual(result["ok"] as? Bool, true, "\(result)")
            listener.waitUntilExit()
            let lines = (try? String(contentsOf: home.appendingPathComponent("received"), encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
            t.expectEqual(lines.count, 2)
            t.expect(lines.first?.contains(#""token": "tok_9f2c4e6a8b""#) == true, "the key first")
            t.expect(lines.last?.contains(#""from": "lampboard""#) == true, "from the panel")
            t.expect(lines.last?.contains("run the tests") == true, "the words")
        },

        TestCase("Another session's id, a key others can read, or no box: nothing sent, and said") { t in
            guard let (home, listener) = home() else { return t.fail("no listener") }
            defer { listener.terminate(); try? FileManager.default.removeItem(at: home) }
            let other = run(RemotePeerScripts.payload(session: "e5f6a7b8-0000-4000-8000-000000000002", content: "x") ?? [:], home: home)
            t.expectEqual(other["ok"] as? Bool, false)
            t.expect((other["reason"] as? String)?.contains("no box") == true, "\(other)")
            let pid = ProcessInfo.processInfo.processIdentifier
            let key = home.appendingPathComponent(".claude/sessions/\(pid).abc123.key")
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
            let open = run(RemotePeerScripts.payload(session: session, content: "x") ?? [:], home: home)
            t.expectEqual(open["ok"] as? Bool, false, "a key anyone can read is not the session's")
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
            let meta = home.appendingPathComponent(".claude/sessions/\(pid).json")
            try? JSONSerialization.data(withJSONObject: ["pid": Int(pid), "sessionId": session, "peerProtocol": 1,
                                                         "messagingSocketPath": home.appendingPathComponent("box.sock").path])
                .write(to: meta)
            try? Data(#"{"peerToken":"tok_9f2c4e6a8b"}"#.utf8).write(to: key)
            let unstarted = run(RemotePeerScripts.payload(session: session, content: "x") ?? [:], home: home)
            t.expectEqual(unstarted["ok"] as? Bool, false, "no start time on either side: not known to be that process")
            t.expectNil(RemotePeerScripts.payload(session: "not a session", content: "x"), "a session id of the wrong shape")
            t.expectNil(RemotePeerScripts.payload(session: session, content: ""), "nothing to send")
        },
    ])
}
