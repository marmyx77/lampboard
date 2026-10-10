import Foundation
import LampBoardCore

/// The two routes of the Hub's command channel (D152), behind the token.
///
/// The token proves nothing about a command — every hook carries it — so the
/// commands themselves are signed with the panel's key and the mod checks each
/// one; the token only keeps a web page or a stranger from draining a queue.
extension SignalServer {

    /// `GET /mod/hello` with `X-LampBoard-Nonce`: the panel's key and its
    /// signature of the nonce.
    func handleModHello(_ request: HTTPRequest) -> Data {
        if let refusal = getTokenRefusal(request) { return refusal }
        guard let desk = hubDesk else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
        guard let nonce = request.header("X-LampBoard-Nonce"), let body = desk.hello(nonce: nonce) else {
            return HTTPRequestParser.response(status: 400, reason: "Bad Request", body: "a nonce of 16 to 128 letters, digits or dashes")
        }
        return HTTPRequestParser.response(status: 200, reason: "OK", body: String(decoding: body, as: UTF8.self), contentType: "application/json")
    }

    /// `GET /mod/inbox` with `X-LampBoard-Session`: the signed commands waiting
    /// for that session, taken out of the queue.
    func handleModInbox(_ request: HTTPRequest) -> Data {
        if let refusal = getTokenRefusal(request) { return refusal }
        guard let desk = hubDesk else { return HTTPRequestParser.response(status: 200, reason: "OK", body: "[]", contentType: "application/json") }
        guard let session = request.header("X-LampBoard-Session"), ModReport.isSessionId(session) else {
            return HTTPRequestParser.response(status: 400, reason: "Bad Request", body: "a session id")
        }
        return HTTPRequestParser.response(status: 200, reason: "OK", body: String(decoding: desk.collect(session: session), as: UTF8.self), contentType: "application/json")
    }

    /// `POST /hub/send` — `{"session","op","args"}`: queue a command as the Hub
    /// would. **Only against a fake home**, for the tests and the test Mac's
    /// probes; in a real install only the Hub's own controls queue a command.
    func handleHubSend(_ request: HTTPRequest) -> Data {
        guard AppConfig.isUsingHomeOverride else { return HTTPRequestParser.response(status: 404, reason: "Not Found") }
        guard request.method == "POST" else { return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed") }
        guard let token, AccessToken.matches(request.header(AccessToken.headerName), expected: token) else {
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }
        guard let desk = hubDesk else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
        struct Wire: Decodable { let session: String; let op: String; let args: [String: String]? }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: request.body),
              desk.send(session: wire.session, op: wire.op, args: wire.args ?? [:])
        else { return HTTPRequestParser.response(status: 400, reason: "Bad Request") }
        return HTTPRequestParser.response(status: 204, reason: "No Content")
    }

    /// `GET /hub` — what the Hub shows; `POST /hub/open` — `{"session"}`:
    /// open it there. **Only against a fake home**, for the tests.
    func handleHubTest(_ request: HTTPRequest) -> Data {
        guard AppConfig.isUsingHomeOverride else { return HTTPRequestParser.response(status: 404, reason: "Not Found") }
        guard let token, AccessToken.matches(request.header(AccessToken.headerName), expected: token) else {
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }
        if request.path == AppConfig.hubPath, request.method == "GET" {
            guard let body = onHubReport?() else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
            return HTTPRequestParser.response(status: 200, reason: "OK", body: String(decoding: body, as: UTF8.self), contentType: "application/json")
        }
        guard request.path == AppConfig.hubOpenPath, request.method == "POST" else {
            return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed")
        }
        struct Wire: Decodable { let session: String? }
        let session = (try? JSONDecoder().decode(Wire.self, from: request.body))?.session
        return onHubOpen?(session) == true
            ? HTTPRequestParser.response(status: 204, reason: "No Content")
            : HTTPRequestParser.response(status: 503, reason: "Service Unavailable")
    }

    private func getTokenRefusal(_ request: HTTPRequest) -> Data? {
        guard request.method == "GET" else { return HTTPRequestParser.response(status: 405, reason: "Method Not Allowed") }
        guard let token else { return HTTPRequestParser.response(status: 503, reason: "Service Unavailable") }
        guard AccessToken.matches(request.header(AccessToken.headerName), expected: token) else {
            return HTTPRequestParser.response(status: 401, reason: "Unauthorized")
        }
        return nil
    }
}
