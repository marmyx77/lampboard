import Foundation
import LampBoardCore
import TestKit

/// The Hub's look into a project (D156): confined to its folder, links out of it
/// refused, values quoted, git and the tools read as they are.
enum ProjectAccessSuite {

    /// Runs a script the way ssh would on the other machine, here with `/bin/sh`.
    private static func sh(_ script: String, input: Data? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let feed = Pipe()
        process.standardInput = feed
        guard (try? process.run()) != nil else { return (-1, "") }
        feed.fileHandleForWriting.write(input ?? Data())
        try? feed.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A project with the traps a hostile repository could hold.
    private static func project() -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lb-project-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try? "let a = 1\n".write(toFile: root + "/src/a.swift", atomically: true, encoding: .utf8)
        try? "it is quoted\n".write(toFile: root + "/it's.txt", atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(atPath: root + "/out", withDestinationPath: "/etc")
        try? FileManager.default.createSymbolicLink(atPath: root + "/hosts", withDestinationPath: "/etc/hosts")
        return root
    }

    static let suite = TestSuite("The Hub's look into a project", [

        TestCase("A path stays inside the project or is refused") { t in
            t.expectEqual(ProjectAccess.relative("src/a.swift"), "src/a.swift")
            t.expectEqual(ProjectAccess.relative("a b//c.md"), "a b/c.md")
            for bad in ["", "/etc/passwd", "../x", "src/../../x", "-rf", "a\nb", "./a", "a/./b"] {
                t.expectNil(ProjectAccess.relative(bad), bad)
            }
            t.expect(ProjectAccess.isInside("/p/x/y", root: "/p/x"), "a file inside")
            t.expect(!ProjectAccess.isInside("/p/xy", root: "/p/x"), "a sibling with the same prefix is outside")
        },

        TestCase("A file is code, Markdown or not text") { t in
            t.expectEqual(ProjectAccess.kind(of: "README.md"), .markdown)
            t.expectEqual(ProjectAccess.kind(of: "shot.PNG"), .binary)
            t.expectEqual(ProjectAccess.kind(of: "main.swift"), .code(language: "swift"))
            t.expectEqual(ProjectAccess.kind(of: "Makefile"), .code(language: "makefile"))
        },

        TestCase("git's short status is read by path, a rename by its new name") { t in
            let status = GitStatus.parse(" M src/a.ts\n?? new.txt\nA  b.ts\nR  old.ts -> renamed.ts\n D gone.ts\n")
            t.expectEqual(status, ["src/a.ts": "M", "new.txt": "?", "b.ts": "A", "renamed.ts": "R", "gone.ts": "D"])
        },

        TestCase("A file is read, written, then in the commit once git no longer calls it changed") { t in
            let tools: [(name: String, detail: String?)] = [
                ("Read", "/w/p/src/a.ts"), ("Grep", "src/b.ts"), ("Edit", "/w/p/src/a.ts"),
                ("Write", "/w/p/c.ts"), ("Bash", "git commit -m 'x'"), ("Read", "/w/elsewhere/z.ts"),
            ]
            let marks = FileMarks.marks(tools: tools, root: "/w/p", changed: ["c.ts"])
            t.expectEqual(marks["src/a.ts"], .committed)
            t.expectEqual(marks["src/b.ts"], .read)
            t.expectEqual(marks["c.ts"], .written, "still changed: not in the commit")
            t.expectNil(marks["z.ts"], "a file outside the project is not marked")
        },

        TestCase("On the other machine a folder and a file are read inside the project, and a link out is refused") { t in
            let root = project()
            defer { try? FileManager.default.removeItem(atPath: root) }
            guard let list = RemoteProject.list(root: root, relative: nil) else { return t.fail("no script") }
            let listed = sh(list).output.split(separator: "\n").map(String.init)
            t.expect(listed.contains("src/") && listed.contains("it's.txt"), "the folder's entries: \(listed)")
            t.expectEqual(sh(RemoteProject.list(root: root, relative: "out")!).status, 3, "a folder linked out is refused")
            t.expectEqual(sh(RemoteProject.read(root: root, relative: "src/a.swift")!).output, "let a = 1\n")
            t.expectEqual(sh(RemoteProject.read(root: root, relative: "it's.txt")!).output, "it is quoted\n", "a quote in a name")
            t.expectEqual(sh(RemoteProject.read(root: root, relative: "hosts")!).output, "", "a file linked out is not read")
            t.expectEqual(sh(RemoteProject.read(root: root, relative: "out/hosts")!).output, "", "nor one through a linked folder")
            t.expectNil(RemoteProject.read(root: root, relative: "../etc/hosts"))
        },

        TestCase("A search is a fixed string, quoted, and its hits are read back by path and line") { t in
            let root = project()
            defer { try? FileManager.default.removeItem(atPath: root) }
            guard let search = RemoteProject.search(root: root, query: "let a; rm -rf /") else { return t.fail("no script") }
            t.expect(search.contains("'let a; rm -rf /'"), "quoted whole")
            let hits = SearchHits.parse(sh(RemoteProject.search(root: root, query: "let a")!).output)
            t.expectEqual(hits, [SearchHits.Hit(path: "src/a.swift", line: 1, text: "let a = 1")])
            t.expectNil(RemoteProject.search(root: root, query: ""))
        },

        TestCase("The project's shell opens in its folder here, and through ssh with a terminal there") { t in
            let here = ProjectShell.command(root: "/w/p", host: nil, shell: "/bin/zsh", environment: [:])
            t.expectEqual(here.executable, "/bin/zsh")
            t.expectEqual(here.directory, "/w/p")
            let there = ProjectShell.command(root: "/srv/x/it's", host: "bestia", shell: "/bin/zsh", environment: [:])
            t.expectEqual(there.executable, "/usr/bin/ssh")
            t.expect(there.arguments.contains("-t"), "with a terminal")
            t.expect(there.arguments.last?.contains("cd -- '/srv/x/it'\\''s'") == true, "\(there.arguments)")
        },

        TestCase("An attachment goes into the project's folder for them, kept out of git, never through a link out") { t in
            let root = project()
            defer { try? FileManager.default.removeItem(atPath: root) }
            try? FileManager.default.createDirectory(atPath: root + "/.git/info", withIntermediateDirectories: true)
            guard let script = RemoteProject.attach(root: root, name: "shot.png") else { return t.fail("no script") }
            t.expectEqual(sh(script, input: Data("PNG".utf8)).status, 0)
            t.expectEqual(try? String(contentsOfFile: root + "/.lampboard/allegati/shot.png", encoding: .utf8), "PNG")
            _ = sh(RemoteProject.attach(root: root, name: "b.png")!, input: Data("B".utf8))
            let exclude = (try? String(contentsOfFile: root + "/.git/info/exclude", encoding: .utf8)) ?? ""
            t.expectEqual(exclude.components(separatedBy: "\n").filter { $0 == ".lampboard/" }.count, 1, "once: \(exclude)")
            t.expect(sh(script, input: Data("again".utf8)).status != 0, "a name already there is not overwritten")
            t.expectEqual(sh(RemoteProject.attachments(root: root)).output.split(separator: "\n").sorted(), ["b.png", "shot.png"])
            t.expectNil(RemoteProject.attach(root: root, name: "../x.png"), "only a plain name")

            let trap = project()
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("lb-out-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: trap); try? FileManager.default.removeItem(atPath: outside) }
            try? FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: trap + "/.lampboard", withDestinationPath: outside)
            t.expect(sh(RemoteProject.attach(root: trap, name: "x.png")!, input: Data("X".utf8)).status != 0, "refused")
            t.expect(!FileManager.default.fileExists(atPath: outside + "/allegati"), "nothing made outside, not even the folder")
        },
    ])
}
