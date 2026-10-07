import AppKit
import LampBoardCore
import Foundation

/// The update, from the menu entry to the app coming back.
///
/// Two dialogs and no surprises: one that says what was found, one that says what
/// went wrong if it did. The install is never reached without somebody having
/// read a version number and pressed a button — macOS grants Accessibility to a
/// signing identity, so whatever replaces this app inherits the run of the
/// machine, and that decision stays with the person who granted it.
@MainActor
enum UpdateFlow {

    static func run(report: @escaping (String) -> Void, clear: @escaping () -> Void) async {
        switch await UpdateChecker.check() {
        case .upToDate(let current):
            Alerts.warn(
                title: "LampBoard is up to date",
                message: "Version \(current) is the latest release."
            )

        case .unreadable(let reason):
            Alerts.warn(title: "Could not check for updates", message: reason)

        case .available(let version, let url):
            let current = UpdateChecker.runningVersion.map(String.init(describing:))
                ?? "this build"
            guard Alerts.confirm(
                title: "Version \(version) is available",
                message: """
                    You are running \(current).

                    lampboard will download the release from GitHub, check that it \
                    is signed by the same certificate as this copy and notarized by \
                    Apple, then replace itself and start again. Nothing is installed \
                    if any of those checks fails.
                    """,
                confirmTitle: "Download and install"
            ) else { return }

            report("Downloading version \(version)…")
            do {
                try await UpdateInstaller.install(from: url)
            } catch {
                clear()
                Alerts.warn(
                    title: "The update was not installed",
                    message: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
        }
    }
}
