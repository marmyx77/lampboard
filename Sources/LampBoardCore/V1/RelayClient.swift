import Foundation

/// One HTTP exchange with the relay, as the client needs it: the status, the
/// headers it reads (`retry-after`), the body.
public struct RelayHTTPResponse: Equatable, Sendable {
    public let status: Int
    /// Lower-cased names.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

/// How the bytes reach the relay. The app and the Mac use `URLSession`; `lampd`
/// a transport of its own (a static Linux binary carries no TLS stack it can
/// trust to be configured). Tests use a fake.
public protocol RelayTransport: Sendable {
    /// `body` is JSON for a POST, `nil` for a GET. Throws only when nothing
    /// came back at all.
    func exchange(method: String, url: URL, body: Data?) async throws -> RelayHTTPResponse
}

/// What one request to the relay came to, in the words a source puts in its
/// `hello` (`V1RelayHealth`).
public enum RelayOutcome: Equatable, Sendable {
    case ok
    /// The token is gone (APNs 410, `Unregistered`): the device uninstalled the
    /// app or turned notifications off for good. The source drops the token.
    case gone(String)
    /// Over a quota: try again after that many seconds.
    case quota(retryAfter: Int)
    /// Refused for what was sent: a capability that is not the token's, a
    /// malformed request, an envelope the relay could read.
    case refused(String)
    /// The relay or APNs could not be reached.
    case unreachable(String)

    /// The word `V1RelayHealth.outcome` carries.
    public var word: String {
        switch self {
        case .ok: return "ok"
        case .gone, .refused: return "refused"
        case .quota: return "quota"
        case .unreachable: return "unreachable"
        }
    }

    public func health(at now: Date) -> V1RelayHealth {
        switch self {
        case .ok: return V1RelayHealth(outcome: word, at: now)
        case .gone(let reason), .refused(let reason), .unreachable(let reason):
            return V1RelayHealth(outcome: word, at: now, reason: reason)
        case .quota(let seconds): return V1RelayHealth(outcome: word, at: now, retryAfter: seconds)
        }
    }
}

/// The relay's routes, from the side of a source and of the phone (§2.8):
/// challenge → capability → the Live Activity's capability → push.
///
/// It sends exactly the JSON the relay's tests hold it to (`relay/test/vectors`,
/// written by this Core), and reads every answer into a `RelayOutcome`, so a
/// source never has to know an HTTP status.
public struct RelayClient: Sendable {

    /// The relay everyone uses (Q16).
    public static let production = URL(string: "https://push.lampboard.site")!

    public let base: URL
    public let transport: RelayTransport

    public init(base: URL = RelayClient.production, transport: RelayTransport) {
        self.base = base
        self.transport = transport
    }

    // MARK: - The phone

    /// Asks the relay to send `token` a silent push carrying a nonce
    /// (`lb.challenge`), which only the device holding the token receives.
    public func challenge(token: String, environment: APNsEnvironment) async -> RelayOutcome {
        let body = ["token": token, "environment": environment.rawValue]
        return await outcome(of: post("/v1/challenge", body))
    }

    /// The nonce the silent push carried, given back: the capability, or why not.
    public func capability(
        token: String, environment: APNsEnvironment, challenge: RelayChallenge
    ) async -> Result<RelayCapability, RelayFailure> {
        let body: [String: Any] = ["token": token, "environment": environment.rawValue,
                                   "nonce": challenge.nonce, "issuedAt": challenge.issuedAt]
        return await capabilityAnswer(post("/v1/capability", body))
    }

    /// The Live Activity's token, vouched for by the device's capability.
    public func liveActivityCapability(
        device: RelayCapability, liveActivityToken: String
    ) async -> Result<RelayCapability, RelayFailure> {
        let body = ["cap": device.cap, "token": device.token, "environment": device.environment.rawValue,
                    "liveActivityToken": liveActivityToken]
        return await capabilityAnswer(post("/v1/capability/liveactivity", body))
    }

    // MARK: - A source

    public func push(_ request: RelayPushRequest) async -> RelayOutcome {
        guard let body = try? V1Codec.encoder().encode(request) else { return .refused("the request could not be written") }
        return await outcome(of: exchange("POST", "/v1/push", body))
    }

