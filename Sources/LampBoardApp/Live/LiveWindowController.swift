import AppKit
import LampBoardCore

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
        let window: NSWindow
        let surface: LiveSurface
        let frame: LiveFrameView
        var ended = false
        init(target: LiveTarget, window: NSWindow, surface: LiveSurface, frame: LiveFrameView) {
            self.target = target; self.window = window; self.surface = surface; self.frame = frame
        }
    }

    private var lives: [String: Live] = [:]
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
        if let live = lives[job] {
            if live.ended { attach(live) }
            bringToFront(live.window)
            return true
        }
        guard let command = command(for: target) else { return false }
        let theme = LiveTheme.named(preferences.liveTheme)
        let surface = makeSurface()
        let frame = LiveFrameView(theme: theme, terminal: surface.view)
        let window = makeWindow(content: frame, target: target)
        let live = Live(target: target, window: window, surface: surface, frame: frame)
        frame.reattach.target = self
        frame.reattach.action = #selector(reattachPressed(_:))
        frame.reattach.identifier = NSUserInterfaceItemIdentifier(job)
        surface.apply(theme: theme, fontSize: preferences.liveFontSize)
        lives[job] = live
        start(live, command)
        bringToFront(window)
        window.makeFirstResponder(surface.view)
        startClock()
        return true
    }

    /// Starts a new background session in `directory`, then opens it. The start
    /// runs off the main thread: `claude --bg` may first start the supervisor.
    func start(directory: String, name: String?, failed: @escaping (String) -> Void) {
        guard let claude = LampMasterRunner.executable(),
              let command = LiveLaunch.start(directory: directory, name: name, claude: claude,
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
                if let job, self?.open(job: job) == true { return }
                failed(LiveLaunch.startFailure(fromOutput: output).message)
            }
        }
    }

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
                                       "running": live.surface.isRunning && !live.ended, "title": live.window.title]
            if includingText { view["text"] = live.surface.screenText(lines: 40) }
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
            guard let view = live.window.contentView else { continue }
            view.wantsLayer = true
            let scale = live.window.backingScaleFactor
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
        let theme = LiveTheme.named(preferences.liveTheme)
        for live in lives.values {
            live.frame.apply(theme: theme)
            live.surface.apply(theme: theme, fontSize: preferences.liveFontSize)
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
            self.refreshHeaders()
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
        replacement.surface.apply(theme: LiveTheme.named(preferences.liveTheme), fontSize: preferences.liveFontSize)
        lives[live.job] = replacement
        start(replacement, command)
        live.window.makeFirstResponder(replacement.surface.view)
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
            if let last = lives.values.map(\.window).last { window.cascadeTopLeft(from: NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24)) }
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
            if live.window.title != header.title { live.window.title = header.title }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let live = lives.values.first(where: { $0.window === window }) else { return }
        live.surface.end(waiting: false)
        LiveProcesses.forget(pid: live.surface.pid)
        lives[live.job] = nil
        if lives.isEmpty { clock?.invalidate(); clock = nil }
    }
}
