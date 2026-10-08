// Written by hand for the vendored copy. Upstream generates this file with a
// SwiftPM build-tool plugin that reads git; the vendored sources have no git of
// their own, so the values are those of the release they were copied from.
// See Vendor/SwiftTerm/VENDORED.md.

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    /// The Git branch, if the build uses a branch checkout.
    public static let branch: String? = nil

    /// The exact Git tag for the current commit, if one is available.
    public static let tag: String? = "v1.20.0"

    /// The full Git commit identifier, if one is available.
    public static let commit: String? = "5d14406844143538cd8f8851d2d8a67c1fe443e5"

    /// Whether the repository had uncommitted changes during the build.
    public static let hasUncommittedChanges: Bool? = false

    /// A value suitable for display in logs and diagnostic output.
    public static let version: String = "v1.20.0"
}
