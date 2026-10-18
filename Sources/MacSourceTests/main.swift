import Foundation
import ProtocolConformance
import TestKit

// The Mac as a source for the phone (W5): `MacSourceTests [filter]`. The domain
// suites, then the server in this process on loopback, reached by a phone made
// of NodeLink — the conformance battery over a real ssh, the doors of the
// server, the PTY bridge on a tmux server of its own. Runs on the Mac gate and
// on Linux.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
Instrument.prove()

// The fake phone on another machine (T1-linux), and what it needs.
let commandLine = Array(CommandLine.arguments.dropFirst())
switch commandLine.first {
case "keys" where commandLine.count == 2:
    exit(RemoteCommands.keys(commandLine[1]))
case "devices" where commandLine.count == 3:
    exit(RemoteCommands.devices(commandLine[1], commandLine[2]))
case "serve" where commandLine.count == 2:
    // A harness server that stays up, its keys written into the folder: for
    // trying `remote` against a server in another process.
    if #available(macOS 15.0, *) {
        guard let harness = try? MacHarness(terminalsOn: true) else { exit(1) }
        let dir = commandLine[1]
        _ = FileManager.default.createFile(atPath: dir + "/read.key", contents: Data(harness.read.rawRepresentation.base64EncodedString().utf8))
        _ = FileManager.default.createFile(atPath: dir + "/action.key", contents: Data(harness.action.rawRepresentation.base64EncodedString().utf8))
        _ = FileManager.default.createFile(atPath: dir + "/hostkey", contents: Data(harness.hostKey.openSSH.utf8))
        print("serving on port \(harness.port)")
        while true { sleep(3600) }
    }
    exit(2)
case "remote":
    if #available(macOS 15.0, *) { exit(RemoteCommands.remote(commandLine)) }
    exit(2)
default:
    break
}

let filter = CommandLine.arguments.dropFirst().first
let suites: [TestSuite] = [
    MacRequestSuite.suite,
    MacPolicySuite.suite,
    MacPairingSuite.suite,
    MacDevicesSuite.suite,
    MacSourceSuite.suite,
    MacPanelSuite.suite,
    V1Conformance.suite(against: MacMemoryTarget()),
]

/// The server's suites: NodeLink, the phone of these checks, needs macOS 15.
@available(macOS 15.0, *)
func runWithServer(_ suites: [TestSuite]) -> Int32 {
    let harness: MacHarness
    do {
        harness = try MacHarness()
    } catch {
        FileHandle.standardError.write(Data("MacSourceTests: the server did not start: \(error)\n".utf8))
        return 1
    }
    let all = suites + [
        V1Conformance.suite(against: MacSSHTarget(harness)),
        MacServerSuite.suite(harness),
        MacBridgeSuite.suite(harness),
    ]
    let code = TestRunner.runAndReport(all, filter: filter)
    harness.stop()
    return code
}

if #available(macOS 15.0, *) {
    exit(runWithServer(suites))
} else {
    FileHandle.standardError.write(Data("MacSourceTests: needs macOS 15\n".utf8))
    exit(1)
}
