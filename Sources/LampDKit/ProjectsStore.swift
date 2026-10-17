import Foundation
import LampBoardCore

/// The projects of this machine that the person keeps in the list (H1.1-4,
/// H1.4-1): a folder here, with or without a session, so that a session can be
/// started or resumed there from a phone. Kept by `lampd`, as the Hub keeps the
/// Mac's (`ProjectList`, the same rules and the same file shape), written by
/// `lampd projects attach|detach`, which a device runs with its action key.
public struct ProjectsStore: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    public func list() -> [AttachedProject] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return ProjectList.decode(data).filter { $0.host == nil }
    }

    /// The list with `folder` in it; the same list when it was there already.
    /// A folder that is not an absolute path is refused; one that is not a
    /// folder on this machine too, since nothing could start there.
    public func attach(_ folder: String, at now: Date = Date()) throws -> [AttachedProject] {
        let project = AttachedProject(path: folder, host: nil, addedAt: now)
        guard ProjectList.isValid(path: project.path, host: nil) else { throw ProjectsError.notAFolder(folder) }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &directory), directory.boolValue else {
            throw ProjectsError.notAFolder(folder)
        }
        return try update { list in ProjectList.adding(project, to: list) ?? list }
    }

    public func detach(_ folder: String) throws -> [AttachedProject] {
        let id = ProjectList.key(path: PathNormalizer.normalize(folder), host: nil)
        return try update { ProjectList.removing(id, from: $0) }
    }

    private func update(_ change: ([AttachedProject]) -> [AttachedProject]) throws -> [AttachedProject] {
        try LampDPaths.makeDirectory((path as NSString).deletingLastPathComponent)
        return try FileLock.with(path + ".lock") {
            let next = change(list())
            try AtomicFile.write(ProjectList.encode(next), to: path)
            return next
        }
    }

    public enum ProjectsError: Error, Equatable, CustomStringConvertible {
        case notAFolder(String)

        public var description: String {
            switch self {
            case .notAFolder(let folder): return "\(folder) is not a folder on this machine"
            }
        }
    }
}

extension ProjectsStore {
    public init(paths: LampDPaths) { self.init(path: paths.projectsFile) }
}
