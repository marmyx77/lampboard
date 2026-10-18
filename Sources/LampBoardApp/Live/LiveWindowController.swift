import AppKit
import LampBoardCore
import LampBoardMacSource
import SwiftUI

/// The live view's windows, one per background session (D130).
///
/// A window holds `claude attach <id>` in a terminal of LampBoard's own. Closing
/// it detaches, as leaving a terminal does: the session goes on under Claude
/// Code's supervisor and its lamp keeps working. Opening the same session again
/// brings its window forward rather than attaching twice, because two attaches
/// of different sizes garble each other (measured, 8 October 2026).
@MainActor
final class LiveWindowController: NSObject, NSWindowDelegate {

    private final class Live {
        let target: LiveTarget
        var job: String { target.key }
        /// `nil` while it sits in the Hub's centre (hub-terminale R1).
        var window: NSWindow?
        let surface: LiveSurface
        /// What attaches it, kept for the first start.
        var command: LiveCommand!
        let frame: LiveFrameView
        var ended = false
        init(target: LiveTarget, window: NSWindow?, surface: LiveSurface, frame: LiveFrameView) {
            self.target = target; self.window = window; self.surface = surface; self.frame = frame
        }
    }

    private var lives: [String: Live] = [:]
    /// The background sessions' attaches, shared with the phone's bridge (W5):
    /// one at a time per job, whoever opened it.
    var attaches: MacAttachLedger?
    /// The Hub's job terminals a phone may share.
    var shares: HubShares?
    /// The conversations being moved here (D135).
    private var moving: Set<String> = []
    private var clock: Timer?
    private let preferences: Preferences
    /// The header of a window: its row's name, folder and state.
    private let describe: (LiveTarget) -> LiveHeading
    /// A surface for each window. A test could hand in another.
    private let makeSurface: @MainActor () -> LiveSurface

    init(preferences: Preferences, describe: @escaping (LiveTarget) -> LiveHeading,
         makeSurface: (@MainActor () -> LiveSurface)? = nil) {
        self.preferences = preferences
        self.describe = describe
        self.makeSurface = makeSurface ?? { SwiftTermSurface() }
    }

    // MARK: - Opening

    /// Opens a background job of this Mac (`--live`, a start).
    @discardableResult
    func open(job: String) -> Bool { open(.job(job)) }

    /// Opens `target`'s window, or brings it forward. `false` when no command
    /// can open it (`claude` not found, an id or a host refused).
    @discardableResult
    func open(_ target: LiveTarget) -> Bool {
        let job = target.key
        if let found = lives[job] {
            if found.ended { attach(found) }
            // `attach` puts a new one in its place: the window goes to that one.
            let live = lives[job] ?? found
            if live.window == nil {
                // In the Hub: out of it and into a window of its own, the same attach.
                live.frame.removeFromSuperview()
                live.frame.setInHub(false)
                live.window = makeWindow(content: live.frame, target: target)
                hubRecent.removeAll { $0 == job }
                updateDockPresence()
            }
            if let window = live.window { bringToFront(window) }
            return true
        }
        guard let live = makeLive(target) else { return false }
        let window = makeWindow(content: live.frame, target: target)
        live.window = window
        lives[job] = live
        updateDockPresence()
        start(live, live.command)
        bringToFront(window)
        window.makeFirstResponder(live.surface.view)
        startClock()
        return true
    }

    // MARK: - The Hub's centre

    /// Where a session LampBoard opens is shown: the Hub, when it takes it
    /// (hub-terminale R1), else a window of its own.
    var openInHub: ((LiveTarget) -> Bool)?

    /// `target` in the Hub, or in a window.
    @discardableResult
    func show(_ target: LiveTarget) -> Bool {
        if openInHub?(target) == true { return true }
        return open(target)
    }

    /// The Hub's sessions still attached, the most recent last.
    private var hubRecent: [String] = []
    /// How many sessions the Hub keeps attached: going back to one of them is
    /// instant, and every other one is left, its session going on.
    static let hubKept = 4

