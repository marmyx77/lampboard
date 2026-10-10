import Foundation
import LampBoardCore

/// Where the Hub reads a session's project (D156): the disk here, or the
/// panel's own ssh there, one shared connection per machine. Every call runs off
/// the main actor and answers nothing rather than something outside the folder.
struct ProjectSource: Sendable {

    struct Entry: Equatable, Sendable, Identifiable {
        let name: String
        let isFolder: Bool
        var id: String { name }
    }

    let root: String
    let host: String?

    var isRemote: Bool { host != nil }

    // MARK: - Asking

    func list(_ relative: String?) async -> [Entry] {
        if let relative, ProjectAccess.relative(relative) == nil { return [] }
        if let host {
            guard let script = RemoteProject.list(root: root, relative: relative),
                  let out = await Self.ssh(host, script) else { return [] }
            return Self.sorted(out.split(separator: "\n").compactMap { line in
                let name = String(line)
                guard name != "./", name != "../", !name.isEmpty else { return nil }
                return name.hasSuffix("/") ? Entry(name: String(name.dropLast()), isFolder: true) : Entry(name: name, isFolder: false)
            })
        }
        guard let folder = resolved(relative) else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder),
                                                                  includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return Self.sorted(urls.map { url in
            Entry(name: url.lastPathComponent, isFolder: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        })
    }

    func read(_ relative: String) async -> Data? {
        guard ProjectAccess.relative(relative) != nil else { return nil }
        if let host {
            guard let script = RemoteProject.read(root: root, relative: relative) else { return nil }
            return await Self.ssh(host, script).map { Data($0.utf8) }
        }
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        guard let real = resolved(relative), (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let handle = FileHandle(forReadingAtPath: real) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: ProjectAccess.previewBytes)
    }

    func gitStatus() async -> [String: String] {
        let out: String?
        if let host { out = await Self.ssh(host, RemoteProject.gitStatus(root: root)) }
        else { out = await Self.run("/usr/bin/git", ["-C", root, "status", "--porcelain=v1"]) }
        return GitStatus.parse(out ?? "")
    }

    func search(_ query: String) async -> [SearchHits.Hit] {
        guard let script = RemoteProject.search(root: root, query: query) else { return [] }
        let out = host != nil ? await Self.ssh(host!, script) : await Self.run("/bin/sh", ["-c", script])
        return SearchHits.parse(out ?? "")
    }

    /// The real path of a folder or file in the project, or `nil` when it leads out.
    private func resolved(_ relative: String?) -> String? {
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let url = relative.map { URL(fileURLWithPath: root).appendingPathComponent($0) } ?? URL(fileURLWithPath: root)
        let real = url.resolvingSymlinksInPath().path
        return ProjectAccess.isInside(real, root: realRoot) ? real : nil
    }

    private static func sorted(_ entries: [Entry]) -> [Entry] {
        ProjectFiles.sorted(entries.map { ($0.name, $0.isFolder) })
            .map { Entry(name: $0.name, isFolder: $0.isFolder) }
    }

    // MARK: - Processes

    /// One connection per machine, shared and kept a minute: the tree, a file
    /// and git status are three questions, not three logins.
    static func ssh(_ host: String, _ script: String) async -> String? {
        guard RemoteHostList.isUsable(host), !host.hasPrefix("-") else { return nil }
        let control = (NSTemporaryDirectory() as NSString).appendingPathComponent("lb-hub-%C")
        let args = SSHHardening.options + ["-o", "ConnectTimeout=8", "-o", "ControlMaster=auto",
                                          "-o", "ControlPath=\(control)", "-o", "ControlPersist=60",
                                          "-T", "--", host, script]
        return await run("/usr/bin/ssh", args)
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }
}
