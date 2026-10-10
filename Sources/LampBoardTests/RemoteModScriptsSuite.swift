import LampBoardCore
import Foundation
import TestKit

/// The companion mod put on another machine (the bridge, B1), run for real:
/// `python3` on a temporary home with a `claude` that only writes down how it
/// was called.
enum RemoteModScriptsSuite {

    private static let token = String(repeating: "a1", count: 24)
    private static let key = String(repeating: "c3", count: 32)

    /// A fresh home with a fake `claude` in `~/.local/bin`.
    private static func home() -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lb-remote-mod-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        try? "#!/bin/sh\necho \"$*\" >> \"$HOME/claude-calls\"\n".write(to: claude, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return home
    }

    /// Runs the script with that home, and returns what it printed.
    private static func run(_ payload: [String: Any], home: URL) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        input.fileHandleForWriting.write(Data(RemoteModScripts.script(payloadBase64: data.base64EncodedString()).utf8))
        try? input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ((try? JSONSerialization.jsonObject(with: printed)) as? [String: Any]) ?? [:]
    }

    private static func text(_ home: URL, _ path: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)
    }

    private static func mode(_ home: URL, _ path: String) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(path).path))?[.posixPermissions] as? NSNumber)?.intValue
    }

    static let suite = TestSuite("The companion mod on another machine", [

        TestCase("Its files, the token, the tunnel's port and the key, owner-only; then claude plugin there") { t in
            let home = home()
            defer { try? FileManager.default.removeItem(at: home) }
            let result = run(RemoteModScripts.payload(token: token, port: 30503, checkKey: key), home: home)
            t.expectEqual(result["ok"] as? Bool, true, "\(result)")
            for file in ModFiles.all {
                t.expectEqual(text(home, ".lampboard/mod-marketplace/" + file.path), file.content, file.path)
                t.expectEqual(mode(home, ".lampboard/mod-marketplace/" + file.path), 0o600, "\(file.path) owner-only")
            }
            t.expectEqual(text(home, ".lampboard/token"), token)
            t.expectEqual(text(home, ".lampboard/port"), "30503\n")
            t.expectEqual(text(home, ".lampboard/check-key"), key)
            t.expectEqual(mode(home, ".lampboard/check-key"), 0o600, "the key owner-only")
            t.expect(text(home, ".lampboard/tunnel-mod") != nil, "marked as the tunnel's")
            let again = run(RemoteModScripts.payload(token: token, port: 30503, checkKey: key), home: home)
            t.expectEqual(again["ok"] as? Bool, true, "its own files are its to rewrite")
            let calls = (text(home, "claude-calls") ?? "").split(separator: "\n").map(String.init)
            t.expectEqual(calls.suffix(2), ["plugin marketplace add \(home.path)/.lampboard/mod-marketplace",
                                            "plugin install lampboard@lampboard --scope user"])
            t.expectEqual(calls.first, "plugin uninstall lampboard@lampboard --scope user", "from a clean slate")
        },

        TestCase("The panel's public key goes with them, for the Hub's commands, and goes when they go (D152)") { t in
            let home = home()
            defer { try? FileManager.default.removeItem(at: home) }
            let pub = String(repeating: "ab", count: 32)
            let result = run(RemoteModScripts.payload(token: token, port: 30503, checkKey: key, panelKey: pub), home: home)
            t.expectEqual(result["ok"] as? Bool, true, "\(result)")
            t.expectEqual(text(home, ".lampboard/panel-key.pub"), pub + "\n")
            _ = run(RemoteModScripts.removal(port: 30503), home: home)
            t.expectNil(text(home, ".lampboard/panel-key.pub"), "removed with the helper")
        },

        TestCase("A machine with a panel of its own is left alone") { t in
            let home = home()
            defer { try? FileManager.default.removeItem(at: home) }
            try? FileManager.default.createDirectory(at: home.appendingPathComponent(".lampboard"), withIntermediateDirectories: true)
            try? "30503\n".write(to: home.appendingPathComponent(".lampboard/port"), atomically: true, encoding: .utf8)
            let result = run(RemoteModScripts.payload(token: token, port: 30503, checkKey: key), home: home)
            t.expectEqual(result["ok"] as? Bool, false)
            t.expect((result["reason"] as? String)?.contains("panel of its own") == true, "\(result)")
            t.expectEqual(text(home, ".lampboard/port"), "30503\n", "its port untouched, even the same number")
            t.expectNil(text(home, "claude-calls"), "claude not run")
        },

        TestCase("A ~/.lampboard that is a link is refused, and nothing is written through it") { t in
            let home = home()
            let elsewhere = home.appendingPathComponent("elsewhere")
            defer { try? FileManager.default.removeItem(at: home) }
            try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".lampboard"), withDestinationURL: elsewhere)
            let result = run(RemoteModScripts.payload(token: token, port: 30503, checkKey: key), home: home)
            t.expectEqual(result["ok"] as? Bool, false)
            t.expectNil(text(home, "elsewhere/token"), "nothing through the link")
        },

        TestCase("A failed install leaves no key behind, and a ~/.lampboard others can write is refused") { t in
            let home = home()
            defer { try? FileManager.default.removeItem(at: home) }
            try? "#!/bin/sh\ncase \"$*\" in *install*) exit 1;; esac\n".write(
                to: home.appendingPathComponent(".local/bin/claude"), atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent(".local/bin/claude").path)
            let failed = run(RemoteModScripts.payload(token: token, port: 30503, checkKey: key), home: home)
            t.expectEqual(failed["ok"] as? Bool, false)
            t.expectNil(text(home, ".lampboard/check-key"), "the key taken back")
            try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: home.appendingPathComponent(".lampboard").path)
            let open = run(RemoteModScripts.payload(token: token, port: 30503, checkKey: key), home: home)
            t.expect((open["reason"] as? String)?.contains("written by other users") == true, "\(open)")
        },

        TestCase("Taken out, with the three files it read") { t in
            let home = home()
            defer { try? FileManager.default.removeItem(at: home) }
            _ = run(RemoteModScripts.payload(token: token, port: 30503, checkKey: key), home: home)
            let result = run(RemoteModScripts.removal(port: 30503), home: home)
            t.expectEqual(result["ok"] as? Bool, true, "\(result)")
            for name in ["token", "port", "check-key", "tunnel-mod", "mod-marketplace"] {
                t.expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".lampboard/" + name).path), "\(name) gone")
            }
            let calls = (text(home, "claude-calls") ?? "").split(separator: "\n").map(String.init)
            t.expectEqual(calls.suffix(2), ["plugin uninstall lampboard@lampboard --scope user", "plugin marketplace remove lampboard"])
        },
    ])
}
