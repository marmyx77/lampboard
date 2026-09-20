import Foundation

/// Whether the Claude Code on a machine understands a hook of `type: "http"`.
///
/// The migration to native hooks was measured on 2.1.268 and shipped without
/// asking what version anybody else had. Claude Code's changelog puts the `http`
/// type in **2.1.63**; on anything older the native entries are unknown to it,
/// and the panel hears at best the three events that still run the script — a
/// column gone quiet for every person pinned on an old release, with nothing
/// anywhere to say why (D49).
///
/// **Unknown fails open.** A version that could not be read is taken as current:
/// Claude Code updates itself, so the population on an old release is small, and
/// the population on the slow path would be everybody whose `claude` sits
/// somewhere the reader did not look.
public enum NativeHookSupport {

    /// The release that added `type: "http"`, per Claude Code's changelog.
    public static let firstRelease = ReleaseVersion(major: 2, minor: 1, patch: 63)

    /// `true` when this Claude Code takes native hooks. `nil` is "could not
    /// read", and reads as yes — see above.
    public static func isAvailable(in version: ReleaseVersion?) -> Bool {
        guard let version else { return true }
        return version >= firstRelease
    }

    /// The version in what `claude --version` prints — `2.1.278 (Claude Code)` —
    /// or in the name of the native installer's version directory. `nil` for
    /// anything that does not start with one.
    public static func version(fromOutput output: String) -> ReleaseVersion? {
        guard let first = output.split(whereSeparator: \.isWhitespace).first else { return nil }
        return ReleaseVersion(String(first))
    }

    /// The sentence that goes with a degraded installation, or `nil` when there
    /// is nothing to say.
    public static func note(for version: ReleaseVersion?) -> String? {
        guard let version, !isAvailable(in: version) else { return nil }
        return "Claude Code \(version) here: native hooks need \(firstRelease) or later, "
            + "so every event runs the script."
    }
}
