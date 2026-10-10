// From Clarc (https://github.com/ttnear/Clarc), Apache License 2.0.
// Modified for LampBoard: see Vendor/Clarc/VENDORED.md for what changed.

import Foundation

public extension TimeInterval {
    /// Converts seconds to "Xm Ys" or "Ys" format
    var formattedDuration: String {
        let total = Int(self)
        let m = total / 60
        let s = total % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
