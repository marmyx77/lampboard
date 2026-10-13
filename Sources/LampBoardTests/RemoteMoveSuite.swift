import Foundation
import LampBoardCore
import TestKit

/// «Move to LampBoard…» on another machine (D166): the process there is ended
/// only while it is still the one its file names.
enum RemoteMoveSuite {

    private static func python(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static let suite = TestSuite("Moving a conversation from another machine", [

        TestCase("Only a start time that is one: nothing else is ever written into the script") { t in
            t.expectNil(RemoteMove.script(pid: 4242, procStart: ""), "no start, no move: the pid alone may name something else")
            t.expectNil(RemoteMove.script(pid: 1, procStart: "123"), "never init")
            t.expectNil(RemoteMove.script(pid: 4242, procStart: "1'); import os; os.system('x"))
            t.expect(RemoteMove.script(pid: 4242, procStart: "Mon Oct 13 12:11:51 2026") != nil, "a Mac's start time")
            t.expect(RemoteMove.script(pid: 4242, procStart: "14467577") != nil, "Linux clock ticks")
        },

        TestCase("A process that is not the one named is left alone; the one named is ended") { t in
            let sleeper = Process()
            sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
            sleeper.arguments = ["30"]
            guard (try? sleeper.run()) != nil else { return t.fail("no process to try") }
            defer { if sleeper.isRunning { sleeper.terminate() } }
            let pid = sleeper.processIdentifier
            t.expectEqual(RemoteMove.outcome(python(RemoteMove.script(pid: pid, procStart: "999999999")!)), .notIt,
                          "a start that is not its own: not it")
            t.expect(sleeper.isRunning, "and it still runs")
            // Its own start, read the way the script reads it.
            let probe = "import os,subprocess\ntry:\n print(open('/proc/%d/stat' % \(pid)).read().rsplit(')',1)[1].split()[19])\n"
                + "except FileNotFoundError:\n print(subprocess.run(['ps','-o','lstart=','-p','\(pid)'],capture_output=True,text=True,env=dict(os.environ,TZ='UTC')).stdout.strip())\n"
            let start = python(probe).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let script = RemoteMove.script(pid: pid, procStart: start) else { return t.fail("no script for \(start)") }
            t.expectEqual(RemoteMove.outcome(python(script)), .ended)
            sleeper.waitUntilExit()
            t.expect(!sleeper.isRunning, "ended")
        },
    ])
}
