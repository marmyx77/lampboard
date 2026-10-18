#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import LampBoardCore
import LampDKit
import TestKit

/// The hooks' port in tee (W5, §2.3): every route with one owner, the token the
/// hooks already send, what is passed on to the Mac and named, what is refused
/// (R2), the questions the Mac holds, all over real sockets on loopback.
enum TeeSuite {

    /// The Mac's end of the tunnel: answers each request as told, keeps them.
    final class StubMac: @unchecked Sendable {
        let fd: Int32
        let port: UInt16
        private let lock = NSLock()
        private(set) var requests: [HTTPRequest] = []
        var delay: TimeInterval = 0
        var body = "lampboard-mac"

        init() {
            fd = LoopbackTCP.listen(port: 0)!
            port = LoopbackTCP.boundAddress(fd)!.port
            Thread.detachNewThread { [self] in
                while let connection = UnixSocket.accept(fd) {
                    Thread.detachNewThread { [self] in serve(connection) }
                }
            }
        }

        private func serve(_ connection: Int32) {
            defer { close(connection) }
            guard let request = HookTee.read(connection) else { return }
            lock.lock()
            requests.append(request)
            let wait = delay, text = body
            lock.unlock()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            UnixSocket.sendAll(connection, Array(HTTPRequestParser.response(status: 200, reason: "OK", body: text)))
        }

        func taken(within seconds: TimeInterval = 3, count: Int = 1) -> [HTTPRequest] {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                let seen = lock.withLock { requests }
                if seen.count >= count { return seen }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return lock.withLock { requests }
        }

        func stop() { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
    }

    struct Reply { let status: Int; let body: String }

    static func send(_ port: UInt16, _ method: String, _ path: String, headers: [String: String] = [:], body: String = "") -> Reply? {
        guard let fd = LoopbackTCP.connect(port: port, timeout: 2) else { return nil }
        defer { close(fd) }
        LoopbackTCP.setTimeouts(fd, seconds: 80)
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.utf8.count)\r\n\r\n"
        UnixSocket.sendAll(fd, Array(head.utf8) + Array(body.utf8))
        let text = String(decoding: LoopbackTCP.readAll(fd), as: UTF8.self)
        guard let first = text.split(separator: "\r\n").first, let status = Int(first.split(separator: " ").dropFirst().first ?? "") else { return nil }
        let content = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
        return Reply(status: status, body: content)
    }

    static let token = String(repeating: "5a", count: 32)
    static let tokenHeader = [AccessToken.headerName: token]

    /// A home with the token the Mac's repair wrote, a tee on a port of its own
    /// and the stub Mac on another, and the source the tee changes.
    static func rig(mac: StubMac? = nil) -> (paths: LampDPaths, source: NodeSource, tee: HookTee, port: UInt16, mac: StubMac) {
        let paths = F.home("tee")
        try? FileManager.default.createDirectory(atPath: paths.home + "/.lampboard", withIntermediateDirectories: true)
        try? (token + "\n").write(toFile: paths.hookTokenFile, atomically: true, encoding: .utf8)
        let source = F.source(paths)
        let stub = mac ?? StubMac()
        let tee = HookTee(hooks: source.hooks, macPort: stub.port, tokenFile: paths.hookTokenFile, log: { _ in },
                          changed: { source.changed(at: $0) })
        let fd = LoopbackTCP.listen(port: 0)!
        tee.serve(fd)
        return (paths, source, tee, LoopbackTCP.boundAddress(fd)!.port, stub)
    }

    static func hook(_ event: String, _ session: String = F.a, extra: String = "") -> String {
        #"{"hook_event_name":"\#(event)","session_id":"\#(session)","cwd":"/home/dev/project"\#(extra)}"#
    }

