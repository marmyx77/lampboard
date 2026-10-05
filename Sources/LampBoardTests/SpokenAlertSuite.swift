import LampBoardCore
import Foundation
import TestKit

/// The voice (§5.9, V1): a permission said aloud to someone near the Mac but
/// not at its keys.
enum SpokenAlertSuite {

    static let suite = TestSuite("Spoken alert", [

        TestCase("Said only when asked for, the screen unlocked and nobody at the keys for a minute") { t in
            t.expect(SpokenAlert.speaks(enabled: true, idle: 61, locked: false), "a minute without a key: said")
            t.expect(!SpokenAlert.speaks(enabled: true, idle: 30, locked: false), "at the keys: the notification is enough")
            t.expect(!SpokenAlert.speaks(enabled: true, idle: 600, locked: true), "locked: nobody to hear it, or away soon")
            t.expect(!SpokenAlert.speaks(enabled: false, idle: 600, locked: false), "off unless asked for")
        },

        TestCase("The sentence is the row's name and that it waits: one plain line, cut") { t in
            t.expectEqual(SpokenAlert.sentence(name: "docs-site"), "docs-site is waiting for you.")
            t.expectEqual(SpokenAlert.sentence(name: "api\nserver\u{202E}"), "api server is waiting for you.", "flat, nothing hidden")
            let long = SpokenAlert.sentence(name: String(repeating: "x", count: 200))
            t.expectEqual(long, String(repeating: "x", count: SpokenAlert.longestName) + " is waiting for you.", "a long name cut")
            t.expectEqual(SpokenAlert.sentence(name: "  "), "A session is waiting for you.", "no name: still said")
        },
    ])
}
