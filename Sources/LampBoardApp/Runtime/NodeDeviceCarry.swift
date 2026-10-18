import Foundation
import LampBoardCore
import LampBoardMacSource

/// A phone's keys carried from the Mac to a node, and taken back (W5, §2.4):
/// `lampd devices add` and `lampd devices revoke`, run over the ssh this Mac
/// already opens to the node. Trust goes from the Mac to the nodes (R2): the
/// node never sends the Mac a key, and the phone gets the node's host key from
/// the Mac's own `known_hosts`.
///
/// Blocking: called off the main actor.
enum NodeDeviceCarry {

    /// Where `Scripts/lampd-install.sh` puts `lampd`, from the node's home.
    static let lampdPath = ".local/bin/lampd"

    /// Puts the device's two keys on `host` and says what the phone needs to
    /// reach it. `nil` when the node refused or did not answer: said in the log,
    /// and the phone simply has one node fewer.
    static func add(_ device: MacDevices.Device, on host: String) -> MacPairedNode? {
        // The same device pairing again: its keys are already there (and
        // `lampd` refuses a key twice); the phone only needs the way back.
        if let nodeId = device.nodes?[host] {
            let facts = facts(of: host)
            return MacPairedNode(name: host, address: facts?.address ?? host, port: facts?.port ?? 22,
                                 user: facts?.user ?? "", hostKeys: facts?.keys ?? [], device: nodeId)
        }
        let arguments = ["devices", "add", "--name", device.name, "--read", device.readKey, "--action", device.actionKey]
        guard case .success(let output) = run(arguments, on: host) else {
            Diagnostics.log("carry \(device.id) to \(host): lampd refused or did not answer")
            return nil
        }
        let nodeId = output.split(separator: "\n").first { $0.hasPrefix("added ") }
            .flatMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
        let facts = facts(of: host)
        Diagnostics.log("carry \(device.id) to \(host): \(nodeId ?? "no id said"), \(facts?.keys.count ?? 0) host keys")
        return MacPairedNode(name: host, address: facts?.address ?? host, port: facts?.port ?? 22,
                             user: facts?.user ?? "", hostKeys: facts?.keys ?? [], device: nodeId)
    }

    /// Forget on the Mac takes the device off each node it was carried to.
    static func revoke(_ nodeId: String, on host: String) {
        switch run(["devices", "revoke", nodeId], on: host) {
        case .success: Diagnostics.log("revoked \(nodeId) on \(host)")
        case .failure(let error): Diagnostics.log("revoke \(nodeId) on \(host): \(error.short)")
        }
    }

    /// `lampd <arguments>` on `host`, through Python's `subprocess` with an
    /// argument list: no shell ever reads a key or a name.
    private static func run(_ arguments: [String], on host: String) -> Result<String, RemoteCommandError> {
        guard let payload = try? JSONSerialization.data(withJSONObject: arguments) else { return .failure(.badAnswer("arguments")) }
        let script = """
        import base64, json, os, subprocess, sys
        args = json.loads(base64.b64decode("\(payload.base64EncodedString())"))
        lampd = os.path.join(os.path.expanduser("~"), "\(lampdPath)")
        done = subprocess.run([lampd] + args, capture_output=True, text=True, timeout=20)
        sys.stdout.write(done.stdout)
        sys.stderr.write(done.stderr)
        sys.exit(done.returncode)
        """
        return RemoteCommand.runPython(on: host, script: script, timeout: 20).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Where this Mac's ssh reaches `host`, and the host keys it trusts there.
    static func facts(of host: String) -> (address: String, port: Int, user: String, keys: [String])? {
        guard let resolved = (try? Command.run("/usr/bin/ssh", ["-G", host], deadline: 5))
                .flatMap({ MacSSHFacts.resolved($0.output) }) else { return nil }
        let name = MacSSHFacts.knownHostsName(address: resolved.address, port: resolved.port)
        let known = (try? Command.run("/usr/bin/ssh-keygen", ["-F", name], deadline: 5))?.output ?? ""
        return (resolved.address, resolved.port, resolved.user, MacSSHFacts.hostKeys(known))
    }
}
