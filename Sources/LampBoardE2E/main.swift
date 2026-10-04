import LampBoardCore
import Foundation
import TestKit

// End-to-end test run: `swift run LampBoardE2E [filter]`.
//
// It launches the real binary against a fake home and talks to it over HTTP. It
// does not touch ~/.claude, does not touch the user's preferences, and asks for
// no system permissions: everything it writes lives in a temporary folder that
// gets deleted at the end, pass or fail.

// Before anything is launched: if the assertions do not bite, this run would
// start a real binary, talk to it for a minute and report a success that means
// nothing. Cheaper and clearer to find out here.
Instrument.prove()

let arguments = Array(CommandLine.arguments.dropFirst())

/// Port dedicated to the test run: never the default one, or a test run would
/// collide with the panel the user has open.
let testPort: UInt16 = {
    guard let index = arguments.firstIndex(of: "--port"),
          index + 1 < arguments.count,
          let value = UInt16(arguments[index + 1])
    else {
        return 9899
    }
    return value
}()

/// The optional suite/case filter: the first argument that is neither an option
/// nor **the value of an option**.
///
/// That second condition is not pedantry. Without it, `--port 9899` made `9899`
/// the filter, no suite matched, and the runner printed "0 tests passed" and
/// exited 0 — which is how `./Scripts/test.sh` ran zero end-to-end tests while
/// reporting success. A green result from having run nothing is the worst kind
/// of fake success, because nobody goes looking for it.
let filter: String? = {
    var skipNext = false
    for argument in arguments {
        if skipNext { skipNext = false; continue }
        if argument == "--port" { skipNext = true; continue }
        if argument.hasPrefix("--") { continue }
        return argument
    }
    return nil
}()

let binaryURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .appendingPathComponent("LampBoardApp")

let app = AppUnderTest(binaryURL: binaryURL, port: testPort)

// The fixtures have to name a transcript the app will agree to open, and that is
// now only somewhere under this run's fake `~/.claude`.
HookPayloads.transcriptRoot = app.home.appendingPathComponent(".claude", isDirectory: true)

do {
    try app.start()
} catch {
    FileHandle.standardError.write(Data("Test run failed to start: \(error)\n".utf8))
    app.stop()
    exit(2)
}

// The fake filesystem has to be populated before the cases: the workspace
// resolver discards every session whose cwd doesn't sit inside a lock, and
// without these two files every case would fail for the wrong reason.
app.writeIDELock(port: 40001, folders: [LifecycleSuite.workspace])
app.writeIDELock(port: 40002, folders: [CoverageSuite.secondWorkspace])
app.writeIDELock(port: 40003, folders: [CoverageSuite.terminalWorkspace])

let suites: [TestSuite] = [
    TransportSuite.suite(app),
    LifecycleSuite.suite(app),
    CoverageSuite.suite(app),
    ScaleSuite.suite(app),
    InstallationSuite.suite(app),
    CodexScannerSuite.suite(app: app),
    ClaudeDesktopE2ESuite.suite(app: app),
    UpdateSwapSuite.suite(),
    // Instances of its own, each with LampMaster's preferences written before
    // launch, on a port of its own.
    LampMasterE2ESuite.suite(binaryURL: binaryURL, port: testPort &+ 2),
    // Deliberately last: it starts other instances against the same home and
    // changes their token, so everything before it must already be finished.
    TokenLifecycleSuite.suite(binaryURL: binaryURL, home: app.home, port: testPort &+ 1),
]

let code = TestRunner.runAndReport(suites, filter: filter)
app.stop()
exit(code)
