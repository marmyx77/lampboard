import Foundation

/// A click on a row whose session is already open in a live window (D140).
///
/// The window is where the person is working with it: the click brings that
/// window forward, whatever the click would otherwise do. Before, a session of
/// another machine opened with Open here and left behind another app could be
/// found again only by choosing Open here once more.
public enum LiveClick {

    /// The live window a click on these sessions raises, the row's most urgent
    /// member first; `nil` when none of them is open in one.
    public static func openWindow(for sessions: [SessionState], target: (SessionState) -> LiveTarget?,
                                  isOpen: (LiveTarget) -> Bool) -> LiveTarget? {
        sessions.lazy.compactMap(target).first(where: isOpen)
    }
}
