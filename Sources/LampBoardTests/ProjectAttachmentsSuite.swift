import Foundation
import LampBoardCore
import TestKit

/// A file dropped on a session gets a plain name of its own in the project's
/// attachments, and a citation the session can read.
enum ProjectAttachmentsSuite {

    static let suite = TestSuite("Project attachments", [

        TestCase("An attachment gets a plain name of its own in the project's attachments") { t in
            t.expectEqual(ProjectAttachments.attachmentName("screen shot (1).png", taken: []), "screen-shot-1.png")
            t.expectEqual(ProjectAttachments.attachmentName("a.png", taken: ["a.png"]), "a-2.png")
            t.expectEqual(ProjectAttachments.attachmentName("a.png", taken: ["a.png", "a-2.png"]), "a-3.png")
            t.expectEqual(ProjectAttachments.attachmentName("../../etc/passwd", taken: []), "passwd")
            t.expectEqual(ProjectAttachments.attachmentName(".env", taken: []), "env")
            t.expectEqual(ProjectAttachments.citation(of: "a-2.png"), "@.lampboard/allegati/a-2.png")
        },
    ])
}
