import Foundation
import LampBoardCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The hooks' port in tee (W5, §2.3): every hook and every report of the mod
/// still reaches the Mac — through its tunnel, now on the next port — and is
/// read here on the way, so this machine's rows are heard rather than guessed
/// from its files, and its notifications leave from here.
///
/// Each connection has a thread of its own; nothing here ever runs on the main
/// loop, whose beat is the watchdog's (ADR-65 point 6). What the route table
/// does not name is refused and logged.
public final class HookTee: @unchecked Sendable {

    public struct Stats: Equatable, Sendable {
        public var received = 0
        public var forwarded = 0
        /// Passed on but nobody took it: the Mac away, asleep, or its tunnel
        /// on the hooks' port itself.
        public var undelivered = 0
        public var refused = 0
        public var lastForwardAt: Date?
        public var lastUndeliveredAt: Date?
    }

    public let hooks: NodeHooks
    /// The port the Mac's tunnel listens on here when `lampd` holds the hooks'.
    public let macPort: UInt16
    private let tokenFile: String
    private let log: (String) -> Void
    /// Called after anything that changes a row: the source publishes it.
    private let changed: (Date) -> Void
    /// This process's name for the events it passes on (E3): the Mac 2.4 drops
    /// one whose `X-LampBoard-Event` it has already taken.
    public let name = "tee-" + String(UInt64.random(in: 0...UInt64.max), radix: 36)
    private let lock = NSLock()
    private var counter = 0
    private var statsValue = Stats()
    private var listener: Int32 = -1

    public init(hooks: NodeHooks, macPort: UInt16, tokenFile: String, log: @escaping (String) -> Void,
                changed: @escaping (Date) -> Void) {
        self.hooks = hooks
        self.macPort = macPort
        self.tokenFile = tokenFile
        self.log = log
        self.changed = changed
    }

    public var stats: Stats { locked { statsValue } }

