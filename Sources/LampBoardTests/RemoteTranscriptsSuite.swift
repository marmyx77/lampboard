import Foundation
import LampBoardCore
import TestKit

/// Another machine's transcripts for ⌘K (M7): listed and read under
/// `~/.claude/projects` only, a link refused, the listing read back.
enum RemoteTranscriptsSuite {

    private static func sh(_ script: String, home: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static let id = "0f1e2d3c-4b5a-4968-8776-655443322110"

    private static func home() -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lb-node-\(UUID().uuidString)").path
        let folder = home + "/.claude/projects/-home-x-atlas"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? "{\"a\":1}\n{\"b\":2}\n".write(toFile: folder + "/\(id).jsonl", atomically: true, encoding: .utf8)
        try? "not a transcript".write(toFile: folder + "/notes.jsonl", atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(atPath: folder + "/11111111-2222-4333-8444-555555555555.jsonl",
                                                    withDestinationPath: "/etc/hosts")
        return home
    }

    static let suite = TestSuite("Another machine's transcripts", [

        TestCase("The listing names each transcript with its size and time, and nothing that is not one") { t in
            let home = home()
            defer { try? FileManager.default.removeItem(atPath: home) }
            let files = RemoteTranscripts.parse(sh(RemoteTranscripts.list(), home: home))
            t.expectEqual(files.map(\.path), ["./-home-x-atlas/\(id).jsonl"], "the link and the odd name left out")
            t.expectEqual(files.first?.size, 16)
            t.expectEqual(files.first?.sessionId, id)
        },

        TestCase("A project's own listing has every transcript of its folder, and nothing of another folder or a link") { t in
            let home = home()
            defer { try? FileManager.default.removeItem(atPath: home) }
            let web = home + "/.claude/projects/-srv-dev-web", other = home + "/.claude/projects/-srv-dev-other"
            for folder in [web, other] { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            try? "{}\n".write(toFile: web + "/\(id).jsonl", atomically: true, encoding: .utf8)
            try? "{}\n".write(toFile: other + "/22222222-3333-4444-8555-666666666666.jsonl", atomically: true, encoding: .utf8)
            try? FileManager.default.createSymbolicLink(atPath: web + "/11111111-2222-4333-8444-555555555555.jsonl",
                                                        withDestinationPath: "/etc/hosts")
            let files = RemoteTranscripts.parse(sh(RemoteTranscripts.list(folder: "/srv/dev/web"), home: home))
            t.expectEqual(files.map(\.path), ["./-srv-dev-web/\(id).jsonl"], "its folder only, the link left out")
            t.expect(!RemoteTranscripts.list(folder: "/srv/dev/web").contains("head"), "no cap: a project's every conversation")
            t.expectEqual(RemoteTranscripts.parse(sh(RemoteTranscripts.list(folder: "/srv/dev/none"), home: home)), [], "no folder, no transcript")
        },

        TestCase("Only the new bytes are read, and never through a link or out of the projects") { t in
            let home = home()
            defer { try? FileManager.default.removeItem(atPath: home) }
            let path = "./-home-x-atlas/\(id).jsonl"
            t.expectEqual(sh(RemoteTranscripts.read(path: path, from: 8, limit: 100)!, home: home), "{\"b\":2}\n")
            t.expectEqual(sh(RemoteTranscripts.read(path: path, from: 0, limit: 4)!, home: home), "{\"a\"")
            let link = "./-home-x-atlas/11111111-2222-4333-8444-555555555555.jsonl"
            t.expectEqual(sh(RemoteTranscripts.read(path: link, from: 0, limit: 100)!, home: home), "", "a link is not read")
            for bad in ["../etc/passwd", "./../x/\(id).jsonl", "./a/b/\(id).jsonl", "/etc/\(id).jsonl", "./a/notes.jsonl"] {
                t.expectNil(RemoteTranscripts.read(path: bad, from: 0, limit: 10), bad)
            }
            t.expectEqual(RemoteTranscripts.key(host: "bestia", path: path), "ssh://bestia/\(path)")
        },
    ])
}
