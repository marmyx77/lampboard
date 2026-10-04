import LampBoardCore
import Foundation
import TestKit

/// The two marks of a browser on the local server: `Origin`, and a `Host` that
/// is not loopback (a rebound name).
enum LoopbackGuardSuite {

    static let suite = TestSuite("Requests a web page could have sent", [

        TestCase("The hooks, the mod and curl pass: loopback hosts, no Origin") { t in
            for host in ["127.0.0.1:9877", "127.0.0.1", "localhost:9877", "LOCALHOST", "[::1]:9877", "[::1]"] {
                t.expectNil(LoopbackGuard.refusal(host: host, origin: nil), host)
            }
            t.expectNil(LoopbackGuard.refusal(host: nil, origin: nil), "an HTTP/1.0 client with no Host")
        },

        TestCase("Any Origin is refused, even a loopback one") { t in
            t.expectNotNil(LoopbackGuard.refusal(host: "127.0.0.1:9877", origin: "https://evil.example"))
            t.expectNotNil(LoopbackGuard.refusal(host: "127.0.0.1:9877", origin: "http://127.0.0.1:9877"),
                           "a page served from this Mac is still a page")
            t.expectNotNil(LoopbackGuard.refusal(host: "127.0.0.1:9877", origin: "null"), "a sandboxed frame")
        },

        // DNS rebinding: the page's own name, now pointing at 127.0.0.1.
        TestCase("A Host that is not loopback is refused") { t in
            for host in ["rebind.example:9877", "127.0.0.1.evil.example", "localhost.evil.example:9877",
                         "127.0.0.1:99999", "127.0.0.1:x", "127.0.0.1:", "localhost.", "127.1", "[::1", "[::1]x", "192.168.1.10:9877", ""] {
                t.expectNotNil(LoopbackGuard.refusal(host: host, origin: nil), "host «\(host)»")
            }
        },
    ])
}
