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
