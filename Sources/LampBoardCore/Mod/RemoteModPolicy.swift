import Foundation

/// When the helper goes to another machine at launch (B1, D143).
public enum RemoteModPolicy {

    /// With the helper on here: a machine whose helper is older than this
    /// one's, or that has the hooks and no helper at all. Never a machine
    /// without the hooks, which nobody connected, nor a newer helper's.
    public static func shouldInstall(hooksThere: Bool, modThere: String?, ours: String) -> Bool {
        guard let modThere else { return hooksThere }
        guard let theirs = ReleaseVersion(modThere), let mine = ReleaseVersion(ours) else { return false }
        return theirs < mine
    }
}
