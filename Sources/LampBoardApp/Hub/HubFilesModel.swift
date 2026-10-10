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

    /// Points the model at a session's project; a session of the same folder
    /// keeps what is open.
    func show(session id: String?, root: String?, host: String?) {
        session = id
        guard let root else { reset(nil); return }
        let next = ProjectSource(root: root, host: host)
        guard source?.root != next.root || source?.host != next.host else { return }
        reset(next)
        load(nil)
        refresh()
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
        Task {
            let data = await source.read(path)
            let text = data.flatMap { ProjectFiles.previewText($0) ?? String(data: $0, encoding: .utf8) }
            if let index = self.open.firstIndex(where: { $0.path == path }) { self.open[index].text = text ?? "" }
        }
    }

    func close(_ path: String) {
        open.removeAll { $0.path == path }
        if active == path { active = open.last?.path }
    }

    var activeFile: OpenFile? { open.first { $0.path == active } }

    // MARK: - Loading

    private func reset(_ next: ProjectSource?) {
        timer = nil
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
            guard self.source?.root == source.root else { return }
            self.folders[folder ?? ""] = entries
        }
    }

    private func refresh() {
        guard let source else { return }
        Task {
            let status = await source.gitStatus()
            guard self.source?.root == source.root else { return }
            self.git = status
            if let session = self.session {
                self.marks = FileMarks.marks(tools: self.tools(session), root: source.root, changed: Set(status.keys))
            }
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
