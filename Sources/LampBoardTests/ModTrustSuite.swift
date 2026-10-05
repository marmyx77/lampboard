import LampBoardCore
import Foundation
import TestKit

/// What the mod does, said from what Claude Code reads in it.
///
/// The JSON is what `claude plugin validate --strict --json` printed for the
/// mod on the test Mac on 4 October 2026, paths shortened; the calls line is
/// mod 1.1.0's, whose "(via config, panel)" once split one call into three.
enum ModTrustSuite {

    private static let validate = Data(#"""
        {"success":true,"strict":true,"target":"/x/mod/.claude-plugin/plugin.json",
         "manifest":{"file":"/x/mod/.claude-plugin/plugin.json","type":"plugin","errors":[],"warnings":[],"notes":[]},
         "contents":[{"file":"/x/mod/hooks/hooks.json","type":"hooks","errors":[],"warnings":[],"notes":[
           "./register.js hooks: session.start, session.measure, session.end",
           "./register.js calls: $.env.get (via config, panel), $.fs.read (via panel), $.http.fetch (via panel, post), $.session.id (via post), $.session.model (via model)",
           "./register.js env writes: nothing",
           "./register.js env reads: HOME, LAMPBOARD_HOME"]}]}
        """#.utf8)

    static let suite = TestSuite("What the mod does, in sentences", [

        TestCase("Claude Code's reading of the mod becomes four sentences") { t in
            guard let reading = ModTrust.read(validateJSON: validate) else { return t.fail("not read") }
            t.expect(reading.valid, "valid")
            t.expectEqual(reading.problems, [])
            t.expectEqual(reading.sentences, [
                "It runs when a session starts, when its context, cost or limits change and when it ends.",
                "It reads environment variables, reads files, makes network requests, reads the session's id "
                    + "and reads the session's model name.",
                "It changes no environment variable.",
                "It reads the environment variables HOME and LAMPBOARD_HOME.",
            ])
        },

        // The point of the card: a mod that started doing something else must
        // look different, even to a panel that has no words for it.
        TestCase("A call or a hook it has no words for is shown as Claude Code spelled it") { t in
            let changed = Data(#"""
                {"success":true,"contents":[{"notes":["./register.js hooks: session.compact",
                "./register.js calls: $.process.run (via x), $.fs.read (via y)"]}]}
                """#.utf8)
            let sentences = ModTrust.read(validateJSON: changed)?.sentences ?? []
            t.expectEqual(sentences.first, "It runs on session.compact.")
            t.expectEqual(sentences.last, "It uses $.process.run and reads files.")
        },

        TestCase("Errors and warnings are kept, and what is not validate's JSON is nothing") { t in
            let broken = Data(#"{"success":false,"manifest":{"errors":[{"message":"name is missing"}],"warnings":[]}}"#.utf8)
            t.expectEqual(ModTrust.read(validateJSON: broken)?.problems, ["name is missing"])
            t.expectEqual(ModTrust.read(validateJSON: broken)?.valid, false)
            t.expectNil(ModTrust.read(validateJSON: Data("Error: no such file".utf8)))
            t.expectNil(ModTrust.read(validateJSON: Data(#"{"success":true,"contents":[{"notes":[]}]}"#.utf8)),
                        "a valid reading that lists nothing is unreadable, not reassuring")
        },
    ])
}
