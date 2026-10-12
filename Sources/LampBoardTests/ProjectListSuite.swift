import Foundation
import LampBoardCore
import TestKit

/// The Hub's projects (hub-terminale R3): attached ones kept in their order,
/// then the folders the sessions are in; only a folder that can be reached.
enum ProjectListSuite {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func session(_ id: String, _ path: String, host: String? = nil, at minutes: Double) -> SessionState {
        SessionState(id: id, status: .ready, workspace: Workspace(path: path, host: host),
                     updatedAt: t0.addingTimeInterval(minutes * 60), statusSince: t0)
    }

    static let suite = TestSuite("Projects attached to the Hub", [

        TestCase("A project is attached once, at the end, and only when it can be reached") { t in
            let web = AttachedProject(path: "/Users/dev/web", host: nil, addedAt: t0)
            let api = AttachedProject(path: "/home/dev/api", host: "box", addedAt: t0)
            let list = ProjectList.adding(api, to: ProjectList.adding(web, to: [])!)!
            t.expectEqual(list.map(\.name), ["web", "api"])
            t.expectEqual(ProjectList.adding(web, to: list), list, "the same folder twice is one project")
            let elsewhere = AttachedProject(path: "/Users/dev/web", host: "box", addedAt: t0)
            t.expectEqual(ProjectList.adding(elsewhere, to: list)?.count, 3, "the same path on another machine is another project")
            t.expectNil(ProjectList.adding(AttachedProject(path: "relative", host: nil, addedAt: t0), to: list))
            t.expectNil(ProjectList.adding(AttachedProject(path: "/x", host: "-oProxyCommand=x", addedAt: t0), to: list))
            t.expectNil(ProjectList.adding(AttachedProject(path: "/x\ny", host: nil, addedAt: t0), to: list))
            t.expectEqual(ProjectList.removing(web.id, from: list).map(\.name), ["api"])
        },

        TestCase("The list: attached projects first, in their order, then the folders sessions are in, the latest first") { t in
            let attached = [AttachedProject(path: "/Users/dev/zeta", host: nil, addedAt: t0),
                            AttachedProject(path: "/Users/dev/web", host: nil, addedAt: t0)]
            let all = [session("a", "/Users/dev/web", at: 1), session("b", "/Users/dev/old", at: 2),
                       session("c", "/Users/dev/new", at: 9), session("d", "/Users/dev/web", at: 5),
                       session("e", "/Users/dev/web", host: "box", at: 7)]
            let state = TrafficLightState(sessions: Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }))
            let entries = ProjectList.entries(attached: attached, state: state)
            t.expectEqual(entries.map(\.name), ["zeta", "web", "new", "web", "old"])
            t.expectEqual(entries.map(\.attached), [true, true, false, false, false])
            t.expectEqual(entries[1].sessionIds, ["d", "a"], "its sessions, the latest first")
            t.expectEqual(entries[0].sessionIds, [], "an attached project with no session stays")
            t.expectEqual(entries[3].host, "box", "the same folder on another machine is its own")
        },

        TestCase("The file survives a round trip, and keeps only what can be reached") { t in
            let list = [AttachedProject(path: "/Users/dev/web", host: nil, addedAt: t0),
                        AttachedProject(path: "/home/dev/api", host: "box", addedAt: t0)]
            t.expectEqual(ProjectList.decode(ProjectList.encode(list)), list)
            let edited = #"[{"path":"relative","addedAt":"2026-10-11T10:00:00Z"},{"path":"/ok","addedAt":"2026-10-11T10:00:00Z"}]"#
            t.expectEqual(ProjectList.decode(Data(edited.utf8)).map(\.path), ["/ok"])
            t.expectEqual(ProjectList.decode(Data("garbage".utf8)), [])
        },
    ])
}
