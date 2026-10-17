import Foundation
import LampBoardCore
import LampDKit
import TestKit

/// The person's choices as a file, the configuration, and the replay of
/// recorded hooks that holds `lampd` to the Mac's reducer.
enum SmallSuites {

    static let preferences = TestSuite("lampd: the person's choices on disk", [

        TestCase("Every choice keeps its date, and the file reads back the same") { t in
            var preferences = RowPreferences()
            preferences.apply(V1Command(action: .rename, session: F.a, name: "Release"), at: F.t0)
            preferences.apply(V1Command(action: .mute, session: F.a, on: true), at: F.t0 + 1)
            preferences.apply(V1Command(action: .hide, session: F.b, on: false), at: F.t0 + 2)
            preferences.apply(V1Command(action: .order, ids: [F.b, F.a]), at: F.t0 + 3)
            preferences.apply(V1Command(action: .markSeen, session: F.a), at: F.t0 + 4)
            preferences.apply(V1Command(action: .markUnread, session: F.b), at: F.t0 + 5)
            preferences.apply(V1Command(action: .dismiss, session: F.c), at: F.t0 + 6)
            preferences.apply(V1Command(action: .focus), at: F.t0 + 7)
            t.expectEqual(preferences.row(F.a).label?.at, F.t0, "the name's date")
            t.expectEqual(preferences.row(F.a).order?.value, 1, "the place")
            t.expect(preferences.row(F.b).readAt != nil && preferences.row(F.b).readAt?.value == nil, "unread is a choice too")
            let back = (try? preferences.encoded()).map(RowPreferences.decode)
            t.expectEqual(back?.rows.count, preferences.rows.count, "every row back")
            t.expectEqual(back?.row(F.a).label?.value, "Release", "the name back")
            t.expectEqual(back?.row(F.a).muted?.at, F.t0 + 1, "its date back")
            t.expectEqual(back?.row(F.c).dismissedAt?.value, F.t0 + 6, "the dismissal back")
            t.expect(back?.row(F.b).readAt?.value == nil && back?.row(F.b).readAt != nil, "unread back")
        },

        TestCase("A file that cannot be read is no choices, never a crash") { t in
            t.expectEqual(RowPreferences.decode(Data("not json".utf8)).rows.count, 0, "nothing")
            t.expectEqual(RowPreferences.decode(Data(#"{"rows":{"../x":{"label":{"value":"a","at":"2027-01-15T08:00:00Z"}}}}"#.utf8)).rows.count,
                          0, "an id that is not one is dropped")
        },

        TestCase("Choices about sessions gone for long are forgotten; the live ones stay") { t in
            var preferences = RowPreferences()
            preferences.apply(V1Command(action: .mute, session: F.a, on: true), at: F.t0)
            preferences.apply(V1Command(action: .mute, session: F.b, on: true), at: F.t0)
            preferences.forget(besides: [F.a], olderThan: 3600, at: F.t0 + 7200)
            t.expectEqual(Set(preferences.rows.keys), [F.a], "only the live one")
        },
    ])

    static let projects = TestSuite("lampd: the projects kept in the list", [

        TestCase("A folder of this machine is kept once, a path that is not one is refused, a detached one goes") { t in
            let base = NSTemporaryDirectory() + "lampd-projects-\(UUID().uuidString.prefix(8))"
            defer { try? FileManager.default.removeItem(atPath: base) }
            let folder = base + "/work/app"
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let store = ProjectsStore(path: base + "/state/projects.json")
            t.expectEqual(store.list(), [], "none at first, no file")
            t.expectEqual((try? store.attach(folder, at: F.t0))?.map(\.path), [folder], "kept")
            t.expectEqual((try? store.attach(folder + "/", at: F.t0 + 1))?.count, 1, "the same folder once, slash or not")
            t.expectThrows(ProjectsStore.ProjectsError.notAFolder("work/app")) { _ = try store.attach("work/app") }
            t.expectThrows(ProjectsStore.ProjectsError.notAFolder(base + "/nothing")) { _ = try store.attach(base + "/nothing") }
            let data = FileManager.default.contents(atPath: base + "/state/projects.json") ?? Data()
            t.expectEqual(ProjectList.decode(data).map(\.path), [folder], "the Hub's own file shape")
            t.expectEqual((try? store.detach(folder))?.count, 0, "detached")
            t.expectEqual(store.list(), [], "and gone from the file")
        },
    ])

    static let config = TestSuite("lampd: configuration", [

        TestCase("No file is the defaults; a bad value is said and the default kept") { t in
            let paths = F.home("config")
            defer { F.remove(paths) }
            t.expectEqual(LampDConfig.load(paths.configFile).config, LampDConfig(), "defaults")
            try? FileManager.default.createDirectory(atPath: paths.configDirectory, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: paths.configFile,
                                           contents: Data(#"{"name":"Build box","probeInterval":500,"future":1}"#.utf8))
            let (config, problem) = LampDConfig.load(paths.configFile)
            t.expectEqual(config.name, "Build box", "the name")
            t.expectEqual(config.probeInterval, LampDConfig.defaultProbeInterval, "the default interval")
            t.expect(problem?.contains("probeInterval") == true, "said: \(problem ?? "")")
            t.expectEqual(config.allowance, false, "the allowance is not asked unless turned on")
        },

        TestCase("Doctor reads the tmux options a phone's sessions want, and says the line that sets them") { t in
            func lines(_ values: [String: String]?) -> [LampDDoctor.Line] {
                LampDDoctor.tmuxOptions { _, name in values?[name] }
            }
            let all = lines(["focus-events": "on", "extended-keys": "on", "allow-passthrough": "on"])
            t.expectEqual(all.map(\.verdict), [.green], "all three on: green")
            let some = lines(["focus-events": "on", "extended-keys": "off", "allow-passthrough": "off"])
            t.expectEqual(some.map(\.verdict), [.yellow], "two off: yellow")
            t.expect(some.first?.text.contains("extended-keys, allow-passthrough") == true, "named: \(some.first?.text ?? "")")
            t.expect(some.first?.text.contains("source-file -q ~/.config/lampd/tmux.conf") == true, "with the line to add")
            t.expect(!(some.first?.text.contains("focus-events") ?? true), "an option that is on is not named")
            let none = lines(nil)
            t.expectEqual(none.map(\.verdict), [.yellow], "no server: yellow")
            t.expect(none.first?.text.contains("no tmux server") == true, "said: \(none.first?.text ?? "")")
        },

        TestCase("The paths: a test home keeps everything inside it") { t in
            let paths = LampDPaths.current(environment: ["LAMPBOARD_HOME": "/tmp/x", "HOME": "/home/dev", "XDG_RUNTIME_DIR": "/run/user/1000"])
            t.expectEqual(paths.home, "/tmp/x", "the override")
            t.expectEqual(paths.socket, "/tmp/x/.local/state/lampd/run/lampd/v1.sock", "the socket inside it")
            let real = LampDPaths.current(environment: ["HOME": "/home/dev", "XDG_RUNTIME_DIR": "/run/user/1000"])
            t.expectEqual(real.socket, "/run/user/1000/lampd/v1.sock", "the runtime folder otherwise")
            t.expectEqual(real.authorizedKeys, "/home/dev/.ssh/authorized_keys", "the account's keys")
        },
    ])

    static let replay = TestSuite("lampd: recorded hooks, reduced", [

        TestCase("A recorded turn goes working, needs you, back to work, and answers") { t in
            let flow = [
                #"{"at":0,"entrypoint":"cli","payload":{"cwd":"/home/dev/api","hook_event_name":"UserPromptSubmit","session_id":"replay-1"}}"#,
                #"{"at":1,"entrypoint":"cli","payload":{"cwd":"/home/dev/api","hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"replay-1"}}"#,
                #"{"at":2,"entrypoint":"cli","payload":{"cwd":"/home/dev/api","hook_event_name":"PostToolUse","session_id":"replay-1"}}"#,
                #"{"at":3,"entrypoint":"cli","payload":{"cwd":"/home/dev/api","hook_event_name":"Stop","last_assistant_message":"Done.","session_id":"replay-1"}}"#,
            ].joined(separator: "\n")
            let steps = (try? HookReplay.events(in: flow)).map { HookReplay.replay($0, workspace: "/home/dev/api", start: F.t0) }
            t.expectEqual(steps?.map(\.status), ["working", "awaiting", "working", "ready"], "the lamp after each event")
        },

        TestCase("A line that is not a recorded event is refused by its number") { t in
            t.expect((try? HookReplay.events(in: "{\"at\":0}")) == nil, "refused")
        },
    ])
}