    /// The token the hooks already send (§2.3, the token adopted): the one the
    /// Mac wrote in `~/.lampboard/token`, read again at every request so a
    /// repair that writes a new one is followed. Never one made here: a new
    /// token would put out the colours of every session already running.
    public var adoptedToken: String? {
        guard let text = try? String(contentsOfFile: tokenFile, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    // MARK: - Serving

    /// Accepts on `fd` until `stop`, each connection on a thread of its own.
    public func serve(_ fd: Int32) {
        locked { listener = fd }
        Thread.detachNewThread { [self] in
            while let connection = UnixSocket.accept(fd) {
                Thread.detachNewThread { [self] in handle(connection) }
            }
        }
    }

    /// Lets the port go (`lampd release`).
    public func stop() {
        let fd = locked { () -> Int32 in let fd = listener; listener = -1; return fd }
        guard fd >= 0 else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }

    public var isServing: Bool { locked { listener >= 0 } }

    func handle(_ fd: Int32) {
        LoopbackTCP.setTimeouts(fd, seconds: 5)
        guard let request = Self.read(fd) else {
            UnixSocket.sendAll(fd, Array(HTTPRequestParser.response(status: 400, reason: "Bad Request")))
            close(fd)
            return
        }
        let reply = answer(request, on: fd)
        if let reply { UnixSocket.sendAll(fd, Array(reply)) }
        close(fd)
    }

    /// One request read whole, or `nil`.
    public static func read(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        while true {
            switch HTTPRequestParser.parse(buffer) {
            case .complete(let request, _): return request
            case .malformed: return nil
            case .incomplete:
                guard let bytes = UnixSocket.readSome(fd) else { return nil }
                buffer.append(contentsOf: bytes)
            }
        }
    }

    /// The answer to `request`; `nil` when it was already written on `fd`
    /// (an answer passed on byte for byte).
    func answer(_ request: HTTPRequest, on fd: Int32) -> Data? {
        if let refusal = LoopbackGuard.refusal(host: request.header("Host"), origin: request.header("Origin")) {
            return refuse(request, status: 403, "Forbidden", refusal)
        }
        guard let route = HookRoutes.route(method: request.method, path: request.path) else {
            return refuse(request, status: 404, "Not Found", "no route \(request.path) on lampd")
        }
        switch route.owner {
        case .serve:
            return HTTPRequestParser.response(status: 200, reason: "OK", body: "lampboard")
        case .refuse:
            return refuse(request, status: 403, "Forbidden", "refused by lampd: \(route.why)")
        case .notFound:
            return refuse(request, status: 404, "Not Found", "not on this machine: \(route.why)")
        case .readAndForward:
            let reply = route.path == AppConfig.modPath ? readMod(request) : readSignal(request)
            if reply.passOn {
                let bytes = forwardBytes(request)
                Thread.detachNewThread { [self] in deliver(bytes, wait: route.wait, to: nil) }
            }
            return reply.answer
        case .forward:
            return pass(request, wait: route.wait, on: fd) ? nil
                : HTTPRequestParser.response(status: 503, reason: "Service Unavailable", body: "the Mac is not listening")
        case .forwardAndObserve:
            return observe(request, route: route, on: fd)
        }
    }

    private func refuse(_ request: HTTPRequest, status: Int, _ reason: String, _ body: String) -> Data {
        locked { statsValue.refused += 1 }
        log("hooks: \(request.method) \(request.path) refused (\(status)): \(body)")
        return HTTPRequestParser.response(status: status, reason: reason, body: body)
    }

    // MARK: - Read here

    /// `/signal`, as the Mac's `SignalServer` takes it: a wrong token is
    /// refused, none is taken (a hook installed before tokens), an event no hook
    /// is registered for is no fault.
    private func readSignal(_ request: HTTPRequest) -> (answer: Data, passOn: Bool) {
        guard request.method == "POST" else { return (HTTPRequestParser.response(status: 405, reason: "Method Not Allowed"), false) }
        let presented = request.header(AccessToken.headerName, orLegacy: AccessToken.legacyHeaderName)
        if let presented, let token = adoptedToken, !AccessToken.matches(presented, expected: token) {
            return (refuse(request, status: 401, "Unauthorized", ""), false)
        }
        locked { statsValue.received += 1 }
        do {
            let signal = try HookPayloadDecoder.decode(
                request.body, entrypoint: request.header(AppConfig.entrypointHeader),
                harness: Harness.named(request.header(AppConfig.harnessHeader)),
                git: GitIdentity.from(repo: request.header(AppConfig.repoHeader), branch: request.header(AppConfig.branchHeader),
                                      worktree: request.header(AppConfig.worktreeHeader))
            )
            let now = Date()
            hooks.signal(signal, at: now)
            changed(now)
            return (HTTPRequestParser.response(status: 204, reason: "No Content"), true)
        } catch let error as HookPayloadError {
            if error.isFailure {
                log("hooks: a signal refused: \(error.description)")
                return (HTTPRequestParser.response(status: 400, reason: "Bad Request", body: error.description), true)
            }
            return (HTTPRequestParser.response(status: 204, reason: "No Content"), true)
        } catch {
            return (HTTPRequestParser.response(status: 500, reason: "Internal Server Error"), true)
        }
    }

    /// `/mod`: the token is required, as on the Mac.
    private func readMod(_ request: HTTPRequest) -> (answer: Data, passOn: Bool) {
        guard request.method == "POST" else { return (HTTPRequestParser.response(status: 405, reason: "Method Not Allowed"), false) }
        guard let token = adoptedToken else {
            return (HTTPRequestParser.response(status: 503, reason: "Service Unavailable", body: "no token on this machine"), false)
        }
        guard AccessToken.matches(request.header(AccessToken.headerName), expected: token) else {
            return (refuse(request, status: 401, "Unauthorized", ""), false)
        }
        locked { statsValue.received += 1 }
        do {
            let now = Date()
            hooks.mod(try ModReport.decode(request.body), at: now)
            changed(now)
            return (HTTPRequestParser.response(status: 204, reason: "No Content"), true)
        } catch {
            return (HTTPRequestParser.response(status: 400, reason: "Bad Request", body: "\(error)"), true)
        }
    }

    /// `/check` and `/question`: the Mac holds the question (D80, D86) and
    /// answers it; while it does the row is amber with its text, and the push
    /// leaves as soon as the amber has lasted the planner's four seconds (M9).
    /// With nobody listening the answer is an unsigned `ask`: the mod trusts
    /// only a signed one, so the session shows its own dialog — nothing on this
    /// machine answers a permission (R3, R4).
    private func observe(_ request: HTTPRequest, route: HookRoutes.Route, on fd: Int32) -> Data? {
        guard request.method == "POST" else { return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed") }
        let now = Date()
        let decoded = route.path == AppConfig.questionPath
            ? QuestionGate.decode(request.body, at: now) : PermissionGate.decode(request.body, at: now)
        let entry = decoded.map { hooks.hold($0, at: now) }
        if let entry {
            changed(now)
            // The planner announces an amber four seconds into its spell: look
            // again then, not at the next look five seconds later.
            DispatchQueue.global().asyncAfter(deadline: .now() + PushPlanner.amberDelay + 0.3) { [self] in
                if hooks.heldQuestions.contains(entry) { changed(Date()) }
            }
        }
        defer {
            if let entry {
                hooks.release(entry)
                changed(Date())
            }
        }
        if pass(request, wait: route.wait, on: fd) { return nil }
        return HTTPRequestParser.response(status: 200, reason: "OK", body: PermissionGate.Verdict.ask.rawValue)
    }

    // MARK: - To the Mac

    /// The request as the Mac receives it, named (E3).
    func forwardBytes(_ request: HTTPRequest) -> [UInt8] {
        let id = locked { () -> String in counter += 1; return "\(name)-\(counter)" }
        var head = "\(request.method) \(request.path) HTTP/1.1\r\n"
        let skipped: Set<String> = ["content-length", "connection", MacNodeLink.eventHeader.lowercased()]
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) where !skipped.contains(name) {
            head += "\(name): \(value)\r\n"
        }
        head += "\(MacNodeLink.eventHeader): \(id)\r\nContent-Length: \(request.body.count)\r\nConnection: close\r\n\r\n"
        return Array(head.utf8) + Array(request.body)
    }

    /// Passes `request` on and copies the answer back to `fd` as it comes;
    /// `false` when the Mac could not be reached (nothing written).
    private func pass(_ request: HTTPRequest, wait: TimeInterval, on fd: Int32) -> Bool {
        deliver(forwardBytes(request), wait: wait, to: fd)
    }

    /// Sends `bytes` to the Mac's port; with `answerTo`, copies the answer
    /// there, else reads it and drops it.
    @discardableResult
    func deliver(_ bytes: [UInt8], wait: TimeInterval, to answerTo: Int32?) -> Bool {
        guard let mac = LoopbackTCP.connect(port: macPort, timeout: 1) else {
            locked {
                statsValue.undelivered += 1
                statsValue.lastUndeliveredAt = Date()
            }
            return false
        }
        defer { close(mac) }
        LoopbackTCP.setTimeouts(mac, seconds: wait)
        guard UnixSocket.sendAll(mac, bytes) else {
            locked { statsValue.undelivered += 1 }
            return false
        }
        locked {
            statsValue.forwarded += 1
            statsValue.lastForwardAt = Date()
        }
        if let answerTo {
            LoopbackTCP.setTimeouts(answerTo, seconds: wait)
            while let piece = UnixSocket.readSome(mac) {
                if !UnixSocket.sendAll(answerTo, piece) { break }
            }
        } else {
            _ = LoopbackTCP.readAll(mac, limit: 1 << 20)
        }
        return true
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
