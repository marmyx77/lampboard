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
    private let onLampMaster: () -> Data
    private let onLampMasterRound: () -> Bool
    private let onLampMasterTool: (Data) -> Data
    private let onMod: (ModReport) -> Void
    private let onWatch: (WatchReport) -> Void
    private let onCheck: (Data, String?, String?, String) -> String
    private let onChecks: () -> Data
    private let onCheckAnswer: (Data) -> Bool
    private let onQuestion: (Data, String?, String?, String) -> String
    private let onBand: (String?) -> Data
    private let onBandOpen: (String) -> Bool
    private let onHandoff: (Data, String?, String?, String) -> String
    /// The decision board (D105): a change or `nil` to list → status and body.
    private let onDecisions: (Data?) -> (Int, String)
    /// The mod's question for its session's board → the signed answer.
    private let onModDecisions: (Data, String?, String?, String) -> String
    /// The mod's question for its session's model → the signed answer (G3).
    private let onModGovernor: (Data, String?, String?, String) -> String
    /// The mod's question before a write → the signed answer (§4.4).
    private let onModRadar: (Data, String?, String?, String) -> String
    private let token: String?
    private let checkKey: String?

    private var listener: NWListener?

    init(
        port: UInt16 = AppConfig.listenPort,
        token: String? = nil,
        checkKey: String? = nil,
        onSignal: @escaping (HookSignal) -> Void,
        onError: @escaping (String) -> Void,
        onQuery: @escaping () -> [SessionSnapshot] = { [] },
        onNext: @escaping () -> String? = { nil },
        onOpenSlot: @escaping (Int) -> String? = { _ in nil },
        onNewInSlot: @escaping (Int) -> String? = { _ in nil },
        onChatInSlot: @escaping (Int) -> String? = { _ in nil },
        onLampMaster: @escaping () -> Data = { Data("{}".utf8) },
        onLampMasterRound: @escaping () -> Bool = { false },
        onLampMasterTool: @escaping (Data) -> Data = { _ in Data("{}".utf8) },
        onMod: @escaping (ModReport) -> Void = { _ in },
        onWatch: @escaping (WatchReport) -> Void = { _ in },
        onCheck: @escaping (Data, String?, String?, String) -> String = { _, _, _, _ in "ask" },
        onChecks: @escaping () -> Data = { Data("[]".utf8) },
        onCheckAnswer: @escaping (Data) -> Bool = { _ in false },
        onQuestion: @escaping (Data, String?, String?, String) -> String = { _, _, _, _ in "ask" },
        onBand: @escaping (String?) -> Data = { _ in Band.json([]) },
        onBandOpen: @escaping (String) -> Bool = { _ in false },
        onHandoff: @escaping (Data, String?, String?, String) -> String = { _, _, _, _ in "LampBoard cannot take a handoff here." },
        onDecisions: @escaping (Data?) -> (Int, String) = { _ in (503, "no decision board here") },
        onModDecisions: @escaping (Data, String?, String?, String) -> String = { _, _, _, _ in "" },
        onModGovernor: @escaping (Data, String?, String?, String) -> String = { _, _, _, _ in "" },
        onModRadar: @escaping (Data, String?, String?, String) -> String = { _, _, _, _ in "" }
    ) {
        self.port = port
        self.token = token
        self.checkKey = checkKey
        self.onSignal = onSignal
        self.onError = onError
        self.onQuery = onQuery
        self.onNext = onNext
        self.onOpenSlot = onOpenSlot
        self.onNewInSlot = onNewInSlot
        self.onChatInSlot = onChatInSlot
        self.onLampMaster = onLampMaster
        self.onLampMasterRound = onLampMasterRound
        self.onLampMasterTool = onLampMasterTool
        self.onMod = onMod
        self.onWatch = onWatch
        self.onCheck = onCheck
        self.onChecks = onChecks
        self.onCheckAnswer = onCheckAnswer
        self.onQuestion = onQuestion
        self.onBand = onBand
        self.onBandOpen = onBandOpen
        self.onHandoff = onHandoff
        self.onDecisions = onDecisions
        self.onModDecisions = onModDecisions
        self.onModGovernor = onModGovernor
        self.onModRadar = onModRadar
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
        // Before any route, health included: what a web page sends is refused
        // whatever it asks for (`LoopbackGuard`).
        if let refusal = LoopbackGuard.refusal(host: request.header("Host"), origin: request.header("Origin")) {
            // Under LAMPBOARD_DEBUG only: a client of ours refused here would turn
            // the column grey with nothing anywhere saying why.
            Diagnostics.log("refused \(request.method) \(request.path): \(refusal)")
            return HTTPRequestParser.response(status: 403, reason: "Forbidden", body: refusal)
        }
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

        case AppConfig.lampMasterPath:
            return handleLampMaster(request)

        case AppConfig.lampMasterToolPath:
            return handleLampMasterTool(request)

        case AppConfig.modPath:
            return handleMod(request)

        case AppConfig.watchPath:
            return handleWatch(request)

        case AppConfig.checkPath:
            return handleCheck(request)

        case AppConfig.checkAnswerPath:
            return handleCheckAnswer(request)

        case AppConfig.questionPath:
            // Proven with the permission key, as `/check` is (D80, D86).
            guard request.method == "POST" else { return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed") }
            guard let checkKey else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
            return HTTPRequestParser.response(status: 200, reason: "OK", body: onQuestion(
                request.body, request.header("X-LampBoard-Nonce"), request.header("X-LampBoard-Proof"), checkKey))

        case AppConfig.bandPath:
            return handleBand(request)

        case AppConfig.handoffPath:
            // Behind the token and proven with the permission key, as `/question`
            // is (D80, D91): the token travels with every hook, and with it alone
            // anyone could put words in a composer under any session's name.
            // The answer is what the session shows the person.
            guard request.method == "POST" else { return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed") }
            guard let token, let checkKey else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
            guard AccessToken.matches(request.header(AccessToken.headerName, orLegacy: AccessToken.legacyHeaderName), expected: token)
            else { return HTTPRequestParser.response(status: 401, reason: "Unauthorized") }
            return HTTPRequestParser.response(status: 200, reason: "OK", body: onHandoff(
                request.body, request.header("X-LampBoard-Nonce"), request.header("X-LampBoard-Proof"), checkKey))

        case AppConfig.bandOpenPath:
            return handleBandOpen(request)

        case AppConfig.decisionsPath:
            // Behind the token: GET lists the board, POST pins or takes off.
            guard request.method == "GET" || request.method == "POST" else {
                return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed")
            }
            guard let token else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
            guard AccessToken.matches(request.header(AccessToken.headerName, orLegacy: AccessToken.legacyHeaderName), expected: token)
            else { return HTTPRequestParser.response(status: 401, reason: "Unauthorized") }
            let (status, body) = onDecisions(request.method == "POST" ? request.body : nil)
            let reason = [200: "OK", 400: "Bad Request"][status] ?? "Internal Server Error"
            return HTTPRequestParser.response(status: status, reason: reason, body: body)

        case AppConfig.modRadarPath:
            // A sentence put in front of the person, naming another session: proven both ways.
            guard request.method == "POST" else { return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed") }
            guard let token, let checkKey else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
            guard AccessToken.matches(request.header(AccessToken.headerName, orLegacy: AccessToken.legacyHeaderName), expected: token)
            else { return HTTPRequestParser.response(status: 401, reason: "Unauthorized") }
            return HTTPRequestParser.response(status: 200, reason: "OK", body: onModRadar(
                request.body, request.header("X-LampBoard-Nonce"), request.header("X-LampBoard-Proof"), checkKey))

        case AppConfig.modGovernorPath:
            // Proven both ways like the board (D105): a model is spend.
            guard request.method == "POST" else { return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed") }
            guard let token, let checkKey else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
            guard AccessToken.matches(request.header(AccessToken.headerName, orLegacy: AccessToken.legacyHeaderName), expected: token)
            else { return HTTPRequestParser.response(status: 401, reason: "Unauthorized") }
            return HTTPRequestParser.response(status: 200, reason: "OK", body: onModGovernor(
                request.body, request.header("X-LampBoard-Nonce"), request.header("X-LampBoard-Proof"), checkKey))

        case AppConfig.modDecisionsPath:
            // What this answers enters a conversation: the token, and the
            // permission key both ways (D80, D105). An unproven request gets
            // an empty answer, which the mod reads as nothing to add.
            guard request.method == "POST" else { return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed") }
            guard let token, let checkKey else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
            guard AccessToken.matches(request.header(AccessToken.headerName, orLegacy: AccessToken.legacyHeaderName), expected: token)
            else { return HTTPRequestParser.response(status: 401, reason: "Unauthorized") }
            return HTTPRequestParser.response(status: 200, reason: "OK", body: onModDecisions(
                request.body, request.header("X-LampBoard-Nonce"), request.header("X-LampBoard-Proof"), checkKey))

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

    /// `GET /lampmaster` — LampMaster's state; `POST` asks for a round now.
    ///
    /// Behind the token both ways: the state quotes conversations, and a round
    /// spends the user's allowance. The POST answers at once with 202 and the
    /// round runs on its own; whoever asked reads the outcome with a GET. A
    /// connection held open for two minutes would be one more way to tie up
    /// the server.
    private func handleLampMaster(_ request: HTTPRequest) -> Data {
        guard request.method == "GET" || request.method == "POST" else {
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
        guard request.method == "POST" else {
            return HTTPRequestParser.response(
                status: 200, reason: "OK", body: onLampMaster(), contentType: "application/json"
            )
        }
        guard onLampMasterRound() else {
            // 409, not 202: the request was dropped, and the caller should know.
            return HTTPRequestParser.response(status: 409, reason: "Conflict", body: "a round is already running")
        }
        return HTTPRequestParser.response(status: 202, reason: "Accepted", body: "round requested")
    }

    /// `POST /lampmaster/tool` — a session's tool call, forwarded by the
    /// `lampmaster` MCP server. Unlike a round, the caller waits for the answer:
    /// it is the tool's result. The wait is bounded inside `onLampMasterTool`,
    /// and the queue is concurrent, so the hooks are never held behind it.
    private func handleLampMasterTool(_ request: HTTPRequest) -> Data {
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
        return HTTPRequestParser.response(
            status: 200, reason: "OK", body: onLampMasterTool(request.body), contentType: "application/json"
        )
    }

    /// `POST /mod` — what the companion mod reports from inside a session.
    ///
    /// The token is required, unlike `/signal`: no copy of the mod predates it,
    /// so there is no installed base to keep working. A report that does not
    /// read is a 400 with the reason, and changes nothing.
    private func handleMod(_ request: HTTPRequest) -> Data {
        guard request.method == "POST" else {
            return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed")
        }
        guard let token else {
            return HTTPRequestParser.response(status: 503, reason: "Service Unavailable")
        }
        guard AccessToken.matches(request.header(AccessToken.headerName), expected: token) else {
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }
        do {
            onMod(try ModReport.decode(request.body))
            return HTTPRequestParser.response(status: 204, reason: "No Content")
        } catch {
            return HTTPRequestParser.response(status: 400, reason: "Bad Request", body: "\(error)")
        }
    }

    /// `POST /check` — a permission the companion mod puts to the panel (D80).
    /// The caller waits for the answer, up to the 55 seconds the panel has; the
    /// queue is concurrent, so nothing else is held behind it. Whatever goes
    /// wrong is `ask`: the dialog the session would have shown anyway.
    ///
    /// Not the token in a header but a proof made with it: the mod never sends
    /// the token where something else might be listening, and signs nothing it
    /// cannot check back (`PermissionGate`).
    private func handleCheck(_ request: HTTPRequest) -> Data {
        // GET lists what waits — for a test's fake home only (see `/check/answer`).
        if request.method == "GET" {
            guard AppConfig.isUsingHomeOverride else { return HTTPRequestParser.response(status: 404, reason: "Not Found") }
            guard let token else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
            guard AccessToken.matches(request.header(AccessToken.headerName), expected: token) else {
                return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
            }
            return HTTPRequestParser.response(status: 200, reason: "OK", body: onChecks(), contentType: "application/json")
        }
        guard request.method == "POST" else { return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed") }
        // Proven with the permission key, not the token: the token travels on
        // every hook and every report, the key on nothing (D80).
        guard let checkKey else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
        let verdict = onCheck(request.body, request.header("X-LampBoard-Nonce"), request.header("X-LampBoard-Proof"), checkKey)
        return HTTPRequestParser.response(status: 200, reason: "OK", body: verdict)
    }

    /// `POST /check/answer` — `{"id","verdict"}`: the panel's answer to an ask
    /// waiting. 404 when no ask with that id is waiting: answered once only.
    ///
    /// **Only against a fake home**, for the tests and the test Mac's probes. In
    /// a real install the panel answers in-process, from a click or a key, and
    /// this route does not exist: the token is in every hook, here and on every
    /// node, and readable by any process of the user's — one that held it could
    /// otherwise list another session's ask and answer it `allow`, no click (a
    /// security review's high finding, D80).
    private func handleCheckAnswer(_ request: HTTPRequest) -> Data {
        guard AppConfig.isUsingHomeOverride else { return HTTPRequestParser.response(status: 404, reason: "Not Found") }
        if let refusal = tokenRefusal(request) { return refusal }
        return onCheckAnswer(request.body)
            ? HTTPRequestParser.response(status: 204, reason: "No Content")
            : HTTPRequestParser.response(status: 404, reason: "Not Found", body: "no such ask waiting")
    }

    /// `GET /mod/band` — what the band above a session's prompt shows (D84),
    /// behind the token: what waits elsewhere, never the asking session's own.
    private func handleBand(_ request: HTTPRequest) -> Data {
        guard request.method == "GET" else { return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed") }
        guard let token else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
        guard AccessToken.matches(request.header(AccessToken.headerName), expected: token) else {
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }
        let asking = request.header("X-LampBoard-Session").flatMap { ModReport.isSessionId($0) ? $0 : nil }
        return HTTPRequestParser.response(status: 200, reason: "OK", body: onBand(asking), contentType: "application/json")
    }

    /// `POST /mod/band/open` — `{"session"}`: a digit pressed in a band, which
    /// opens that session in the panel. It answers nothing and runs nothing.
    private func handleBandOpen(_ request: HTTPRequest) -> Data {
        if let refusal = tokenRefusal(request) { return refusal }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let session = object["session"] as? String, ModReport.isSessionId(session) else {
            return HTTPRequestParser.response(status: 400, reason: "Bad Request")
        }
        return onBandOpen(session)
            ? HTTPRequestParser.response(status: 204, reason: "No Content")
            : HTTPRequestParser.response(status: 404, reason: "Not Found", body: "no such session")
    }

    /// POST and the token, or the response that says which is missing.
    private func tokenRefusal(_ request: HTTPRequest) -> Data? {
        guard request.method == "POST" else {
            return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed")
        }
        guard let token else {
            return HTTPRequestParser.response(status: 503, reason: "Service Unavailable")
        }
        guard AccessToken.matches(request.header(AccessToken.headerName), expected: token) else {
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }
        return nil
    }

    /// `POST /watch` — a command run under `lampboard watch` (D70). Behind the
    /// token, because it is the one route besides `/signal` that makes a row.
    private func handleWatch(_ request: HTTPRequest) -> Data {
        guard request.method == "POST" else {
            return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed")
        }
        guard let token else {
            return HTTPRequestParser.response(status: 503, reason: "Service Unavailable")
        }
        guard AccessToken.matches(request.header(AccessToken.headerName), expected: token) else {
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }
        // A folder that exists: the row's folder glyph opens it, and a path to an
        // application or a document there would be a click that launches it.
        var isDirectory: ObjCBool = false
        guard let report = try? WatchReport.decode(request.body),
              FileManager.default.fileExists(atPath: report.cwd, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            return HTTPRequestParser.response(status: 400, reason: "Bad Request", body: "not a watch report")
        }
        onWatch(report)
        return HTTPRequestParser.response(status: 204, reason: "No Content")
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
