import LampBoardCore
import Foundation
import TestKit

/// The Mac and a node's `lampd` on the tunnel's connection (W5, §2.3, §2.12):
/// the port the tunnel holds from the heartbeats alone, the lines each way, and
/// the merge of the panel's choices into the node's.
enum MacNodeLinkSuite {

    private static let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private static let id = "30000000-0000-4000-8000-000000000001"

    static func beat(_ serving: Bool, hooks: Bool = true) -> NodeToMac {
        NodeToMac(serving: serving, journal: "j", seq: 1, hooks: serving ? hooks : nil, at: t0)
    }

    static let suite = TestSuite("Mac and lampd: the tunnel's port, the lines, the merge of the choices", [

        TestCase("The hooks' port goes to lampd after three healthy beats, not before") { t in
            var watch = MacNodeLinkWatch()
            t.expectEqual(watch.beat(beat(true), at: t0), .primary)
            t.expectEqual(watch.beat(beat(true), at: t0.addingTimeInterval(0.3)), .primary)
            t.expect(!watch.lampdHealthy(at: t0.addingTimeInterval(0.3)), "two beats are not yet healthy")
            t.expectEqual(watch.beat(beat(true), at: t0.addingTimeInterval(0.6)), .secondary)
            t.expect(watch.lampdHealthy(at: t0.addingTimeInterval(0.6)), "three are: lampd owns the node's rows")
        },

        TestCase("A lampd that serves without the hooks' port owns its rows, and the port stays the Mac's") { t in
            // Installed without `--tee`, or after `lampd release` (§2.15, the way
            // back): moving the tunnel off the hooks' port would leave it empty.
            var watch = MacNodeLinkWatch()
            for n in 0..<5 { watch.beat(beat(true, hooks: false), at: t0.addingTimeInterval(Double(n) * 0.3)) }
            t.expectEqual(watch.port, .primary, "nobody else hears the hooks")
            t.expect(watch.lampdHealthy(at: t0.addingTimeInterval(1.2)), "yet lampd answers: its rows are its own")
            for n in 5..<8 { watch.beat(beat(true), at: t0.addingTimeInterval(Double(n) * 0.3)) }
            t.expectEqual(watch.port, .secondary, "once it holds the port in tee, the tunnel goes next to it")
            t.expectEqual(watch.beat(beat(true, hooks: false), at: t0.addingTimeInterval(2.4)), .primary,
                          "lampd release: the port back to the Mac at the first beat that says so")
            t.expect(watch.lampdHealthy(at: t0.addingTimeInterval(2.4)), "still owning its rows")
        },

        TestCase("The first beat that says lampd is not serving takes the port back (N = 1)") { t in
            var watch = MacNodeLinkWatch()
            for n in 0..<5 { watch.beat(beat(true), at: t0.addingTimeInterval(Double(n) * 0.3)) }
            t.expectEqual(watch.port, .secondary)
            t.expectEqual(watch.beat(beat(false), at: t0.addingTimeInterval(1.5)), .primary)
            t.expect(!watch.lampdHealthy(at: t0.addingTimeInterval(1.5)), "the Mac notifies the node's rows again")
            t.expectEqual(watch.beat(beat(true), at: t0.addingTimeInterval(1.8)), .primary, "back only after three again (M = 3)")
        },

        TestCase("Silence past the margin is lampd gone: the port comes back without a beat") { t in
            var watch = MacNodeLinkWatch()
            for n in 0..<3 { watch.beat(beat(true), at: t0.addingTimeInterval(Double(n) * 0.3)) }
            t.expectEqual(watch.tick(at: t0.addingTimeInterval(1.5)), .secondary, "within the margin")
            t.expectEqual(watch.tick(at: t0.addingTimeInterval(0.6 + MacNodeLink.silentAfter + 0.1)), .primary)
            t.expect(!watch.lampdHealthy(at: t0.addingTimeInterval(0.6 + MacNodeLink.silentAfter + 0.1)), "and lampd is not healthy")
        },

        TestCase("The secondary port is the next one; the hooks' file keeps the primary") { t in
            t.expectEqual(MacNodeLink.secondaryPort(of: AppConfig.remotePort(forUID: 1000)), 31001)
        },

        TestCase("A line from the Mac carries exactly one thing, and never a device's focus") { t in
            t.expectNil(MacToNode(presence: .away, at: t0).problem)
            t.expectNotNil(MacToNode(at: t0).problem, "an empty line")
            t.expectNotNil(MacToNode(presence: .here, settings: MacNodeSettings(sendMessages: true), at: t0).problem, "two things")
            t.expectNotNil(MacToNode(command: V1Command(action: .focus), at: t0).problem, "focus is a device's")
            t.expectNotNil(MacToNode(command: V1Command(action: .markSeen, session: "not an id"), at: t0).problem)
            t.expectNil(MacToNode(command: V1Command(action: .markSeen, session: id), at: t0).problem)
        },

        TestCase("Lines each way read back as written") { t in
            let out = MacToNode(settings: MacNodeSettings(permissionMode: "bypass", sendMessages: true, palette: "{}"), at: t0)
            let line = MacNodeLink.encode(out)
            t.expectNotNil(line)
            t.expect(!(line ?? "").contains("\n"), "one line")
            t.expectEqual(line.flatMap { MacNodeLink.decode(MacToNode.self, $0) }, out)
            var choices = RowPreferences()
            choices.apply(V1Command(action: .rename, session: id, name: "api"), at: t0)
            let back = NodeToMac(preferences: RowPreferencesWire(choices), at: t0)
            let read = MacNodeLink.encode(back).flatMap { MacNodeLink.decode(NodeToMac.self, $0) }
            t.expectEqual(read?.preferences?.preferences, choices)
        },

        TestCase("Bypass from the start is allowed on a node only when the Mac's own mode is Bypass") { t in
            t.expect(MacNodeSettings(permissionMode: "bypass").bypassAllowed, "the Mac starts in Bypass")
            t.expect(!MacNodeSettings(permissionMode: "allowBypass").bypassAllowed, "Bypass on Shift+Tab is not from the start")
            t.expect(!MacNodeSettings().bypassAllowed, "unwritten is off")
        },

        TestCase("The migration: per field the last written wins with its date, at a tie the node's") { t in
            var node = RowPreferences()
            node.apply(V1Command(action: .rename, session: id, name: "from the phone"), at: t0.addingTimeInterval(60))
            node.apply(V1Command(action: .mute, session: id, on: true), at: t0)
            var mac = RowPreferences()
            mac.apply(V1Command(action: .rename, session: id, name: "from the panel"), at: t0)
            mac.apply(V1Command(action: .mute, session: id, on: false), at: t0)
            mac.apply(V1Command(action: .hide, session: id, on: true), at: t0.addingTimeInterval(30))
            let merged = node.merged(with: mac).row(id)
            t.expectEqual(merged.label?.value, "from the phone", "the phone's rename is later")
            t.expectEqual(merged.muted?.value, true, "a tie keeps the node's")
            t.expectEqual(merged.hidden?.value, true, "a field only the panel set comes over")
            t.expectEqual(node.merged(with: mac).merged(with: mac), node.merged(with: mac), "merging twice does nothing more")
        },

        TestCase("The tunnel's ssh runs lampd mac-link on the node: no -N, the command last") { t in
            // 2.4.0 passed `-N`, and ssh with `-N` runs no command: the forward
            // held and `lampd` never heard from the Mac.
            let arguments = MacNodeLink.tunnelArguments(host: "bestia", remotePort: 31000, localPort: 9877, connectTimeout: 5)
            t.expect(!arguments.contains("-N"), "-N would drop the command: \(arguments)")
            t.expectEqual(arguments.suffix(2), ["bestia", MacNodeLink.remoteCommand])
            t.expect(arguments.contains("127.0.0.1:31000:127.0.0.1:9877"), "the forward of the hooks' port")
            t.expect(arguments.starts(with: SSHHardening.options), "the hardening first")
        },
    ])
}