    /// `target`'s terminal, for the Hub's centre: the one already open (out of
    /// its window if it had one, so that one attach serves both), or a new
    /// attach. `nil` when nothing can open it.
    func hosted(_ target: LiveTarget) -> NSView? {
        let job = target.key
        if let live = lives[job] {
            if let window = live.window {
                live.window = nil
                window.delegate = nil
                window.contentView = NSView()
                window.close()
                updateDockPresence()
            }
            live.frame.setInHub(true)
            if live.ended { attach(live) }
            keepInHub(job)
            return lives[job]?.frame
        }
        guard let live = makeLive(target) else { return nil }
        live.frame.setInHub(true)
        lives[job] = live
        start(live, live.command)
        startClock()
        keepInHub(job)
        return live.frame
    }

    /// The Hub's session's terminal, to give it the keys.
    func hostedTerminal(_ target: LiveTarget) -> NSView? {
        guard let live = lives[target.key], live.window == nil else { return nil }
        return live.surface.view
    }

    /// Whether `target`'s terminal is in a window of its own.
    func isInWindow(_ target: LiveTarget) -> Bool { lives[target.key]?.window != nil }

    /// Whether the Hub's session has left (its attach ended).
    func hostedEnded(_ target: LiveTarget) -> Bool { lives[target.key]?.ended ?? false }

    /// Opens the Hub's session again after its attach ended.
    func reattachHosted(_ target: LiveTarget) {
        guard let live = lives[target.key], live.ended else { return }
        attach(live)
    }

    /// The Hub closed: its attaches end, its sessions go on. A temporary
    /// session's terminal is the session (D168): it stays, until it is ended or
    /// LampBoard quits.
    func endHosted() {
        for live in lives.values where live.window == nil && live.target.outlivesItsTerminal { end(live) }
        hubRecent = hubRecent.filter { lives[$0] != nil }
    }

    /// Ends one session's terminal: a temporary one ends with it (D168).
    func endHosted(_ target: LiveTarget) {
        guard let live = lives[target.key] else { return }
        if let window = live.window { window.delegate = nil; window.close() }
        hubRecent.removeAll { $0 == target.key }
        end(live)
        updateDockPresence()
    }

    /// The temporary session's target running `sessionId`, if one does here.
    func directTarget(for sessionId: String) -> LiveTarget? {
        lives.values.first { if case .direct = $0.target { return $0.target.sessionId == sessionId }; return false }?.target
    }

    private func keepInHub(_ job: String) {
        hubRecent.removeAll { $0 == job }
        hubRecent.append(job)
        // Only attaches are left: a temporary session's terminal is the session.
        let detachable = hubRecent.filter { lives[$0]?.target.outlivesItsTerminal ?? true }
        for oldest in detachable.dropLast(Self.hubKept) {
            hubRecent.removeAll { $0 == oldest }
            if let live = lives[oldest], live.window == nil { end(live) }
        }
    }

    /// A job's attach here is over: the bridge may take it, and no phone shares it.
    private func letGo(_ target: LiveTarget) {
        guard case .job(let id) = target else { return }
        attaches?.release(id, by: .hub)
        shares?.unregister(job: id)
    }

    private func end(_ live: Live) {
        letGo(live.target)
        live.surface.onExit = nil
        live.surface.end(waiting: false)
        LiveProcesses.forget(pid: live.surface.pid)
        lives[live.job] = nil
        if lives.isEmpty { clock?.invalidate(); clock = nil }
    }

