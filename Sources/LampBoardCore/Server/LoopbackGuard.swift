import Foundation

/// Which requests the local server refuses before reading them: anything a web
/// page could have sent.
///
/// The socket is bound to loopback, so nothing on the network reaches it. A
/// page open in a browser on this Mac does, two ways. It can post to
/// `127.0.0.1` directly — and `/signal` accepts a signal with no token, for the
/// hooks installed before tokens existed — and it can rebind a name it owns to
/// `127.0.0.1` and then read what the server answers as its own origin. Both
/// carry marks no hook, mod, script or `curl` does: a browser sends `Origin` on
/// every cross-site request and on every POST, and a rebound name arrives as the
/// `Host`. Refusing those two closes both, and costs a real client nothing.
public enum LoopbackGuard {

    /// Why a request is refused, or `nil` when it may go on.
    public static func refusal(host: String?, origin: String?) -> String? {
        if origin != nil { return "requests from a web page are not accepted" }
        guard let host else { return nil }
        return isLoopback(host: host) ? nil : "only 127.0.0.1 and localhost are served"
    }

    /// `127.0.0.1`, `localhost` or `[::1]`, with or without a port.
    static func isLoopback(host raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let name: Substring
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            name = host[host.index(after: host.startIndex)..<close]
            let rest = host[host.index(after: close)...]
            guard rest.isEmpty || isPort(rest) else { return false }
        } else {
            let parts = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            name = parts[0]
            guard parts.count == 1 || isPort(":" + parts[1]) else { return false }
        }
        return ["127.0.0.1", "localhost", "::1"].contains(String(name))
    }

    private static func isPort(_ text: Substring) -> Bool {
        guard text.first == ":", let port = Int(text.dropFirst()) else { return false }
        return (1...65_535).contains(port)
    }
}
