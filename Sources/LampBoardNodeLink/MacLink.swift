import Citadel
import Foundation
import LampBoardCore
import NIOCore
import NIOSSH

/// The phone's side of the Mac as a source (§2.4, §2.6): pairing from the QR
/// code, and the Mac's terminals and named actions over the action key.
///
/// The Mac's server takes no command of the phone's own: what is sent is a
/// `MacRequest`, a name and checked arguments, and the Mac builds the rest.
@available(macOS 15.0, *)
extension NodeLink {

    /// Pairs with the Mac whose QR code is `invitation`, at `address`: the
    /// `pair` account with the one-time code, the host key pinned to the one
    /// the code carries, the device's two public keys sent, and the Mac's
    /// answer once the person there said yes or no.
    public static func pair(_ invitation: MacPairingInvitation, address: String, request: MacPairingRequest,
                            deadlines: NodeDeadlines = .standard, answerWithin: TimeInterval = 150) async throws -> MacPairingReply {
        let hostKey = try NodeHostKey(openSSH: invitation.hostKey)
        let judge = HostKeyJudge(trust: .pinned(hostKey))
        let endpoint = NodeEndpoint(host: address, port: invitation.port, user: MacBridge.pairUser)
        let client: SSHClient
        do {
            client = try await NodeDeadline.run(deadlines.connect, "connecting to \(endpoint)",
                                                late: { (late: SSHClient) in Task { try? await late.close() } }) {
                try await SSHClient.connect(
                    host: address, port: invitation.port,
                    authenticationMethod: .passwordBased(username: MacBridge.pairUser, password: invitation.code),
                    hostKeyValidator: .custom(judge), reconnect: .never,
                    connectTimeout: .milliseconds(Int64(deadlines.connect * 1000))
                )
            }
        } catch {
            if case .refused(let presented, let expected)? = judge.verdict {
                throw NodeLinkError.hostKeyMismatch(presented: presented.openSSH, expected: expected.openSSH)
            }
            throw NodeErrorWords.describe(error, "pairing with \(invitation.name)")
        }
        defer { Task { try? await client.close() } }
        let channel = try await ExecChannel.open(client, command: "pair", deadlines: deadlines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try await channel.write(Array(try encoder.encode(request)) + [0x0A])
        // The person on the Mac reads the fingerprints and answers: minutes, not seconds.
        let answer = try await NodeDeadline.run(answerWithin, "waiting for the Mac's answer") { () -> [UInt8] in
            var collected: [UInt8] = []
            for await chunk in channel.inbound {
                collected += chunk
                if collected.contains(0x0A) { break }
            }
            return collected
        }
        await channel.close()
        let line = answer.split(separator: 0x0A).first.map { Data($0) } ?? Data()
        guard let reply = try? JSONDecoder().decode(MacPairingReply.self, from: line) else {
            throw NodeLinkError.failed("the Mac did not answer the pairing")
        }
        return reply
    }
}

@available(macOS 15.0, *)
extension ActionConnection {

    /// A terminal on one of the Mac's sessions, through its PTY bridge.
    public func openMacTerminal(_ target: MacTerminalTarget, size: TerminalSize) async throws -> NodeTerminal {
        guard let line = MacRequest.attach(target).line else { throw NodeLinkError.failed("not a terminal the Mac opens") }
        return try await openTerminal(command: line, size: size)
    }

    /// One of the panel's actions, run on the Mac by name.
    public func runOnMac(_ action: NodeAction, limit: Int = 1 << 20) async throws -> NodeCommandResult {
        guard let line = MacRequest.action(action).line else { throw NodeLinkError.failed("not an action the Mac takes") }
        return try await run(line, limit: limit)
    }

    /// The rule of Q7 for this connection's terminals on the Mac (E14).
    public func backgroundOnMac() async throws -> NodeCommandResult {
        try await run("background")
    }
}
