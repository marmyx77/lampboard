import CoreGraphics
import Foundation

/// How much of the panel is out (UX §1): the column of lights, the panel with
/// its rows and queue, or the Plancia with one session open beside the list.
public enum PanelDepth: String, Sendable, CaseIterable {
    case column, panel, plancia

    /// `⌘⇧L`: one deeper, and from the Plancia back to the column.
    public var next: PanelDepth {
        switch self {
        case .column: return .panel
        case .panel: return .plancia
        case .plancia: return .column
        }
    }

    /// `Esc`: one level down, and the column stays the column.
    public var down: PanelDepth {
        switch self {
        case .column, .panel: return .column
        case .plancia: return .panel
        }
    }

    /// The widths of the UX: the prototype's were at its own scale, these are
    /// the ones it settled on.
    public var width: CGFloat {
        switch self {
        case .column: return 44
        case .panel: return 340
        case .plancia: return 780
        }
    }

    /// The Plancia goes back to the panel by itself when nothing waits and the
    /// pointer has been elsewhere this long — unless it is pinned open.
    public static let planciaLingers: TimeInterval = 4

    public static func closesPlancia(queueEmpty: Bool, pointerAwayFor seconds: TimeInterval, pinned: Bool) -> Bool {
        queueEmpty && !pinned && seconds >= planciaLingers
    }
}