    /// A surface, its frame and the command that attaches it, not started.
    private func makeLive(_ target: LiveTarget) -> Live? {
        let job = target.key
        // An iPhone or iPad has this background session open through the
        // bridge: a second attach here would be a second writer (D130).
        if case .job(let id) = target, attaches?.holder(of: id) == .bridge { return nil }
        guard let command = command(for: target) else { return nil }
        let theme = preferences.liveAppearance.theme
        let surface = makeSurface()
        let frame = LiveFrameView(theme: theme, terminal: surface.view)
        let live = Live(target: target, window: nil, surface: surface, frame: frame)
        live.command = command
        frame.reattach.target = self
        frame.reattach.action = #selector(reattachPressed(_:))
        frame.reattach.identifier = NSUserInterfaceItemIdentifier(job)
        surface.apply(preferences.liveAppearance)
        // A session on another machine: a file dropped is copied there, into the
        // project's attachments, and cited (D165); a path of this Mac means nothing there.
        if target.host != nil {
            surface.onFileDrop = { [weak self] urls in self?.dropElsewhere(urls, on: target) ?? false }
        }
        return live
    }

    /// Where a session on another machine works: its machine and folder.
    var remoteFolder: (LiveTarget) -> (host: String, folder: String)? = { _ in nil }

    /// Copies `urls` to `target`'s machine and types their citations; `false`
    /// when its folder there is not known, and the paths are typed instead.
    private func dropElsewhere(_ urls: [URL], on target: LiveTarget) -> Bool {
        guard let place = remoteFolder(target) else { return false }
        let job = target.key
        let source = ProjectSource(root: place.folder, host: place.host)
        Task { [weak self] in
            let names = await source.attach(urls)
            guard let self, let live = self.lives[job], !live.ended else { return }
            guard !names.isEmpty else {
                NSSound.beep()
                Diagnostics.log("drop: nothing could be copied to \(place.host):\(place.folder)")
                return
            }
            live.surface.paste(names.map(ProjectAttachments.citation(of:)).joined(separator: " ") + " ")
        }
        return true
    }

