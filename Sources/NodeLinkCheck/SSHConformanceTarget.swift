import Foundation
import LampBoardCore
import LampBoardNodeLink
import ProtocolConformance
import TestKit

/// The node under test, as the command line described it.
struct CheckedNode {
    let endpoint: NodeEndpoint
    let hostKey: NodeHostKey
    let wrongHostKey: NodeHostKey
    let readKey: ReadKey
    let actionKey: ActionKey
    /// Where `V1ReferenceNode` is on the node, its socket and its log.
    let reference: String
    let socket: String
    let log: String
    /// A port on the node that accepts TCP and never says a word.
    let silentPort: Int
}

/// The reference node reached through NodeLink: every connection of the battery
/// is a new ssh connection with the read key, and the source is made to change
/// with the action key, by running its `provoke` on the node.
@available(macOS 15.0, *)
final class SSHConformanceTarget: V1ConformanceTarget {
    let name = "the reference node over ssh"
    let pingInterval: TimeInterval = 0.5
    private let node: CheckedNode
    private var actor: ActionConnection?

    init(_ node: CheckedNode) { self.node = node }

    func connect(role: V1Role) throws -> V1ByteStream {
        let node = self.node
        return try Blocking.run(30) { () async throws -> SSHByteStream in
            switch role {
            case .read:
                let connection = try await NodeLink.read(node.endpoint, trust: .pinned(node.hostKey), key: node.readKey)
                return SSHByteStream(try await connection.openV1()) { await connection.close() }
            case .action:
                let connection = try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
                return SSHByteStream(try await connection.openV1()) { await connection.close() }
            }
        }
    }

    func provoke(_ count: Int) throws {
        let node = self.node
        let existing = actor
        let connection = try Blocking.run(30) { () async throws -> ActionConnection in
            if let existing { return existing }
            return try await NodeLink.act(node.endpoint, trust: .pinned(node.hostKey), key: node.actionKey)
        }
        actor = connection
        let result = try Blocking.run(30) {
            try await connection.run("\(node.reference) provoke --socket \(node.socket) \(count)")
        }
        guard result.exitCode == 0 else { throw NodeLinkError.failed("provoke exited \(result.exitCode)") }
    }

    func finish() {
        guard let actor else { return }
        _ = try? Blocking.run(10) { await actor.close() }
    }
}

/// A NodeLink channel as the battery reads it: blocking calls with a timeout,
/// over a channel that delivers asynchronously.
@available(macOS 15.0, *)
final class SSHByteStream: V1ByteStream, @unchecked Sendable {
    private let channel: NodeByteChannel
    private let closeConnection: () async -> Void
    private let condition = NSCondition()
    private var buffer: [UInt8] = []
    private var ended = false

    init(_ channel: NodeByteChannel, closeConnection: @escaping () async -> Void) {
        self.channel = channel
        self.closeConnection = closeConnection
        let inbound = channel.inbound
        Task.detached { [weak self] in
            for await chunk in inbound { self?.append(chunk) }
            self?.markEnded()
        }
    }

    func write(_ bytes: [UInt8]) throws {
        let channel = self.channel
        try Blocking.run(15) { try await channel.write(bytes) }
    }

    func read(timeout: TimeInterval) throws -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while buffer.isEmpty && !ended {
            if !condition.wait(until: deadline) { break }
        }
        if !buffer.isEmpty {
            defer { buffer = [] }
            return buffer
        }
        return ended ? nil : []
    }

    func close() {
        let channel = self.channel, closeConnection = self.closeConnection
        _ = try? Blocking.run(10) {
            await channel.close()
            await closeConnection()
        }
    }

    private func append(_ chunk: [UInt8]) {
        condition.lock()
        buffer += chunk
        condition.broadcast()
        condition.unlock()
    }

    private func markEnded() {
        condition.lock()
        ended = true
        condition.broadcast()
        condition.unlock()
    }
}
