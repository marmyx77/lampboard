import LampBoardCore
import Foundation
import TestKit

/// Transport: who can talk to the server, and from where.
///
/// These cases don't touch the traffic light logic. They verify the shell — the
/// socket, the token, the methods — which is the part no domain test sees and
/// which has already been got wrong once: `acceptLocalOnly` looked like it said
/// "this machine only" and actually said "this network only".
enum TransportSuite {

    static func suite(_ app: AppUnderTest) -> TestSuite {
        TestSuite("E2E · transport", [

            TestCase("/health answers without a token") { a in
                let result = app.raw(method: "GET", path: "/health", token: .some(nil))
                a.expectEqual(result.status, 200, "status")
                a.expect(result.body.contains("lampboard"), "body: \(result.body)")
            },

            TestCase("the socket is bound to 127.0.0.1, not to every interface") { a in
                let bindings = listeningAddresses(port: app.port)
                a.expect(!bindings.isEmpty, "lsof found no listening socket")

                // `*:port` means INADDR_ANY: reachable by anyone on the same
                // network. That is exactly what the previous version did while
                // believing it was doing the opposite.
                let wildcard = bindings.filter { $0.hasPrefix("*:") }
                a.expect(
                    wildcard.isEmpty,
                    "the server listens on every interface: \(wildcard.joined(separator: ", "))"
                )
                a.expect(
                    bindings.allSatisfy { $0.hasPrefix("127.0.0.1:") },
                    "unexpected addresses: \(bindings.joined(separator: ", "))"
                )
            },

            TestCase("/sessions without a token is refused") { a in
                let result = app.raw(method: "GET", path: AppConfig.sessionsPath, token: .some(nil))
                a.expectEqual(result.status, 401, "status")
            },

            TestCase("/sessions with the wrong token is refused") { a in
                let result = app.raw(
                    method: "GET",
                    path: AppConfig.sessionsPath,
                    token: .some(String(repeating: "a", count: AccessToken.byteCount * 2))
                )
                a.expectEqual(result.status, 401, "status")
            },

            TestCase("/sessions with the right token answers in JSON") { a in
                a.expectNotNil(app.sessions(), "decoded response")
            },

            TestCase("the token file has 0600 permissions") { a in
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: app.tokenFileURL.path
                )
                guard let permissions = attributes?[.posixPermissions] as? NSNumber else {
                    a.fail("token permissions unreadable")
                    return
                }
                a.expectEqual(permissions.int16Value & 0o777, 0o600, "permissions")
            },

            TestCase("the generated token has the expected shape") { a in
                guard let token = app.tokenValue else {
                    a.fail("no token read")
                    return
                }
                a.expect(AccessToken.isWellFormed(token), "malformed token: \(token)")
            },

            TestCase("POST on /sessions is not allowed") { a in
                let result = app.raw(method: "POST", path: AppConfig.sessionsPath)
                a.expectEqual(result.status, 405, "status")
            },

            TestCase("GET on /signal is not allowed") { a in
                let result = app.raw(method: "GET", path: AppConfig.signalPath)
                a.expectEqual(result.status, 405, "status")
            },

            // The three cases below pin the asymmetry `/signal` was given: a wrong
            // token is refused, an absent one is not. Every other case in this file
            // sends no token at all — `sendHook` doesn't — so the middle one is the
            // only place the grandfathering is stated on purpose rather than relied
            // on by accident.

            TestCase("/signal with the wrong token is refused") { a in
                let result = app.raw(
                    method: "POST",
                    path: AppConfig.signalPath,
                    token: .some(String(repeating: "b", count: AccessToken.byteCount * 2)),
                    body: signalBody(id: "e2e-wrong-token")
                )
                a.expectEqual(result.status, 401, "status")
            },

            TestCase("/signal with no token is still accepted") { a in
                // Not an oversight: hooks installed by an earlier version carry no
                // token and stay registered until somebody reinstalls them, here and
                // on every node the tunnel reaches. Requiring one is a later release.
                let result = app.raw(
                    method: "POST",
                    path: AppConfig.signalPath,
                    token: .some(nil),
                    body: signalBody(id: "e2e-no-token")
                )
                a.expectEqual(result.status, 204, "status")
            },

            TestCase("/signal with the right token is accepted") { a in
                let result = app.raw(
                    method: "POST",
                    path: AppConfig.signalPath,
                    body: signalBody(id: "e2e-right-token")
                )
                a.expectEqual(result.status, 204, "status")
            },

            TestCase("an unknown path answers 404") { a in
                let result = app.raw(method: "GET", path: "/something-that-does-not-exist")
                a.expectEqual(result.status, 404, "status")
            },

            TestCase("an unhandled event is not an error") { a in
                let status = app.sendHook([
                    "session_id": "e2e-ignored",
                    "hook_event_name": "PreCompact",
                    "cwd": "/tmp",
                ])
                // The hook script forwards everything: were this a 400, every
                // unmodelled event would end up in the log as a fault.
                a.expectEqual(status, 204, "status")
            },

            TestCase("a payload with no cwd is refused") { a in
                let status = app.sendHook([
                    "session_id": "e2e-incomplete",
                    "hook_event_name": "Stop",
                ])
                a.expectEqual(status, 400, "status")
            },

            TestCase("a relative cwd is refused") { a in
                let status = app.sendHook([
                    "session_id": "e2e-relative",
                    "hook_event_name": "Stop",
                    "cwd": "projects/something",
                ])
                a.expectEqual(status, 400, "status")
            },
        ])
    }

    // MARK: - Internal

    /// A payload the decoder accepts, so that a case about the token fails for the
    /// token and never for a missing field.
    private static func signalBody(id: String) -> String {
        """
        {"session_id":"\(id)","hook_event_name":"Stop","cwd":"/tmp"}
        """
    }

    /// The addresses the process is really listening on, read from `lsof`.
    ///
    /// The operating system is queried instead of trusting how the listener was
    /// configured: that is the difference between verifying the intention and
    /// verifying the fact, and it is precisely where the defect was hiding.
    private static func listeningAddresses(port: UInt16) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // The `-Fn` format emits one line per field, prefixed by its type:
        // the ones starting with `n` are the address names.
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .filter { $0.hasPrefix("n") }
            .map { String($0.dropFirst()) }
    }
}