    /// Starts a new background session in `directory`, then opens it. The start
    /// runs off the main thread: `claude --bg` may first start the supervisor.
    func start(directory: String, name: String?, failed: @escaping (String) -> Void) {
        guard let claude = LampMasterRunner.executable(),
              let command = LiveLaunch.start(directory: directory, name: name, permissions: preferences.sessionPermissions, claude: claude,
                                             environment: ProcessInfo.processInfo.environment,
                                             home: AppConfig.homeDirectory.path)
        else { failed(LiveLaunch.StartFailure.other("Claude Code was not found on this Mac.").message); return }
        // Variables the command does not keep are taken away, not inherited.
        var environment: [String: String?] = [:]
        for key in ProcessInfo.processInfo.environment.keys where command.environment[key] == nil { environment[key] = .some(nil) }
        for (key, value) in command.environment { environment[key] = value }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = try? Command.run(command.executable, command.arguments, deadline: 60,
                                          directory: command.directory.map(URL.init(fileURLWithPath:)),
                                          environment: environment)
            let output = result?.output ?? ""
            let job = result?.succeeded == true ? LiveLaunch.jobId(fromBackgroundOutput: output) : nil
            DispatchQueue.main.async {
                if let job, self?.show(.job(job)) == true { return }
                failed(LiveLaunch.startFailure(fromOutput: output).message)
            }
        }
    }

    /// Ends the editor's process of a conversation and takes it up as a
    /// background session here (D135). Off the main thread: the process gets
    /// ten seconds to save what it holds before the new one starts.
    /// Where a moved conversation goes on when tmux is there (hub-terminale R6):
    /// taken up in tmux, its terminal in the Hub. `false` when it cannot, and the
    /// move goes on in the background as before.
    var resumeInTmux: ((_ folder: String, _ sessionId: String, _ name: String, _ failed: @escaping (String) -> Void) -> Bool)?

    func move(_ process: SessionProcess, name: String, failed: @escaping (String) -> Void) {
        // One move per conversation at a time: a second would start a second writer.
        guard !moving.contains(process.sessionId) else { return }
        let inTmux = resumeInTmux != nil && LocalTmuxPlaces.executable() != nil
        guard let claude = LampMasterRunner.executable(),
              let command = LiveLaunch.start(directory: process.cwd, name: name, resume: process.sessionId,
                                             permissions: preferences.sessionPermissions, claude: claude,
                                             environment: ProcessInfo.processInfo.environment,
                                             home: AppConfig.homeDirectory.path)
        else { failed(LiveLaunch.StartFailure.other("Claude Code was not found on this Mac.").message); return }
        var environment: [String: String?] = [:]
        for key in ProcessInfo.processInfo.environment.keys where command.environment[key] == nil { environment[key] = .some(nil) }
        for (key, value) in command.environment { environment[key] = value }
        // The same lock a phone's Move takes through the bridge (W3c, W5): of
        // two Moves of one conversation, one ends the process and one is told.
        let home = AppConfig.homeDirectory.path
        guard MoveLock.take(session: process.sessionId, home: home) else {
            failed("Another device is moving this conversation now. Nothing was moved.")
            return
        }
        moving.insert(process.sessionId)
        let finish: @MainActor (String?) -> Void = { [weak self] message in
            self?.moving.remove(process.sessionId)
            MoveLock.release(session: process.sessionId, home: home)
            if let message { failed(message) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard SessionTerminator.terminate(process) else {
                DispatchQueue.main.async { finish("The VS Code process would not end, or had already gone. Nothing was moved.") }
                return
            }
            // Gone, or a pid now reused by another process: either way not it.
            let deadline = Date().addingTimeInterval(10)
            while SessionTerminator.isStillRunning(process), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            guard !SessionTerminator.isStillRunning(process) else {
                DispatchQueue.main.async { finish("The VS Code process is still running after ten seconds. Nothing was started, so the conversation has one writer.") }
                return
            }
            if inTmux {
                DispatchQueue.main.async {
                    if self?.resumeInTmux?(process.cwd, process.sessionId, name, { finish($0) }) == true { finish(nil) }
                    else { finish("tmux could not take the conversation up. Nothing was started, so it has one writer: resume it yourself with claude --resume \(process.sessionId).") }
                }
                return
            }
            let result = try? Command.run(command.executable, command.arguments, deadline: 60,
                                          directory: URL(fileURLWithPath: process.cwd), environment: environment)
            let output = result?.output ?? ""
            let job = result?.succeeded == true ? LiveLaunch.jobId(fromBackgroundOutput: output) : nil
            let outcome: MoveHere.Outcome
            if let job { outcome = .started(job: job) }
            else if let result, !result.succeeded, !output.isEmpty { outcome = .refused(LiveLaunch.startFailure(fromOutput: output).message) }
            else { outcome = .unknown }
            DispatchQueue.main.async {
                if case .started(let job) = outcome, self?.show(.job(job)) == true { finish(nil); return }
                if case .refused = outcome {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MoveHere.fallback(sessionId: process.sessionId, folder: process.cwd), forType: .string)
                }
                finish(MoveHere.message(outcome, sessionId: process.sessionId, folder: process.cwd))
            }
        }
    }

    /// Whether `target` has a live window, attached or ended.
    func isOpen(_ target: LiveTarget) -> Bool { lives[target.key] != nil }

    /// Whether a conversation is being moved right now.
    func isMoving(_ sessionId: String) -> Bool { moving.contains(sessionId) }

    // MARK: - What other parts of the app ask

    /// What the open windows show, attached right now.
    var openTargets: [LiveTarget] { lives.values.filter { !$0.ended }.map(\.target) }

    /// Text as a paste into `job`'s session, without Enter (`@path`, a quote).
    @discardableResult
    func paste(_ text: String, into job: String) -> Bool {
        guard let live = lives[job], !live.ended else { return false }
        live.surface.paste(text)
        return true
    }

    /// The same, once the program has asked for bracketed paste (Claude Code
    /// does as it starts), and at most ten seconds later: before it, a paste
    /// would be typed.
    func pasteWhenReady(_ text: String, into job: String, giveUp: Date = Date().addingTimeInterval(10)) {
        guard let live = lives[job], !live.ended else { return }
        if live.surface.acceptsPaste || Date() >= giveUp { live.surface.paste(text); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.pasteWhenReady(text, into: job, giveUp: giveUp)
        }
    }

    /// The open windows, for `GET /live`. What a window shows is a person's
    /// conversation, and the token is also held by other machines' hooks: the
    /// screen's text is given only against a fake home, to the end-to-end suite.
    func report(includingText: Bool) -> Data {
        let views = lives.values.sorted { $0.job < $1.job }.map { live -> [String: Any] in
            var view: [String: Any] = ["job": live.job, "pid": Int(live.surface.pid),
                                       "dock": NSApp.activationPolicy() == .regular, "keys": AppMenu.keys, "keyRouted": keyRouted,
                                       "running": live.surface.isRunning && !live.ended,
                                       "title": live.window?.title ?? describe(live.target).title, "inHub": live.window == nil]
            if includingText {
                view["text"] = live.surface.screenText(lines: 40)
                if let folder = describe(live.target).folder { view["folder"] = folder }
            }
            return view
        }
        return (try? JSONSerialization.data(withJSONObject: ["views": views], options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// A picture of every open window, for the README and for a check on a Mac
    /// whose screen cannot be photographed from outside: `<path>-<job>.png`.
    ///
    /// In two parts, composed. The frame comes through its layer tree; the
    /// terminal through its own drawing, at its own origin. Drawn into the
    /// window's bitmap at once, the terminal's text came out missing: its glyphs
    /// are placed relative to where it sits in the window, and the capture
    /// clipped them away while keeping the cell backgrounds (measured).
    func snapshot(to path: String) {
        for live in lives.values {
            guard let view = live.window?.contentView ?? (live.frame.superview == nil ? nil : live.frame) else { continue }
            view.wantsLayer = true
            let scale = view.window?.backingScaleFactor ?? 2
            let terminal = live.surface.view
            guard let layer = view.layer,
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                                pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext,
                  let alone = terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds) else { continue }
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            terminal.cacheDisplay(in: terminal.bounds, to: alone)
            if let image = alone.cgImage {
                context.draw(image, in: terminal.convert(terminal.bounds, to: view))
            }
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-\(live.job).png"))
        }
    }

    /// A theme or a size changed in Settings: every open window takes it.
    func applyAppearance() {
        let theme = preferences.liveAppearance.theme
        for live in lives.values {
            live.frame.apply(theme: theme)
            live.surface.apply(preferences.liveAppearance)
        }
    }

    /// Quitting: every attach ends, every session goes on. Waited for, since a
    /// timer set now would never fire; an attach that outlives even SIGKILL
    /// stays in the ledger for the next launch.
    func endAll() {
        clock?.invalidate()
        clock = nil
        for live in lives.values {
            live.surface.end(waiting: true)
            if !live.surface.isStillOurs { LiveProcesses.forget(pid: live.surface.pid) }
        }
        lives.removeAll()
    }

    // MARK: - Inside

    private func command(for target: LiveTarget) -> LiveCommand? {
        // An ssh needs no `claude` here; an attach does.
        let claude = LampMasterRunner.executable()
        if case .job = target, claude == nil { return nil }
        return LiveLaunch.command(for: target, claude: claude ?? "", environment: ProcessInfo.processInfo.environment,
                                  home: AppConfig.homeDirectory.path, tmux: LocalTmuxPlaces.executable())
    }

    private func start(_ live: Live, _ command: LiveCommand) {
        live.ended = false
        live.surface.onExit = { [weak self, weak live] _ in
            guard let self, let live else { return }
            live.ended = true
            LiveProcesses.forget(pid: live.surface.pid)
            self.letGo(live.target)
            self.refreshHeaders()
        }
        if case .job(let id) = live.target {
            _ = attaches?.take(id, for: .hub)
            shares?.register(job: id, surface: live.surface)
        }
        live.surface.start(command)
        LiveProcesses.record(pid: live.surface.pid, job: live.job)
        refreshHeaders()
    }

    /// The attach ended (the session stopped, or `/exit`): the same window,
    /// a new surface on the same session.
    private func attach(_ live: Live) {
        guard live.ended, let command = command(for: live.target) else { return }
        let replacement = Live(target: live.target, window: live.window, surface: makeSurface(), frame: live.frame)
        // The old one has exited: ending it closes its pty and signals nothing.
        live.surface.onExit = nil
        live.surface.end(waiting: false)
        // The frame keeps its place; only the terminal inside the card changes.
        live.frame.replaceTerminal(live.surface.view, with: replacement.surface.view)
        replacement.surface.apply(preferences.liveAppearance)
        lives[live.job] = replacement
        start(replacement, command)
        replacement.surface.view.window?.makeFirstResponder(replacement.surface.view)
    }

    @objc private func reattachPressed(_ sender: NSButton) {
        guard let job = sender.identifier?.rawValue, let live = lives[job], live.ended else { return }
        attach(live)
    }

    private func makeWindow(content: NSView, target: LiveTarget) -> NSWindow {
        let job = target.key
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = describe(target).title
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.minSize = NSSize(width: 560, height: 360)
        // Each session's window comes back where it was; a first one is centred,
        // the next ones cascade from the last.
        let name = "lampboard-live-\(job)"
        if !window.setFrameUsingName(name) {
            if let last = lives.values.compactMap(\.window).last { window.cascadeTopLeft(from: NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24)) }
            else { window.center() }
        }
        window.setFrameAutosaveName(name)
        window.delegate = self
        return window
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A live window is somewhere to come back to (D138): while one is open,
    /// LampBoard has a Dock icon, a place in ⌘Tab and a Window menu listing
    /// them; with the last one closed it is a menu-bar app again.
    /// Another window that needs the Dock and the menu while it is open: the Hub.
    var keepsDock: () -> Bool = { false }

    func refreshDockPresence() { updateDockPresence() }

    private func updateDockPresence() {
        let windows = lives.values.contains { $0.window != nil }
        let policy: NSApplication.ActivationPolicy = !windows && !keepsDock() ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// ⌘V pressed in `job`'s window, as a keyboard would, with `text` on the
    /// pasteboard: the way the end-to-end suite proves that the keys reach the
    /// terminal through the menu (D138). On a Mac whose screen is locked no
    /// window is key, and the menu's action has nowhere to go by itself; it is
    /// then handed to the terminal, which is where a key window would send it.
    func pressPaste(_ text: String, into job: String, giveUp: Date = Date().addingTimeInterval(10)) {
        guard let live = lives[job], !live.ended else { return }
        guard live.surface.acceptsPaste || Date() >= giveUp else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.pressPaste(text, into: job, giveUp: giveUp) }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard let window = live.surface.view.window else { return }
        bringToFront(window)
        window.makeFirstResponder(live.surface.view)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: "v",
                                           charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) else { return }
        keyRouted = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        if !window.isKeyWindow, keyRouted,
           let item = NSApp.mainMenu?.items.flatMap({ $0.submenu?.items ?? [] }).first(where: { $0.keyEquivalent == "v" }),
           let action = item.action {
            NSApp.sendAction(action, to: live.surface.view, from: item)
        }
    }

    /// Whether the last ⌘V pressed found its menu item.
    private var keyRouted = false

    /// Every live window forward, the Dock icon's click; `false` with none open.
    func bringAllForward() -> Bool {
        guard lives.values.contains(where: { $0.window != nil }) else { return false }
        NSApp.activate(ignoringOtherApps: true)
        for live in lives.values { live.window?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// The headers follow their rows: the lamp changes colour with the session.
    private func startClock() {
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHeaders() }
        }
    }

    private func refreshHeaders() {
        for live in lives.values {
            let header = describe(live.target)
            live.frame.show(header, ended: live.ended)
            if let window = live.window, window.title != header.title { window.title = header.title }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let live = lives.values.first(where: { $0.window === window }) else { return }
        letGo(live.target)
        live.surface.end(waiting: false)
        LiveProcesses.forget(pid: live.surface.pid)
        lives[live.job] = nil
        if lives.isEmpty { clock?.invalidate(); clock = nil }
        updateDockPresence()
    }
}
