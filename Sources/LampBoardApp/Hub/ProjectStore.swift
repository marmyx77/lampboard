import Foundation
import LampBoardCore

/// The projects attached to the Hub (hub-terminale R3), kept in
/// `~/.lampboard/projects.json`: a folder here or on another machine stays in the
/// list with no session in it, ready for one to start.
@MainActor
final class ProjectStore: ObservableObject {

    @Published private(set) var attached: [AttachedProject]
    private let file: URL

    init(file: URL = AppConfig.projectsFile) {
        self.file = file
        attached = (try? Data(contentsOf: file)).map(ProjectList.decode) ?? []
    }

    /// Attaches a folder; `false` when it cannot be reached.
    @discardableResult
    func add(path: String, host: String?) -> Bool {
        let project = AttachedProject(path: path, host: host, addedAt: Date())
        guard let next = ProjectList.adding(project, to: attached) else { return false }
        save(next)
        return true
    }

    func remove(_ id: String) { save(ProjectList.removing(id, from: attached)) }

    private func save(_ list: [AttachedProject]) {
        guard list != attached else { return }
        attached = list
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try ProjectList.encode(list).write(to: file, options: .atomic)
        } catch {
            Diagnostics.log("projects: could not write \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