    static let suite = TestSuite("lampd: the hooks' port in tee", [

        TestCase("Every route of the table has one owner; /new, /open, /chat, /next are refused (R2)") { t in
            for route in HookRoutes.table { t.expectEqual(HookRoutes.route(method: "POST", path: route.path)?.owner, route.owner, route.path) }
            for path in [AppConfig.newConversationPath, AppConfig.openPath, AppConfig.chatPath, AppConfig.nextPath] {
                t.expectEqual(HookRoutes.route(method: "POST", path: path)?.owner, .refuse, path)
            }
            t.expectNil(HookRoutes.route(method: "POST", path: "/a-route-of-tomorrow"), "an unknown route has no owner")
            t.expectEqual(HookRoutes.route(method: "GET", path: AppConfig.checkPath)?.owner, .refuse, "GET /check is a client's")
        },

        TestCase("A hook with the token the hooks already send is heard, answered at once and passed on, named") { t in
            let rig = rig()
            defer { rig.tee.stop(); rig.mac.stop(); F.remove(rig.paths) }
            rig.source.absorb(F.look([F.record(F.a, pid: 10, status: "idle", tail: F.ended)]))
            let reply = send(rig.port, "POST", AppConfig.signalPath, headers: tokenHeader, body: hook("UserPromptSubmit"))
            t.expectEqual(reply?.status, 204, "answered here")
            let taken = rig.mac.taken()
            t.expectEqual(taken.count, 1, "and passed on to the Mac")
            t.expectEqual(taken.first.map { String(decoding: $0.body, as: UTF8.self) }, hook("UserPromptSubmit"), "byte for byte")
            t.expect(taken.first?.header(MacNodeLink.eventHeader)?.hasPrefix(rig.tee.name + "-") == true,
                     "named, so the Mac 2.4 drops a double (E3): \(taken.first?.headers ?? [:])")
            t.expectEqual(taken.first?.header(AccessToken.headerName), token, "with the hook's own token")
            let row = rig.source.currentRows.first
            t.expectEqual(row?.session.status, SessionStatus.working.rawValue, "the row is heard working, not read idle")
            t.expectEqual(row?.extras.stateBasis, .hooks, "and says so")
        },

        TestCase("Token adopted: a session opened before the switch still changes colour; a new token would refuse it") { t in
            let rig = rig()
            defer { rig.tee.stop(); rig.mac.stop(); F.remove(rig.paths) }
            rig.source.absorb(F.look([F.record(F.a, pid: 10, status: "busy")]))
            // The hook of a session started under the Mac 2.3 carries the token
            // the Mac wrote then: the one in ~/.lampboard/token.
            t.expectEqual(send(rig.port, "POST", AppConfig.signalPath, headers: tokenHeader,
                               body: hook("Stop", extra: #","last_assistant_message":"Done.""#))?.status, 204)
            t.expectEqual(rig.source.currentRows.first?.session.status, SessionStatus.ready.rawValue, "green: an answer to read")
            t.expectEqual(rig.tee.adoptedToken, token, "the token is the file's, never one made here")
            let wrong = send(rig.port, "POST", AppConfig.signalPath, headers: [AccessToken.headerName: String(repeating: "0", count: 64)],
                             body: hook("UserPromptSubmit"))
            t.expectEqual(wrong?.status, 401, "a token that is not the hooks' is refused")
            t.expectEqual(rig.source.currentRows.first?.session.status, SessionStatus.ready.rawValue, "and changes nothing")
        },

        TestCase("Refused and logged: /new from the node (R2), a route nobody named, a web page") { t in
            let rig = rig()
            defer { rig.tee.stop(); rig.mac.stop(); F.remove(rig.paths) }
            t.expectEqual(send(rig.port, "POST", AppConfig.newConversationPath, headers: tokenHeader, body: "{}")?.status, 403)
            t.expectEqual(send(rig.port, "POST", AppConfig.chatPath, headers: tokenHeader, body: "{}")?.status, 403)
            t.expectEqual(send(rig.port, "POST", "/a-route-of-tomorrow", headers: tokenHeader, body: "{}")?.status, 404)
            t.expectEqual(send(rig.port, "POST", AppConfig.signalPath, headers: ["Origin": "http://example.com"], body: hook("Stop"))?.status, 403)
            t.expectEqual(send(rig.port, "GET", AppConfig.watchPath)?.status, 404, "/watch: no lampboard for Linux")
            Thread.sleep(forTimeInterval: 0.3)
            t.expectEqual(rig.mac.requests.count, 0, "none of them reached the Mac")
            t.expectEqual(rig.tee.stats.refused, 5, "each counted")
        },

        TestCase("/health is served here; /sessions is the Mac's, its answer handed back") { t in
            let rig = rig()
            defer { rig.tee.stop(); rig.mac.stop(); F.remove(rig.paths) }
            t.expectEqual(send(rig.port, "GET", AppConfig.healthPath)?.body, "lampboard", "the mod's /health")
            t.expectEqual(rig.mac.requests.count, 0, "without asking the Mac")
            t.expectEqual(send(rig.port, "GET", AppConfig.sessionsPath, headers: tokenHeader)?.body, "lampboard-mac", "/lamps sees the Mac's column")
        },

        TestCase("With nobody on the Mac's port the hook is still heard, and nothing waits") { t in
            let stub = StubMac()
            stub.stop()
            let rig = rig(mac: stub)
            defer { rig.tee.stop(); F.remove(rig.paths) }
            rig.source.absorb(F.look([F.record(F.a, pid: 10, status: "idle", tail: F.ended)]))
            let start = Date()
            t.expectEqual(send(rig.port, "POST", AppConfig.signalPath, headers: tokenHeader, body: hook("UserPromptSubmit"))?.status, 204)
            t.expect(Date().timeIntervalSince(start) < 1, "answered before the Mac was tried")
            t.expectEqual(rig.source.currentRows.first?.session.status, SessionStatus.working.rawValue, "heard")
            Thread.sleep(forTimeInterval: 0.5)
            t.expectEqual(rig.tee.stats.undelivered, 1, "and counted as not taken")
            t.expectEqual(send(rig.port, "GET", AppConfig.sessionsPath, headers: tokenHeader)?.status, 503, "/sessions says the Mac is not there")
        },

        TestCase("A question the Mac holds: amber here with its text while held, the Mac's answer handed back") { t in
            let rig = rig()
            defer { rig.tee.stop(); rig.mac.stop(); F.remove(rig.paths) }
            rig.mac.delay = 1.5
            rig.mac.body = "allow.signed"
            rig.source.absorb(F.look([F.record(F.a, pid: 10, status: "busy")]))
            let check = #"{"v":1,"session":"\#(F.a)","id":"toolu_01","tool":"Bash","detail":"npm publish"}"#
            final class Box: @unchecked Sendable { var reply: Reply? }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                box.reply = send(rig.port, "POST", AppConfig.checkPath, body: check)
                done.signal()
            }
            Thread.sleep(forTimeInterval: 0.6)
            let held = rig.source.currentRows.first
            t.expectEqual(held?.session.status, SessionStatus.awaiting.rawValue, "amber while the Mac holds it, though the file says busy")
            t.expectEqual(held?.session.pendingAsk, "Bash: npm publish", "with the question")
            t.expectEqual(held?.extras.heldByMac, true, "and that the Mac holds it")
            _ = done.wait(timeout: .now() + 10)
            t.expectEqual(box.reply?.body, "allow.signed", "the Mac's answer, untouched: nothing here answers a permission")
            t.expect(rig.source.currentRows.first?.extras.heldByMac != true, "released when the Mac answered")
        },

        TestCase("With nobody on the Mac's port a question gets an unsigned ask: the session's own dialog") { t in
            let stub = StubMac()
            stub.stop()
            let rig = rig(mac: stub)
            defer { rig.tee.stop(); F.remove(rig.paths) }
            let check = #"{"v":1,"session":"\#(F.a)","id":"toolu_02","tool":"Bash","detail":"ls"}"#
            t.expectEqual(send(rig.port, "POST", AppConfig.checkPath, body: check)?.body, "ask")
            t.expect(rig.tee.hooks.heldQuestions.isEmpty, "nothing held")
        },

        TestCase("Green to read, red, and amber with its question, as the hooks say; a row no hook spoke for keeps the file's rule") { t in
            let rig = rig()
            defer { rig.tee.stop(); rig.mac.stop(); F.remove(rig.paths) }
            rig.source.absorb(F.look([F.record(F.a, pid: 10, status: "busy"), F.record(F.b, pid: 11, status: "busy"),
                                      F.record(F.c, pid: 12, status: "busy")]))
            _ = send(rig.port, "POST", AppConfig.signalPath, headers: tokenHeader,
                     body: hook("Stop", F.a, extra: #","last_assistant_message":"Done.""#))
            _ = send(rig.port, "POST", AppConfig.signalPath, headers: tokenHeader,
                     body: hook("StopFailure", F.b, extra: #","error_type":"rate_limit""#))
            let byId = Dictionary(uniqueKeysWithValues: rig.source.currentRows.map { ($0.id, $0) })
            t.expectEqual(byId[F.a]?.session.status, SessionStatus.ready.rawValue, "green")
            t.expectEqual(byId[F.b]?.session.status, SessionStatus.failed.rawValue, "red")
            t.expectEqual(byId[F.c]?.extras.stateBasis, .sessionFile, "unheard: the file's rule, unchanged")
            _ = send(rig.port, "POST", AppConfig.signalPath, headers: tokenHeader,
                     body: hook("PermissionRequest", F.c, extra: #","tool_name":"Bash","tool_input":{"command":"make deploy"}"#))
            let asked = rig.source.currentRows.first { $0.id == F.c }
            t.expectEqual(asked?.session.status, SessionStatus.awaiting.rawValue, "amber")
            t.expect(asked?.session.pendingAsk?.contains("make deploy") == true, "with its question: \(asked?.session.pendingAsk ?? "none")")
        },

        TestCase("A read from the phone clears the green in the hooks' state too") { t in
            let rig = rig()
            defer { rig.tee.stop(); rig.mac.stop(); F.remove(rig.paths) }
            rig.source.absorb(F.look([F.record(F.a, pid: 10, status: "idle", tail: F.ended)]))
            _ = send(rig.port, "POST", AppConfig.signalPath, headers: tokenHeader, body: hook("Stop", extra: #","last_assistant_message":"Done.""#))
            t.expectNil(rig.source.perform(V1Command(action: .markSeen, session: F.a), by: V1Peer(device: "test-phone", role: .read), at: Date()))
            t.expect(rig.source.currentRows.first?.session.status != SessionStatus.ready.rawValue, "read: no longer an answer to read")
        },
    ])
}