    /// `GET /health`: `ok`, or why not (`hello` carries it, §2.11).
    public func health() async -> RelayOutcome {
        let answer = await exchange("GET", "/health", nil)
        guard case .success(let response) = answer else { return outcome(of: answer) }
        guard response.status == 200,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              object["status"] as? String == "ok"
        else { return .unreachable("the relay says it is not well (\(response.status))") }
        return .ok
    }

    // MARK: - Reading answers

    /// An answer as an outcome: the relay's own `outcome` word wins, the status
    /// decides when there is none.
    func outcome(of answer: Result<RelayHTTPResponse, RelayFailure>) -> RelayOutcome {
        switch answer {
        case .failure(let failure): return .unreachable(failure.reason)
        case .success(let response): return Self.outcome(of: response)
        }
    }

    public static func outcome(of response: RelayHTTPResponse) -> RelayOutcome {
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let reason = Self.clean(object?["reason"] as? String) ?? "status \(response.status)"
        switch response.status {
        case 200..<300: return .ok
        case 410: return .gone(reason)
        case 429:
            let seconds = response.headers["retry-after"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return .quota(retryAfter: max(1, seconds ?? 60))
        case 500...: return .unreachable(reason)
        default: return .refused(reason)
        }
    }

    private func capabilityAnswer(_ answer: Result<RelayHTTPResponse, RelayFailure>) -> Result<RelayCapability, RelayFailure> {
        switch answer {
        case .failure(let failure): return .failure(failure)
        case .success(let response):
            guard (200..<300).contains(response.status) else {
                return .failure(RelayFailure(outcome: Self.outcome(of: response)))
            }
            guard let capability = try? V1Codec.decoder().decode(RelayCapability.self, from: response.body),
                  !capability.cap.isEmpty
            else { return .failure(RelayFailure(outcome: .refused("the relay's answer is not a capability"))) }
            return .success(capability)
        }
    }

    /// A reason as the relay wrote it, made safe to show and to keep: one line,
    /// bounded, printable.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let kept = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }.prefix(120)
        let line = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    // MARK: - Sending

    private func post(_ path: String, _ object: [String: Any]) async -> Result<RelayHTTPResponse, RelayFailure> {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return .failure(RelayFailure(outcome: .refused("the request could not be written")))
        }
        return await exchange("POST", path, body)
    }

    private func exchange(_ method: String, _ path: String, _ body: Data?) async -> Result<RelayHTTPResponse, RelayFailure> {
        let url = base.appendingPathComponent(String(path.drop { $0 == "/" }))
        do {
            return .success(try await transport.exchange(method: method, url: url, body: body))
        } catch {
            return .failure(RelayFailure(outcome: .unreachable("the relay could not be reached")))
        }
    }
}

/// What the silent push of a challenge carries (`lb.challenge`).
public struct RelayChallenge: Codable, Equatable, Sendable {
    public let nonce: String
    /// Seconds since 1970, as the relay wrote it: given back untouched.
    public let issuedAt: Int

    public init(nonce: String, issuedAt: Int) {
        self.nonce = nonce
        self.issuedAt = issuedAt
    }

    /// The challenge in a push's `userInfo`, or `nil` when it carries none.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let lb = userInfo["lb"] as? [String: Any], let challenge = lb["challenge"] as? [String: Any],
              let nonce = challenge["nonce"] as? String, !nonce.isEmpty, nonce.count <= 200
        else { return nil }
        let issued = (challenge["issuedAt"] as? NSNumber)?.intValue ?? (challenge["issuedAt"] as? String).flatMap { Int($0) }
        guard let issued else { return nil }
        self.init(nonce: nonce, issuedAt: issued)
    }
}

public struct RelayFailure: Error, Equatable, Sendable {
    public let outcome: RelayOutcome

    public init(outcome: RelayOutcome) {
        self.outcome = outcome
    }

    public var reason: String {
        switch outcome {
        case .ok: return "ok"
        case .gone(let reason), .refused(let reason), .unreachable(let reason): return reason
        case .quota(let seconds): return "over the relay's quota for \(seconds) s"
        }
    }
}

#if canImport(Darwin)
/// The relay over `URLSession`: the app's and the Mac's way.
public struct URLSessionRelayTransport: RelayTransport {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func exchange(method: String, url: URL, body: Data?) async throws -> RelayHTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return RelayHTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
#endif
