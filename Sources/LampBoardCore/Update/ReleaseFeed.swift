import Foundation

/// What the update check concluded.
public enum UpdateDecision: Equatable, Sendable {
    /// Nothing newer is published.
    case upToDate(current: ReleaseVersion)
    /// A newer release exists, and this is where its disk image lives.
    case available(version: ReleaseVersion, downloadURL: URL)
    /// The answer could not be read. Carries what to say, not what went wrong
    /// internally: the person reading it can act on one and not the other.
    case unreadable(String)
}

/// Reads GitHub's "latest release" answer, and refuses everything else.
///
/// This is the part of an updater that decides what will be downloaded and run,
/// so it is written as a parser that says no. Two checks matter more than the
/// rest and neither is about JSON:
///
/// - the download URL is **pinned** to this project's own releases. An answer
///   that arrives over HTTPS is still just an answer; if the field could name
///   any host, whoever could influence it — a compromised account, a proxy that
///   a user was talked into trusting — would be choosing the code that runs on
///   a Mac where this app holds the Accessibility permission.
/// - a draft or a pre-release is not an update. They exist precisely so that
///   something can be published without being offered to anybody.
public enum ReleaseFeed {

    /// Where the check asks. Public so the app and the tests name the same URL.
    public static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/marmyx77/lampboard/releases/latest"
    )!

    /// The only prefix a downloadable asset may have.
    public static let downloadPrefix = "https://github.com/marmyx77/lampboard/releases/download/"

    /// Compares the published release with the running one.
    public static func decide(payload: Data, current: ReleaseVersion) -> UpdateDecision {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return .unreadable("the answer from GitHub could not be read")
        }

        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true {
            return .upToDate(current: current)
        }

        guard let version = ReleaseVersion(object["tag_name"] as? String) else {
            return .unreadable("the latest release carries no version this app understands")
        }
        guard version > current else {
            return .upToDate(current: current)
        }
        guard let url = diskImage(in: object, version: version) else {
            return .unreadable("version \(version) is published without a disk image")
        }
        return .available(version: version, downloadURL: url)
    }

    /// The `.dmg` to fetch: the one that says which version it is.
    ///
    /// A release carries two disk images now and they are the same bytes:
    /// `LampBoard-0.2.9.dmg`, and a copy called `LampBoard.dmg` that exists so
    /// `/releases/latest/download/LampBoard.dmg` is an address nobody has to
    /// edit — what a fleet manager polls on a schedule.
    ///
    /// This picks the versioned one deliberately rather than taking whichever
    /// GitHub happens to list first. Either would install the same application;
    /// the difference is what can be read back afterwards. Everything this app
    /// says about an update — the sentence in the menu, a failure while
    /// downloading, a line in the log — carries the name of the file it went
    /// for, and `LampBoard.dmg` names no version at all. Choosing by luck of the
    /// listing order would also mean the answer could change between two checks
    /// with nothing having changed.
    private static func diskImage(in object: [String: Any], version: ReleaseVersion) -> URL? {
        guard let assets = object["assets"] as? [[String: Any]] else { return nil }

        var fallback: URL?
        for asset in assets {
            guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                  let raw = asset["browser_download_url"] as? String,
                  raw.hasPrefix(downloadPrefix),
                  let url = URL(string: raw)
            else { continue }
            if name.contains(version.description) { return url }
            // Still a disk image of ours, and better than refusing the update:
            // a release published under names nobody here predicted is a release
            // somebody can still install.
            if fallback == nil { fallback = url }
        }
        return fallback
    }
}
