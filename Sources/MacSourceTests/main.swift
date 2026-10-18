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

let filter = CommandLine.arguments.dropFirst().first
var suites: [TestSuite] = [
    MacRequestSuite.suite,
    MacPolicySuite.suite,
    MacPairingSuite.suite,
    MacDevicesSuite.suite,
    MacSourceSuite.suite,
    V1Conformance.suite(against: MacMemoryTarget()),
]

let harness: MacHarness
do {
    harness = try MacHarness()
} catch {
    FileHandle.standardError.write(Data("MacSourceTests: the server did not start: \(error)\n".utf8))
    exit(1)
}
suites += [
    V1Conformance.suite(against: MacSSHTarget(harness)),
    MacServerSuite.suite(harness),
    MacBridgeSuite.suite(harness),
]
let code = TestRunner.runAndReport(suites, filter: filter)
harness.stop()
exit(code)
