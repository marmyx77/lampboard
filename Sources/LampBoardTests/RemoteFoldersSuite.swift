import Foundation
import LampBoardCore
import TestKit

/// Browsing another machine's folders to attach a project there.
enum RemoteFoldersSuite {

    static let suite = TestSuite("Another machine's folders", [

        TestCase("The listing starts at home or at an absolute path, quoted, and refuses anything else") { t in
            t.expect(RemoteFolders.list(nil)?.hasPrefix("cd \"$HOME\"") == true, "home when no path")
            t.expect(RemoteFolders.list("/home/dev/it's here")?.hasPrefix(#"cd -- '/home/dev/it'\''s here'"#) == true,
                     RemoteFolders.list("/home/dev/it's here") ?? "")
            t.expectNil(RemoteFolders.list("relative"))
            t.expectNil(RemoteFolders.list("/x\n; rm -rf ~"))
        },

        TestCase("The answer: where it stands, then its folders in Finder's order, hidden ones and the empty glob left out") { t in
            let listing = RemoteFolders.parse("/home/dev\nweb\n.config\nApi 10\nApi 9\n*\n")
            t.expectEqual(listing?.path, "/home/dev")
            t.expectEqual(listing?.folders, ["Api 9", "Api 10", "web"])
            t.expectEqual(listing?.parent, "/home")
            t.expectEqual(listing?.child("web"), "/home/dev/web")
            t.expectEqual(RemoteFolders.parse("/\nhome\n")?.parent, nil)
            t.expectEqual(RemoteFolders.parse("/\nhome\n")?.child("home"), "/home")
            t.expectNil(RemoteFolders.parse(""), "no folder there")
        },
    ])
}
