import LampBoardCore
import Foundation
import TestKit

/// What a node's `lampd` forwards to the real app (W5, §2.3): an event that
/// arrived twice taken once (E3), and the Mac's own routes refused when a node
/// forwarded them (R2, «il nodo non comanda il Mac»).
enum NodeLinkE2ESuite {

    static let session = "e2e0d0d0-0000-4000-8000-0000000000dd"

    static func suite(_ app: AppUnderTest) -> TestSuite {
        TestSuite("E2E · what a node's lampd forwards", [

            TestCase("an event lampd forwarded twice is taken once; another id is taken") { t in
                // The header is believed only for a machine this app was told about.
                t.expectEqual(app.runCommand(["remote", "add", "e2e-node"]).status, 0, "host configured")
                defer { app.runCommand(["remote", "remove", "e2e-node"]) }
                usleep(300_000)
                let body = String(decoding: (try? JSONSerialization.data(withJSONObject:
                    HookPayloads.userPromptSubmit(sessionId: session, cwd: "/tmp/lampboard-e2e/project-node"))) ?? Data(), as: UTF8.self)
                let headers = ["Content-Type": "application/json", "X-Claude-Entrypoint": "cli",
                               AppConfig.remoteHostHeader: "e2e-node", MacNodeLink.eventHeader: "lampd-e2e-1"]
                let first = app.raw(method: "POST", path: AppConfig.signalPath, body: body, headers: headers)
                t.expectEqual(first.status, 204, "taken, as any hook")
                usleep(300_000)
                t.expectEqual(app.status(of: session), "working", "the row lit by it")
                let again = app.raw(method: "POST", path: AppConfig.signalPath, body: body, headers: headers)
                t.expectEqual(again.status, 200)
                t.expectEqual(again.body, "already taken", "the same event, once")
                var other = headers
                other[MacNodeLink.eventHeader] = "lampd-e2e-2"
                t.expectEqual(app.raw(method: "POST", path: AppConfig.signalPath, body: body, headers: other).status, 204,
                              "another event is another event")
            },

            TestCase("the Mac's own routes, forwarded by a node, are refused; from the Mac itself they are what they were") { t in
                for path in [AppConfig.nextPath, AppConfig.openPath, AppConfig.newConversationPath, AppConfig.chatPath] {
                    let forwarded = app.raw(method: "POST", path: path, body: "{}", headers: [MacNodeLink.eventHeader: "lampd-e2e-9"])
                    t.expectEqual(forwarded.status, 403, "\(path) through a node")
                    t.expect(app.raw(method: "POST", path: path, body: "{}").status != 403, "\(path) from here is not refused for that")
                }
                t.expectEqual(app.raw(method: "GET", path: AppConfig.checkPath, headers: [MacNodeLink.eventHeader: "lampd-e2e-10"]).status,
                              403, "the list of asks is the panel's")
            },
        ])
    }
}
