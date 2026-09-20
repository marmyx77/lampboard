import LampBoardCore
import Foundation
import TestKit

/// Whether a Claude Code takes native hooks: the boundary, the parsing, and the
/// direction an unreadable version falls (D49).
enum NativeHookSupportSuite {

    static let suite = TestSuite("Native hook support", [

        TestCase("The boundary is the release that added the type") { t in
            t.expect(!NativeHookSupport.isAvailable(in: ReleaseVersion("2.1.62")), "one before")
            t.expect(NativeHookSupport.isAvailable(in: ReleaseVersion("2.1.63")), "the release itself")
            t.expect(NativeHookSupport.isAvailable(in: ReleaseVersion("2.1.278")), "what was measured")
            t.expect(NativeHookSupport.isAvailable(in: ReleaseVersion("3.0.0")), "a later major")
            t.expect(!NativeHookSupport.isAvailable(in: ReleaseVersion("1.0.38")), "hooks existed, http did not")
        },

        // Claude Code updates itself: the people on an old release are few, the
        // people whose `claude` sits somewhere unexpected are not, and only one
        // of the two groups would pay for a rule that failed closed.
        TestCase("A version that cannot be read is taken as current") { t in
            t.expect(NativeHookSupport.isAvailable(in: nil), "unknown fails open")
            t.expectNil(NativeHookSupport.note(for: nil), "and says nothing about it")
        },

        TestCase("The version is read off what claude prints, or off a directory name") { t in
            t.expectEqual(
                NativeHookSupport.version(fromOutput: "2.1.278 (Claude Code)"), ReleaseVersion("2.1.278"),
                "claude --version"
            )
            t.expectEqual(NativeHookSupport.version(fromOutput: "2.1.50"), ReleaseVersion("2.1.50"), "a bare name")
            t.expectNil(NativeHookSupport.version(fromOutput: "Claude Code 2.1.278"), "words first")
            t.expectNil(NativeHookSupport.version(fromOutput: ""), "nothing")
        },

        TestCase("The note names both versions, and only when it applies") { t in
            let note = NativeHookSupport.note(for: ReleaseVersion("2.1.50"))
            t.expect(note?.contains("2.1.50") == true, "the version found")
            t.expect(note?.contains("2.1.63") == true, "the version needed")
            t.expect(note?.contains("script") == true, "what happens instead")
            t.expectNil(NativeHookSupport.note(for: ReleaseVersion("2.1.63")), "nothing to say when current")
        },
    ])
}
