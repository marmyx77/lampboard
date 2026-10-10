import Combine
import Foundation
import LampBoardCore

/// The open session's project as the Hub shows it (D156): its tree, what git
/// and the session's tools say of each file, a search, the files open in tabs,
/// and whether the last column shows a file or the project's shell.
@MainActor
final class HubFilesModel: ObservableObject {

    struct OpenFile: Equatable, Identifiable {
        let path: String
        let kind: ProjectAccess.Kind
        var text: String?
        /// The file as drawn, made away from the main thread once it is read.
        var code: HubDocument?
        var preview: HubDocument?
        /// When it was last changed on this Mac's disk, to read it again when it changes.
        var stamp: Date?
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    enum LastColumn: String { case file, terminal }

    @Published private(set) var source: ProjectSource?
    @Published private(set) var folders: [String: [ProjectSource.Entry]] = [:]
    @Published var expanded: Set<String> = []
    @Published private(set) var git: [String: String] = [:]
    @Published private(set) var marks: [String: FileMarks.Mark] = [:]
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published private(set) var hits: [SearchHits.Hit] = []
    @Published private(set) var open: [OpenFile] = []
    @Published var active: String?
    @Published var previews: Set<String> = []
    @Published var lastColumn: LastColumn = .file

    /// The tools the session ran lately, for the marks: (name, detail).
    var tools: (String) -> [(name: String, detail: String?)] = { _ in [] }

    private var session: String?
    private var timer: AnyCancellable?
    private var searchTask: Task<Void, Never>?
    private var refreshing = false
    /// Each read of a file takes the next number; only the latest one is kept,
    /// so a slow read finishing late never overwrites a newer one.
    private var reads: [String: Int] = [:]

    /// Points the model at a session's project; a session of the same folder
    /// keeps what is open.
    func show(session id: String?, root: String?, host: String?) {
        session = id
        guard let root else { reset(nil); return }
        let next = ProjectSource(root: root, host: host)
        guard source?.root != next.root || source?.host != next.host else {
            if timer == nil { refresh(); startTimer() }
            return
        }
        reset(next)
        load(nil)
        refresh()
        startTimer()
    }

    /// The Hub closed: git is asked nothing more until it opens again, and
    /// what is open stays open.
    func pause() { timer = nil }

    private func startTimer() {
        timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    }

    func toggle(_ folder: String) {
        if expanded.contains(folder) { expanded.remove(folder) } else { expanded.insert(folder); load(folder) }
    }

    func entries(in folder: String?) -> [ProjectSource.Entry] { folders[folder ?? ""] ?? [] }

    /// Opens a file in a tab, or brings its tab forward.
    func openFile(_ path: String) {
        guard let source, ProjectAccess.relative(path) != nil else { return }
        lastColumn = .file
        active = path
        guard !open.contains(where: { $0.path == path }) else { return }
        let kind = ProjectAccess.kind(of: path)
        open.append(OpenFile(path: path, kind: kind, text: nil))
        if kind == .markdown { previews.insert(path) }
        guard kind != .binary else { return }
        Task { await self.read(path, from: source) }
    }

    /// Reads an open file and makes what is drawn of it, away from the main
    /// thread; read again, a file that has not changed is left as it is.
    private func read(_ path: String, from source: ProjectSource) async {
        guard let kind = open.first(where: { $0.path == path })?.kind else { return }
        let number = (reads[path] ?? 0) + 1
        reads[path] = number
        // Still this read, of this project: another project's file of the same
        // name, or a newer read, is never overwritten by this one.
        func current() -> Bool { reads[path] == number && self.source == source }
        let stamp = source.isRemote ? nil : Self.stamp(of: path, in: source.root)
        let data = await source.read(path)
        let text = await Task.detached(priority: .userInitiated) {
            data.flatMap { ProjectFiles.previewText($0) ?? String(data: $0, encoding: .utf8) } ?? ""
        }.value
        guard current(), let file = open.first(where: { $0.path == path }) else { return }
        update(path) { $0.stamp = stamp }
        // Unchanged and fully made: nothing to do. A read that replaced an
        // older one still making its views makes them itself.
        let made = file.code != nil && (kind != .markdown || file.preview != nil)
        guard file.text != text || !made else { return }
        update(path) { $0.text = text }
        // The view shown first: a Markdown file opens as its preview.
        if kind == .markdown {
            let preview = await Task.detached(priority: .userInitiated) { HubDocument.markdown(text) }.value
            guard current() else { return }
            update(path) { $0.preview = preview }
        }
        let language: String
        if case .code(let name) = kind { language = name } else { language = "md" }
        let code = await Task.detached(priority: .userInitiated) { HubDocument.code(text, language: language) }.value
        guard current() else { return }
        update(path) { $0.code = code }
    }

    private static func stamp(of path: String, in root: String) -> Date? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Changes an open file, if it is still open.
    private func update(_ path: String, _ change: (inout OpenFile) -> Void) {
        guard let index = open.firstIndex(where: { $0.path == path }) else { return }
        change(&open[index])
    }

    func close(_ path: String) {
        open.removeAll { $0.path == path }
        if active == path { active = open.last?.path }
    }

    var activeFile: OpenFile? { open.first { $0.path == active } }

    // MARK: - Loading

    private func reset(_ next: ProjectSource?) {
        timer = nil
        refreshing = false
        reads = [:]
        source = next
        folders = [:]
        expanded = []
        git = [:]
        marks = [:]
        hits = []
        open = []
        active = nil
    }

    private func load(_ folder: String?) {
        guard let source else { return }
        Task {
            let entries = await source.list(folder)
            guard self.source == source else { return }
            self.folders[folder ?? ""] = entries
        }
    }

    /// Git and the marks, every few seconds: published only when they change,
    /// since every change draws the columns again; one question at a time.
    private func refresh() {
        guard let source, !refreshing else { return }
        refreshing = true
        Task {
            defer { self.refreshing = false }
            let status = await source.gitStatus()
            guard self.source == source else { return }
            var changed = false
            if self.git != status { self.git = status; changed = true }
            if let session = self.session {
                let marks = FileMarks.marks(tools: self.tools(session), root: source.root, changed: Set(status.keys))
                if self.marks != marks { self.marks = marks; changed = true }
            }
            // The session works on the project while it is open here: what git
            // or its tools say changed is read again, the tree and the file in
            // sight; a file changed on this Mac's disk is read again too.
            if changed { await self.reloadFolders(from: source) }
            if let active = self.active, let file = self.open.first(where: { $0.path == active }), file.kind != .binary,
               changed || (!source.isRemote && Self.stamp(of: active, in: source.root) != file.stamp) {
                await self.read(active, from: source)
            }
        }
    }

    /// The folders already listed, listed again; published only when they differ.
    private func reloadFolders(from source: ProjectSource) async {
        for key in folders.keys {
            let entries = await source.list(key.isEmpty ? nil : key)
            guard self.source == source else { return }
            if folders[key] != entries { folders[key] = entries }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard let source, text.count >= 2 else { hits = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let found = await source.search(text)
            guard !Task.isCancelled else { return }
            self.hits = found
        }
    }
}
