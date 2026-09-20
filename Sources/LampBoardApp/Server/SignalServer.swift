import LampBoardCore
import Foundation
import Network

/// Server startup errors.
enum SignalServerError: LocalizedError {
    case invalidPort(UInt16)
    case portInUse(UInt16)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid port: \(port)"
        case .portInUse(let port):
            return "Port \(port) is already taken. Is another instance of lampboard running?"
        case .failed(let reason):
            return "Server startup failed: \(reason)"
        }
    }
}

/// Local HTTP server receiving the signals from the Claude Code hooks.
///
/// It listens **only on 127.0.0.1**, and the constraint is explicit:
/// `requiredLocalEndpoint` binds the socket to the loopback address.
///
/// The previous version relied on `acceptLocalOnly`, which does not do this. That
/// flag limits to the *local link* — that is, to the network the Mac is attached
/// to, not to the machine — and indeed `lsof` showed `TCP *:9877 (LISTEN)`: the
/// socket was reachable by anyone on the Wi-Fi. With one endpoint exposing
/// workspace names, and another accepting signals capable of driving the panel's
/// state, that is not a nuance.
final class SignalServer {
    private let port: UInt16
    /// A **concurrent** queue, and that is not a detail.
    ///
    /// With a serial queue, a request that waits — `/next` has to cross over to
    /// the main actor to raise a window — would also block reading the hooks'
    /// `POST /signal`, because they share the same thread. The result would be
    /// that a shortcut pressed at the wrong moment adds latency to a Claude Code
    /// turn: exactly what the rest of this project takes care not to do.
    ///
    /// Connections share no mutable state with each other — every buffer is local
    /// to its own recursion — so concurrency here introduces no races.
    private let queue = DispatchQueue(
        label: "com.lampboard.server", qos: .utility, attributes: .concurrent
    )
    private let onSignal: (HookSignal) -> Void
    private let onError: (String) -> Void
    private let onQuery: () -> [SessionSnapshot]
    private let onNext: () -> String?
    private let onOpenSlot: (Int) -> String?
    private let onNewInSlot: (Int) -> String?
    private let onChatInSlot: (Int) -> String?
    private let token: String?

    private var listener: NWListener?

    init(
        port: UInt16 = AppConfig.listenPort,
        token: String? = nil,
        onSignal: @escaping (HookSignal) -> Void,
        onError: @escaping (String) -> Void,
        onQuery: @escaping () -> [SessionSnapshot] = { [] },
        onNext: @escaping () -> String? = { nil },
        onOpenSlot: @escaping (Int) -> String? = { _ in nil },
        onNewInSlot: @escaping (Int) -> String? = { _ in nil },
        onChatInSlot: @escaping (Int) -> String? = { _ in nil }
    ) {
        self.port = port
        self.token = token
        self.onSignal = onSignal
        self.onError = onError
        self.onQuery = onQuery
        self.onNext = onNext
        self.onOpenSlot = onOpenSlot
        self.onNewInSlot = onNewInSlot
        self.onChatInSlot = onChatInSlot
    }

