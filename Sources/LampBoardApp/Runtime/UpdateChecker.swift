import LampBoardCore
import Foundation

/// Asks GitHub what the latest release is. Nothing else.
///
/// Deliberately separate from the thing that installs: this one makes a request
/// and returns a value, so it can be wrong, slow or unreachable without any
/// consequence beyond a sentence on screen.
enum UpdateChecker {

    /// The version this build carries, from its own bundle.
    static var runningVersion: ReleaseVersion? {
        ReleaseVersion(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }

    static func check() async -> UpdateDecision {
        guard let current = runningVersion else {
            return .unreadable("this build does not say which version it is")
        }
        return await check(current: current)
    }

    static func check(current: ReleaseVersion) async -> UpdateDecision {
        // The redirect first: no API, no quota shared with the whole office
        // (D50). The API is asked only when the redirect could not be read — a
        // proxy that swallowed it, a network that answered something else — and
        // never when the redirect was read and refused: a target outside this
        // project's releases is an answer, not a glitch to route around.
        let redirected = await followingNothing(current: current)
        switch redirected {
        case .available, .upToDate: return redirected
        case .unreadable(let reason) where reason.contains("outside"): return redirected
        case .unreadable: break
        }
        return await askingTheAPI(current: current)
    }

    /// One request to the address that never changes, with redirects **not**
    /// followed, so the `Location` GitHub answers with is the answer.
    private static func followingNothing(current: ReleaseVersion) async -> UpdateDecision {
        var request = URLRequest(url: ReleaseFeed.latestDownloadURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = AppConfig.updateCheckTimeout
        request.setValue("lampboard/\(current)", forHTTPHeaderField: "User-Agent")

        let session = URLSession(
            configuration: .ephemeral, delegate: RedirectStopper(), delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode) else {
                return .unreadable("GitHub did not say where the latest release is")
            }
            return ReleaseFeed.decide(
                redirect: http.value(forHTTPHeaderField: "Location"), current: current
            )
        } catch {
            return .unreadable("could not reach GitHub: \(error.localizedDescription)")
        }
    }

    /// Stops `URLSession` from following a redirect, so the response handed
    /// back is the 3xx itself and its `Location` can be read.
    private final class RedirectStopper: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static func askingTheAPI(current: ReleaseVersion) async -> UpdateDecision {
        var request = URLRequest(url: ReleaseFeed.latestReleaseURL)
        request.timeoutInterval = AppConfig.updateCheckTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub refuses anonymous requests without one, with a 403 that reads
        // like a rate limit and sends you looking in the wrong place.
        request.setValue("lampboard/\(current)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                switch status {
                case 404:
                    // Not an error: it is what a project with no published
                    // release looks like, and "404" would send somebody to
                    // check their network.
                    return .unreadable("no release has been published yet")
                case 403:
                    // Almost always the anonymous hourly limit, and saying so
                    // saves the next half hour of looking at the network.
                    return .unreadable("GitHub is rate-limiting anonymous requests: try again later")
                default:
                    return .unreadable("GitHub answered \(status)")
                }
            }
            return ReleaseFeed.decide(payload: data, current: current)
        } catch {
            return .unreadable("could not reach GitHub: \(error.localizedDescription)")
        }
    }
}
