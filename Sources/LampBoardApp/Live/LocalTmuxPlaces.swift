import Foundation
import LampBoardCore

/// Where this Mac's sessions sit in tmux, asked every ten seconds (D132).
///
/// A row's menu offers Open here only for a session it can open, and building a
/// menu must not run a command; so the answer is kept ready. One `tmux
/// list-panes` of the default server per round, and each live session's
/// ancestry walked up to a pane's shell. No tmux installed, or no server
/// running, is simply no places.
@MainActor
final class LocalTmuxPlaces {

    private(set) var places: [String: TmuxPlace] = [:]
    private var clock: Timer?
    private var asking = false

    func start() {
        guard clock == nil else { return }
        refresh()
        clock = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        clock?.invalidate()
        clock = nil
    }

    /// The tmux this Mac has: where people install it. Under a fake home only
    /// the fake home's own, so a test never reaches the person's sessions.
    nonisolated static func executable() -> String? {
        let own = AppConfig.homeDirectory.appendingPathComponent(".local/bin/tmux").path
        let candidates = AppConfig.isUsingHomeOverride ? [own] : [own, "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func refresh() {
        guard !asking, let tmux = Self.executable() else { return }
        asking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Self.ask(tmux)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.asking = false
                // tmux that did not answer is no news: the places stay, so Open
                // here does not blink out of the menus for a slow second.
                guard let found, found != self.places else { return }
                Diagnostics.log("live: \(found.count) sessions placed in this Mac's tmux")
                self.places = found
            }
        }
    }

    /// `nil` when tmux did not answer; no panes is an answer, and no places.
    nonisolated private static func ask(_ tmux: String) -> [String: TmuxPlace]? {
        guard let result = try? Command.run(tmux, ["list-panes", "-a", "-F", TmuxPlace.paneFormat], deadline: 2,
                                            capturingStandardError: false, environment: ["TMUX": nil])
        else { return nil }
        let panes = TmuxPlace.panes(result.output)
        guard !panes.isEmpty else { return [:] }
        var found: [String: TmuxPlace] = [:]
        for session in LiveSessionReader().readLiveSessions()
        where session.pid > 1 && TmuxPlace.isPlaceable(entrypoint: session.entrypoint, isBackground: session.isBackground) {
            let ancestry = ProcessTree.ancestry(of: pid_t(session.pid)).map(\.pid)
            if let place = TmuxPlace.place(ofAncestry: ancestry, in: panes) { found[session.sessionId] = place }
        }
        return found
    }
}