    // MARK: - Lifecycle

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SignalServerError.invalidPort(port)
        }

        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        // This is the line that binds the socket to loopback, not the one above.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw SignalServerError.portInUse(port)
        }

        listener.stateUpdateHandler = { [onError] state in
            if case .failed(let error) = state {
                onError("The server stopped: \(error.localizedDescription)")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: AppConfig.maxRequestBodyBytes
        ) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            let accumulated = buffer + (chunk ?? Data())

            switch HTTPRequestParser.parse(accumulated) {
            case .incomplete:
                guard !isComplete else {
                    connection.cancel()
                    return
                }
                self.receive(on: connection, buffer: accumulated)

            case .malformed(let reason):
                self.reply(on: connection, HTTPRequestParser.response(
                    status: 400, reason: "Bad Request", body: reason
                ))

            case .complete(let request, _):
                self.reply(on: connection, self.handle(request))
            }
        }
    }

    /// Translates a request into a response, emitting the signal when it is valid.
    private func handle(_ request: HTTPRequest) -> Data {
        switch request.path {
        case AppConfig.signalPath:
            return handleSignal(request)

        case AppConfig.sessionsPath:
            return handleSessions(request)

        case AppConfig.nextPath:
            return handleNext(request)

        case AppConfig.openPath:
            return handleSlotRoute(request, action: onOpenSlot)

        case AppConfig.newConversationPath:
            return handleSlotRoute(request, action: onNewInSlot)

        case AppConfig.chatPath:
            return handleSlotRoute(request, action: onChatInSlot)

        // Courtesy endpoint: lets you check that the app is alive.
        case AppConfig.healthPath:
            return HTTPRequestParser.response(status: 200, reason: "OK", body: "lampboard")

        default:
            return HTTPRequestParser.response(status: 404, reason: "Not Found")
        }
    }

    /// `GET /sessions` — the column state as JSON, behind the token.
    private func handleSessions(_ request: HTTPRequest) -> Data {
        guard request.method == "GET" else {
            return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed")
        }

        guard let token else {
            return HTTPRequestParser.response(
                status: 503,
                reason: "Service Unavailable",
                body: "endpoint closed: no token available"
            )
        }

        guard AccessToken.matches(
            request.header(AccessToken.headerName, orLegacy: AccessToken.legacyHeaderName),
            expected: token
        ) else {
            // No detail about what was wrong: a message distinguishing "token
            // missing" from "token incorrect" is already half an oracle.
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }

        do {
            let payload = try SessionsCodec.encode(
                SessionsResponse(generatedAt: Date(), sessions: onQuery())
            )
            return HTTPRequestParser.response(
                status: 200, reason: "OK", body: payload, contentType: "application/json"
            )
        } catch {
            onError("Serializing the sessions failed: \(error.localizedDescription)")
            return HTTPRequestParser.response(status: 500, reason: "Internal Server Error")
        }
    }

    /// `POST /next` — raises the window of the next waiting session.
    ///
    /// This is a route that **raises windows**, not one that colors dots: the
    /// separation matters, because it is the only one acting outside the process
    /// and it deserves authentication even when the other doesn't have it.
    private func handleNext(_ request: HTTPRequest) -> Data {
        guard request.method == "POST" else {
            return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed")
        }
        guard let token else {
            return HTTPRequestParser.response(status: 503, reason: "Service Unavailable")
        }
        guard AccessToken.matches(
            request.header(AccessToken.headerName, orLegacy: AccessToken.legacyHeaderName),
            expected: token
        ) else {
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }

        guard let description = onNext() else {
            // 204: the request succeeded, there simply was nothing to raise.
            // A 404 would suggest the route was wrong.
            return HTTPRequestParser.response(status: 204, reason: "No Content")
        }
        return HTTPRequestParser.response(status: 200, reason: "OK", body: description)
    }

    /// The two slot-addressed routes: `POST /open` raises, `POST /new` opens a
    /// fresh conversation. They differ only in the action, so they share
    /// everything else — method, authentication, validation and the three answers.
    ///
    /// Authenticated like `/next`, and for the same reason: they act on windows.
    /// The slot travels in the body rather than the path so the minimal parser
    /// keeps matching exact routes — a router that has to interpret path segments
    /// is a router with a parsing bug waiting in it.
    private func handleSlotRoute(
        _ request: HTTPRequest,
        action: (Int) -> String?
    ) -> Data {
        guard request.method == "POST" else {
            return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed")
        }
        guard let token else {
            return HTTPRequestParser.response(status: 503, reason: "Service Unavailable")
        }
        guard AccessToken.matches(
            request.header(AccessToken.headerName, orLegacy: AccessToken.legacyHeaderName),
            expected: token
        ) else {
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }

        let raw = String(data: request.body, encoding: .utf8)?.trimmed ?? ""
        guard let slot = Int(raw), (1...AppConfig.maxSlots).contains(slot) else {
            return HTTPRequestParser.response(
                status: 400, reason: "Bad Request",
                body: "slot must be a number from 1 to \(AppConfig.maxSlots), received: “\(raw)”"
            )
        }

        guard let description = action(slot) else {
            // 204, exactly like `/next` with nothing waiting: the request was
            // understood and that slot simply holds nothing right now. Answering
            // 404 would suggest the route was wrong.
            return HTTPRequestParser.response(status: 204, reason: "No Content")
        }
        return HTTPRequestParser.response(status: 200, reason: "OK", body: description)
    }

    /// `POST /signal` — the hooks' entry point.
    ///
    /// A token that is **present and wrong** is refused; one that is **absent** is
    /// let through. That asymmetry is the whole point, and it is deliberate.
    ///
    /// WHY THIS ENDPOINT IS NO LONGER WIDE OPEN
    /// It used to accept anything, and `AccessToken` explained why: a hook failing
    /// authentication would block a Claude Code turn for the sake of a decorative
    /// widget. Measured instead of assumed, that premise turns out to be false. A
    /// hook whose endpoint refuses it costs the turn nothing — three runs against a
    /// dead port came in at 7.2, 7.4 and 8.4 seconds against a baseline of 7.2, 8.5
    /// and 7.9 — and a `401` answer is swallowed in silence, printing nothing to the
    /// person at the keyboard. The script has always ignored the response anyway: it
    /// pipes it to `/dev/null` and exits 0 regardless.
    ///
    /// WHY AN ABSENT TOKEN IS STILL ACCEPTED
    /// Hooks installed by an earlier version carry no token, and they stay in
    /// `settings.json` until somebody reinstalls them — on this machine and on every
    /// node the tunnel reaches. Demanding one today would turn the column grey on
    /// upgrade, which is the failure this project treats as the worst kind: silent,
    /// and looking exactly like nothing happening. Requiring it is a separate
    /// release, once the installed base has turned over.
    private func handleSignal(_ request: HTTPRequest) -> Data {
        guard request.method == "POST" else {
            return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed")
        }

        let presented = request.header(
            AccessToken.headerName, orLegacy: AccessToken.legacyHeaderName
        )
        if let presented, let token, !AccessToken.matches(presented, expected: token) {
            // Same silence as the other routes: saying whether the token was
            // missing or merely wrong is already half an oracle.
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }

        do {
            let signal = try HookPayloadDecoder.decode(
                request.body,
                entrypoint: request.header(AppConfig.entrypointHeader),
                host: request.header(
                    AppConfig.remoteHostHeader,
                    orLegacy: AppConfig.legacyRemoteHostHeader
                ),
                harness: Harness.named(request.header(AppConfig.harnessHeader)),
                // Resolved by the script, in the session's own directory, because
                // this process must never read under somebody's working folder.
                git: GitIdentity.from(
                    repo: request.header(AppConfig.repoHeader),
                    branch: request.header(AppConfig.branchHeader),
                    worktree: request.header(AppConfig.worktreeHeader)
                )
            )
            // Who will answer a Codex permission request is not on the wire: it
            // is in the session's rollout, which this event names. Resolved here,
            // at the edge, so the reducer keeps receiving facts and never a path.
            onSignal(signal.withApprovalReviewer(CodexApprovalReader.reviewer(for: signal)))
            return HTTPRequestParser.response(status: 204, reason: "No Content")
        } catch let error as HookPayloadError {
            // An irrelevant event is business as usual, not a fault: the hook
            // script forwards everything and the filter lives here.
            if error.isFailure {
                onError("Payload rejected: \(error.description)")
                return HTTPRequestParser.response(
                    status: 400, reason: "Bad Request", body: error.description
                )
            }
            return HTTPRequestParser.response(status: 204, reason: "No Content")
        } catch {
            onError("Unexpected error: \(error.localizedDescription)")
            return HTTPRequestParser.response(status: 500, reason: "Internal Server Error")
        }
    }

    private func reply(on connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
