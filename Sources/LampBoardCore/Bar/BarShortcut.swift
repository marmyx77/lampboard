import Foundation

/// The shortcut that reaches the bar from any application (D77): off until
/// somebody picks one. A short list rather than a recorder: each one on it was
/// chosen not to be a chord an editor begins with, which a free choice could be.
public enum BarShortcut: String, Sendable, CaseIterable {
    case off
    case optionCommandK
    case controlCommandK

    public var label: String {
        switch self {
        case .off: return "Off"
        case .optionCommandK: return "⌥⌘K"
        case .controlCommandK: return "⌃⌘K"
        }
    }

    /// The virtual key code (`kVK_ANSI_K`), `nil` when off.
    public var keyCode: UInt32? { self == .off ? nil : 40 }

    /// Carbon's modifier mask: `cmdKey` 0x100, `optionKey` 0x800, `controlKey` 0x1000.
    public var carbonModifiers: UInt32 {
        switch self {
        case .off: return 0
        case .optionCommandK: return 0x100 | 0x800
        case .controlCommandK: return 0x100 | 0x1000
        }
    }

    /// A stored value read back; anything unknown is off, never a guess.
    public static func stored(_ raw: String?) -> BarShortcut {
        raw.flatMap(BarShortcut.init(rawValue:)) ?? .off
    }
}
