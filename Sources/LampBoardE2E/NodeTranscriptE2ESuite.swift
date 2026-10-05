import LampBoardCore
import Foundation
import TestKit

/// The program a node runs for LampMaster's cards (D4), run here for real
/// with this Mac's `python3` in a fake home, as ssh would run it there.
enum NodeTranscriptE2ESuite {

    static func run(_ script: String, home: URL) -> [RemoteTranscriptScript.Read] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        guard (try? process.run()) != nil else { return [] }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RemoteTranscriptScript.decode(data, asked: ["a", "b", "c"])
    }

    static func suite() -> TestSuite {
        TestSuite("E2E · a node's transcripts", [

            TestCase("the tail first, then only what was added; a shrunk file read again; nothing outside the projects") { t in
                let home = FileManager.default.temporaryDirectory.appendingPathComponent("lb-node-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: home) }
                let folder = home.appendingPathComponent(".claude/projects/-home-dev-api")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("aaaaaaaa-0000-4000-8000-000000000001.jsonl")
                try? Data(repeating: 0x61, count: 1_000).write(to: file)
                // Real paths: the program compares them with its own home's.
                let real = { (url: URL) in url.resolvingSymlinksInPath().path }
                let link = folder.appendingPathComponent("bbbbbbbb-0000-4000-8000-000000000002.jsonl")
                try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
                let outside = home.appendingPathComponent(".claude/elsewhere.jsonl")
                try? Data("secret".utf8).write(to: outside)

                let first = run(RemoteTranscriptScript.script([
                    .init(id: "a", path: real(file), offset: 0),
                    .init(id: "b", path: folder.resolvingSymlinksInPath().path + "/" + link.lastPathComponent, offset: 0),
                    .init(id: "c", path: real(home) + "/.claude/projects/../elsewhere.jsonl", offset: 0),
                ], tail: 300), home: home)
                t.expectEqual(first.map(\.id), ["a"], "a link and a path out of the projects are not read")
                t.expectEqual(first.first?.start, 700, "the tail")
                t.expectEqual(first.first?.data.count, 300)

                let handle = try? FileHandle(forWritingTo: file)
                _ = try? handle?.seekToEnd()
                handle?.write(Data(repeating: 0x62, count: 50))
                try? handle?.close()
                let next = run(RemoteTranscriptScript.script([.init(id: "a", path: real(file), offset: 1_000)], tail: 300), home: home)
                t.expectEqual(next.first?.start, 1_000, "from where it stopped")
                t.expectEqual(next.first?.data, Data(repeating: 0x62, count: 50), "only what was added")

                try? Data(repeating: 0x63, count: 100).write(to: file)
                let shrunk = run(RemoteTranscriptScript.script([.init(id: "a", path: real(file), offset: 1_050)], tail: 300), home: home)
                t.expectEqual(shrunk.first?.start, 0, "a file that shrank is read again")
                t.expectEqual(shrunk.first?.size, 100)
            },
        ])
    }
}
