import Foundation
import LampBoardCore

/// The push relay over the machine's `curl` (§2.8, ADR-65 point 10).
///
/// A static Linux binary carries no TLS stack configured for the machine it
/// lands on: certificates, proxies and IPv6 are the system's business, and
/// `curl` is how the system does them. The request body travels on standard
/// input and nothing secret is on the command line, where `ps` would show it.
public struct CurlRelayTransport: RelayTransport {
    public let curl: String
    public let timeout: TimeInterval

    public init(curl: String = CurlRelayTransport.find() ?? "/usr/bin/curl", timeout: TimeInterval = 15) {
        self.curl = curl
        self.timeout = timeout
    }

    /// `curl` where a service's `PATH` would find it, or `nil`.
    public static func find() -> String? {
        ["/usr/bin/curl", "/bin/curl", "/usr/local/bin/curl"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct Failed: Error, CustomStringConvertible {
        public let description: String
    }

    public func exchange(method: String, url: URL, body: Data?) async throws -> RelayHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { continuation.resume(returning: try run(method: method, url: url, body: body)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func run(method: String, url: URL, body: Data?) throws -> RelayHTTPResponse {
        guard url.scheme == "https" || url.scheme == "http" else { throw Failed(description: "not an http URL") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: curl)
        var arguments = ["--silent", "--show-error", "--include", "--max-time", String(Int(timeout)),
                         "--proto", "=https,http", "--max-filesize", "65536", "-X", method]
        if body != nil { arguments += ["-H", "Content-Type: application/json", "--data-binary", "@-"] }
        arguments.append(url.absoluteString)
        process.arguments = arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        if let body { input.fileHandleForWriting.write(body) }
        try? input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failed(description: "curl exited \(process.terminationStatus)") }
        return try Self.parse(bytes)
    }

    /// `--include` output: one or more header blocks (a `100 Continue` first,
    /// sometimes), then the body.
    static func parse(_ bytes: Data) throws -> RelayHTTPResponse {
        var rest = bytes
        let separator = Data("\r\n\r\n".utf8)
        while true {
            guard let end = rest.range(of: separator) else { throw Failed(description: "no headers") }
            let head = String(decoding: rest[rest.startIndex..<end.lowerBound], as: UTF8.self)
            let body = rest[end.upperBound...]
            var lines = head.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst()
            let parts = statusLine.split(separator: " ")
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
                throw Failed(description: "no status line")
            }
            if status == 100 { rest = Data(body); continue }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return RelayHTTPResponse(status: status, headers: headers, body: Data(body))
        }
    }
}
