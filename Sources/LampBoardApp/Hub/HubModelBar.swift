import AppKit
import LampBoardCore

/// The command bar's actions (D157): each goes through the session's mod or,
/// for the mode, through the terminal LampBoard shows; none writes Claude
/// Code's settings, which would change every session (measured, M0).
extension HubModel {

    /// A slash line the session knows, as a command; `nil` when it is words.
    func runSlash(_ text: String, in id: String) -> HubComposer.Outcome? {
        guard commandable.contains(id), let slash = HubBar.slash(text, known: bar.names) else { return nil }
        guard deps.command(id, "command", ["name": slash.name, "args": slash.args]) else {
            notice = "The command did not go. It is still in the box."
            return .refused
        }
        notice = nil
        composer.ran()
        return .sent
    }

    /// The model for this session alone, from its next request; asked twice
    /// over a warm cache, which another model reads again at full price.
    func choose(model value: String?) {
        guard let id = session?.id, commandable.contains(id) else {
            notice = "Choosing the model needs LampBoard's helper in this session."
            return
        }
        guard value != bar.model else { return bar.warn(nil) }
        if HubBar.cacheWarm(session?.context, now: Date()), pendingModel != .some(value) {
            pendingModel = .some(value)
            let name = value.flatMap { id in HubBar.models.first { $0.id == id }?.title } ?? "the session's default"
            bar.warn("The cache is warm: \(name) reads the whole conversation again at full price. Choose it again to switch.")
            return
        }
        pendingModel = nil
        guard deps.command(id, "model", ["value": value ?? ""]) else {
            notice = "The model did not change: the helper did not take it."
            return
        }
        bar.chose(model: value, for: id)
    }

    func choose(effort value: String?) {
        guard let id = session?.id, commandable.contains(id), deps.command(id, "effort", ["value": value ?? ""]) else {
            notice = "Choosing the effort needs LampBoard's helper in this session."
            return
        }
        bar.chose(effort: value, for: id)
    }

    /// Whether `mode` can be reached from here: Plan by its command, any mode
    /// by Shift+Tab where LampBoard shows the session's terminal.
    func canReach(_ mode: HubBar.Mode) -> Bool {
        guard let id = session?.id, session?.status != .awaiting else { return false }
        if mode == .plan, commandable.contains(id), bar.names.contains("plan") { return true }
        guard let current = bar.mode, HubBar.presses(from: current, to: mode) != nil else { return false }
        return deps.canShiftTab(id)
    }

    /// Reaches `target`: Plan by its command where it can, else one Shift+Tab
    /// at a time, each waited for in the footer the mod reports, never while
    /// the session asks something (a key there would answer it).
    func choose(mode target: HubBar.Mode) {
        guard let id = session?.id, canReach(target), bar.mode != target else { return }
        bar.reach(target)
        if target == .plan, commandable.contains(id), bar.names.contains("plan"), !deps.canShiftTab(id) {
            guard deps.command(id, "command", ["name": "plan", "args": ""]) else { return bar.reach(nil) }
            // The footer says when it took; a command that did nothing frees the menu.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if bar.reaching == target { bar.reach(nil) }
            }
            return
        }
        Task { @MainActor in
            for _ in 0..<HubBar.cycle.count {
                guard bar.reaching == target, bar.mode != target, session?.id == id, session?.status != .awaiting else { break }
                let before = bar.mode
                guard deps.shiftTab(id) else { break }
                var moved = false
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if bar.mode != before { moved = true; break }
                }
                if !moved {
                    notice = "The session did not show a new mode. Check its window."
                    break
                }
            }
            bar.reach(nil)
        }
    }

    /// Claude Code's Remote Control, by its own command.
    func toggleRemoteControl() {
        guard let id = session?.id, commandable.contains(id), bar.names.contains("remote-control"),
              deps.command(id, "command", ["name": "remote-control", "args": ""]) else {
            notice = "Remote Control needs LampBoard's helper in this session."
            return
        }
        notice = "Remote Control: the session shows its link and QR code in its window."
    }

    /// Asks for files and attaches them.
    func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Attach to the message: copied into the project's .lampboard/allegati"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await self?.attach(urls) }
        }
    }

    /// Copies `files` into the open session's project and cites each in the box.
    func attach(_ files: [URL]) async {
        guard let id = session?.id, let project = deps.project(id) else { return }
        let names = await ProjectSource(root: project.root, host: project.host).attach(files)
        for name in names { composer.insert(citation: HubBar.citation(of: name), at: nil) }
        notice = names.count == files.count ? nil : "Some files were not attached (too large, or the folder refused them)."
    }
}
