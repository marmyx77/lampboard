import LampBoardCore
import Foundation
import TestKit

/// Naming the machine that is actually at fault.
///
/// ssh says *"remote port forwarding failed for listen port 31000"*, and read
/// literally that sends you to the other machine. Measured once: the port was
/// held by this app's own tunnel from a previous run, orphaned by the `pkill`
/// the build script recommends, and the panel spent two hours blaming a remote
/// box that had done nothing.
enum TunnelRefusalSuite {

    /// What `ps -ax -o pid=,ppid=,command=` really looks like on this Mac.
    private static let listing = """
        64151     1 /usr/bin/ssh -N -a -x -o ExitOnForwardFailure=yes -R 127.0.0.1:31000:127.0.0.1:9877 devmachine
        24376     1 /Applications/LampBoard.app/Contents/MacOS/lampboard
        94563 24376 /usr/bin/ssh -N -a -x -R 127.0.0.1:31002:127.0.0.1:9877 other
        """

    static let suite = TestSuite("Tunnel refusals", [

        TestCase("ssh's own sentence is recognised, and nothing else is") { t in
            t.expect(
                TunnelRefusal.mentionsBindFailure(
                    "Warning: remote port forwarding failed for listen port 31000"
                ),
                "the real message"
            )
            t.expect(!TunnelRefusal.mentionsBindFailure("Permission denied (publickey)."), "a refused key")
            t.expect(!TunnelRefusal.mentionsBindFailure(""), "silence")
        },

        TestCase("A process listing is read, and a malformed line is skipped") { t in
            let processes = TunnelRefusal.parse(listing + "\nnot a process line\n")
            t.expectEqual(processes.count, 3, "three usable lines")
            t.expectEqual(processes.first?.pid, 64151, "pid")
            t.expectEqual(processes.first?.parent, 1, "parent")
            t.expect(processes.first?.command.contains("devmachine") == true, "the command survives whole")
        },

        TestCase("An orphan is the one reparented to pid 1") { t in
            let processes = TunnelRefusal.parse(listing)
            t.expect(processes[0].isOrphan, "reparented to launchd")
            t.expect(!processes[2].isOrphan, "owned by a running panel")
        },

        TestCase("The port is matched exactly, not by prefix") { t in
            // `-R 127.0.0.1:3100:` and `-R 127.0.0.1:310000:` both contain the
            // digits of 31000. Without the trailing colon this would accuse a
            // tunnel that has nothing to do with the failure.
            let processes = TunnelRefusal.parse("""
                101     1 /usr/bin/ssh -N -R 127.0.0.1:3100:127.0.0.1:9877 host
                102     1 /usr/bin/ssh -N -R 127.0.0.1:310000:127.0.0.1:9877 host
                """)
            t.expectEqual(TunnelRefusal.holders(of: 31000, among: processes).count, 0, "neither is ours")
        },

        TestCase("A forward is ours by its specification, not by being ssh") { t in
            let processes = TunnelRefusal.parse("""
                200     1 /usr/bin/ssh -L 127.0.0.1:31000:127.0.0.1:80 somewhere
                """)
            t.expectEqual(
                TunnelRefusal.holders(of: 31000, among: processes).count, 0,
                "a local forward the user set up by hand is not this app's"
            )
        },

        TestCase("The orphan is named, with the command that removes it") { t in
            let message = TunnelRefusal.diagnosis(port: 31000, among: TunnelRefusal.parse(listing))
            t.expectNotNil(message, "a diagnosis")
            t.expect(message?.contains("64151") == true, "names the pid")
            t.expect(message?.contains("left behind") == true, "says whose fault it is")
            t.expect(message?.contains("kill 64151") == true, "and what to do")
        },

        TestCase("A tunnel owned by a running panel is described differently") { t in
            let processes = TunnelRefusal.parse(
                "94563 24376 /usr/bin/ssh -N -R 127.0.0.1:31002:127.0.0.1:9877 other"
            )
            let message = TunnelRefusal.diagnosis(port: 31002, among: processes)
            t.expect(message?.contains("another lampboard") == true, "not an orphan")
            t.expect(message?.contains("kill") != true, "and not something to kill")
        },

        TestCase("When this Mac holds nothing, it says nothing") { t in
            // The message then falls back to ssh's own, which is right: the port
            // really is taken on the other side, by something that is not us.
            t.expectNil(
                TunnelRefusal.diagnosis(port: 31000, among: TunnelRefusal.parse(
                    "24376 1 /Applications/LampBoard.app/Contents/MacOS/lampboard"
                )),
                "nothing to add"
            )
        },
    ])
}
