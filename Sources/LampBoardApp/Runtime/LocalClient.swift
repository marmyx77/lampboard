import LampBoardCore
import Foundation

/// Talks to the lampboard instance that is already running.
///
/// The terminal commands run in a separate process that knows nothing about the
/// column: the state lives in the app with the panel. Asking the live process is
/// the only way to get a true answer instead of a plausible reconstruction from
/// the filesystem.
enum LocalClient {

    enum ClientError: LocalizedError {
        case noToken
        case notRunning
        case unauthorized
        case http(Int, String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .noToken:
                return """
                No token at \(AppConfig.tokenURL.path).
                It is created the first time the panel starts: is it running?
                """
            case .notRunning:
                return "LampBoard is not running."
            case .unauthorized:
                return """
                Token rejected. If you restarted the app after deleting the token \
                file, try again: the old one is no longer valid.
                """
            case .http(let status, let body):
                return "Response \(status)\(body.isEmpty ? "" : ": \(body)")"
            case .transport(let reason):
                return "Communication failed: \(reason)"
            }
        }
    }

    /// Reads the column state from the running instance.
    static func sessions(port: UInt16) -> Result<SessionsResponse, ClientError> {
        switch request(method: "GET", path: AppConfig.sessionsPath, port: port) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            guard let response = try? SessionsCodec.decode(data) else {
                return .failure(.transport("response not decodable"))
            }
            return .success(response)
        }
    }

    /// The decision board (D105): listed with no change, otherwise changed and
    /// listed as it now is.
    static func decisions(change: Data?, port: UInt16) -> Result<DecisionBoard, ClientError> {
        switch request(method: change == nil ? "GET" : "POST", path: AppConfig.decisionsPath, port: port, body: change) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            guard let board = try? DecisionBoardCodec.decode(data) else { return .failure(.transport("response not decodable")) }
            return .success(board)
        }
    }

    /// Asks the running instance to raise the next waiting session.
    static func next(port: UInt16) -> Result<String, ClientError> {
        switch request(method: "POST", path: AppConfig.nextPath, port: port) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            return .success(String(data: data, encoding: .utf8)?.trimmed ?? "")
        }
    }

    /// Asks the running instance to raise the project bound to a slot.
    /// - Returns: an empty string when the slot holds nothing — which is an
    ///   answer, not a failure.
    static func open(slot: Int, port: UInt16) -> Result<String, ClientError> {
        slotRequest(path: AppConfig.openPath, slot: slot, port: port)
    }

    /// Asks the running instance to open a new conversation in a slot's project.
    static func newConversation(slot: Int, port: UInt16) -> Result<String, ClientError> {
        slotRequest(path: AppConfig.newConversationPath, slot: slot, port: port)
    }

    /// Asks the running instance to open a slot's conversation in a chat window.
    static func chat(slot: Int, port: UInt16) -> Result<String, ClientError> {
        slotRequest(path: AppConfig.chatPath, slot: slot, port: port)
    }

    /// A session's tool call, forwarded for the `lampmaster` MCP server. The
    /// wait is a question's: up to a minute and a half for a model to answer.
    static func lampMasterTool(_ body: Data, port: UInt16) -> Result<Data, ClientError> {
        request(method: "POST", path: AppConfig.lampMasterToolPath, port: port, body: body,
                timeout: LampMasterAsk.timeout + 20)
    }

    /// `lampboard watch` telling the panel a command started or ended.
    static func watch(_ report: WatchReport, port: UInt16) -> Result<Data, ClientError> {
        request(method: "POST", path: AppConfig.watchPath, port: port, body: report.encoded())
    }

    private static func slotRequest(
        path: String, slot: Int, port: UInt16
    ) -> Result<String, ClientError> {
        switch request(
            method: "POST", path: path, port: port, body: Data(String(slot).utf8)
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            return .success(String(data: data, encoding: .utf8)?.trimmed ?? "")
        }
    }

    // MARK: - Internal

    private static func request(
        method: String,
        path: String,
        port: UInt16,
        body: Data? = nil,
        timeout: TimeInterval = 3
    ) -> Result<Data, ClientError> {
        guard let token = TokenStore().read() else {
            return .failure(.noToken)
        }

        var request = URLRequest(
            url: URL(string: "http://\(AppConfig.listenHost):\(port)\(path)")!
        )
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: AccessToken.headerName)
        request.httpBody = body
        request.timeoutInterval = timeout

        // A synchronous request: we are in a terminal command that has to print and
        // exit, and an explicit wait is more honest than a semaphore wrapped around
        // an asynchronous API.
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Data, ClientError> = .failure(.transport("no response"))

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error as? URLError {
                outcome = .failure(
                    error.code == .cannotConnectToHost || error.code == .networkConnectionLost
                        ? .notRunning
                        : .transport(error.localizedDescription)
                )
                return
            }
            if let error {
                outcome = .failure(.transport(error.localizedDescription))
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data ?? Data()

            switch status {
            case 200...299:
                outcome = .success(body)
            case 401:
                outcome = .failure(.unauthorized)
            default:
                outcome = .failure(
                    .http(status, String(data: body, encoding: .utf8)?.trimmed ?? "")
                )
            }
        }.resume()

        _ = semaphore.wait(timeout: .now() + timeout + 2)
        return outcome
    }
}
