import Foundation
import LampBoardCore
import ProtocolConformance
import TestKit

// lampd's suite: `LampDTests [filter]`. Scripts/test-lampd.sh runs it on Linux,
// in the pinned toolchain's container; it builds and runs on the Mac too.

setvbuf(stdout, nil, _IOLBF, 0)
Instrument.prove()

let suites: [TestSuite] = [
    DevicesSuite.suite,
    NodeSourceSuite.suite,
    PushSuite.suite,
    SmallSuites.preferences,
    SmallSuites.projects,
    SmallSuites.config,
    SmallSuites.replay,
    V1Conformance.suite(against: NodeMemoryTarget(mode: .live)),
    V1Conformance.suite(against: NodeMemoryTarget(mode: .files)),
]

let filter = CommandLine.arguments.dropFirst().first
exit(TestRunner.runAndReport(suites, filter: filter))
