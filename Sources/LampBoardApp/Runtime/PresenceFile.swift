import AppKit
import LampBoardCore
import Foundation

/// Declares to Claude Code that you are sitting at the Mac.
///
/// Claude Code reads the path in `CLAUDE_CLIENT_PRESENCE_FILE` and, if the file
/// exists, **skips the push notifications to your phone**. Present in binary
/// 2.1.220, verified with `strings`.
///
/// **Off by default**, and not out of generic caution: this feature inverts a
/// Claude Code default. If the detection got it wrong, the result would not be
/// one notification too many but a notification **lost** — and lost notifications
/// go unnoticed. Whoever turns it on chooses that risk knowing what they are
/// trading.
@MainActor
final class PresenceFile {

    private let preferences: Preferences
    private let url: URL
    private var timer: Timer?

    init(preferences: Preferences, url: URL = AppConfig.presenceFileURL) {
        self.preferences = preferences
        self.url = url
    }

    var path: String { url.path }

    func start() {
        stop()
        update()

        let timer = Timer.scheduledTimer(
            withTimeInterval: AppConfig.presencePollInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Deletes the file: to be called when the app shuts down.
    ///
    /// A presence file left behind by an app that is no longer running would say
    /// "I'm at the Mac" forever, and the push notifications would never arrive again.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Internal

    private func update() {
        guard preferences.presenceEnabled else {
            remove()
            return
        }
        isPresent ? write() : remove()
    }

    /// You are at the Mac when the screen isn't locked and you touched something recently.
    private var isPresent: Bool {
        guard !Self.isScreenLocked else { return false }
        return SessionNotifier.secondsSinceLastInput() < AppConfig.presenceIdleThreshold
    }

    private func write() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data("lampboard\n".utf8).write(to: url, options: .atomic)
    }

    /// `true` when the screen is locked.
    ///
    /// CoreGraphics' session dictionary exposes the key without requiring any
    /// permission. When it is missing we assume **not locked**: erring in that
    /// direction delivers one push too many, erring the other way loses it.
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}
