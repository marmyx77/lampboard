import AppKit
import LampBoardCore
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
        let window: NSWindow
        let surface: LiveSurface
        let frame: LiveFrameView
        var ended = false
        /// The chat, once it has been shown (D147).
        var chat: LiveChatModel?
        init(target: LiveTarget, window: NSWindow, surface: LiveSurface, frame: LiveFrameView) {
            self.target = target; self.window = window; self.surface = surface; self.frame = frame
        }
    }

    private var lives: [String: Live] = [:]
    /// Where a session's transcript is, for its chat (D147); set by the app.
    var chatSource: (LiveTarget) -> LiveChatModel.Source? = { _ in nil }
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
        if let live = lives[job] {
            if live.ended { attach(live) }
            bringToFront(live.window)
            return true
        }
        guard let command = command(for: target) else { return false }
        let theme = preferences.liveAppearance.theme
        let surface = makeSurface()
        let frame = LiveFrameView(theme: theme, terminal: surface.view)
        let window = makeWindow(content: frame, target: target)
        let live = Live(target: target, window: window, surface: surface, frame: frame)
        frame.reattach.target = self
        frame.reattach.action = #selector(reattachPressed(_:))
        frame.reattach.identifier = NSUserInterfaceItemIdentifier(job)
        frame.makeChat = { [weak self] in self?.makeChat(for: job) }
        // A citation goes to the session's prompt, and the keys back to it.
        frame.files.cite = { [weak self] text in
            guard let live = self?.lives[job], !live.ended else { NSSound.beep(); return }
            live.surface.paste(text)
            live.window.makeFirstResponder(live.surface.view)
        }
        surface.apply(preferences.liveAppearance)
        lives[job] = live
        updateDockPresence()
        start(live, command)
        if preferences.liveOpensChat { frame.show(chat: true) }
        bringToFront(window)
        if !frame.showsChat { window.makeFirstResponder(surface.view) }
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

    /// Ends the editor's process of a conversation and takes it up as a
    /// background session here (D135). Off the main thread: the process gets
    /// ten seconds to save what it holds before the new one starts.
    func move(_ process: SessionProcess, name: String, failed: @escaping (String) -> Void) {
        // One move per conversation at a time: a second would start a second writer.
        guard !moving.contains(process.sessionId) else { return }
        guard let claude = LampMasterRunner.executable(),
              let command = LiveLaunch.start(directory: process.cwd, name: name, resume: process.sessionId, claude: claude,
                                             environment: ProcessInfo.processInfo.environment,
                                             home: AppConfig.homeDirectory.path)
        else { failed(LiveLaunch.StartFailure.other("Claude Code was not found on this Mac.").message); return }
        var environment: [String: String?] = [:]
        for key in ProcessInfo.processInfo.environment.keys where command.environment[key] == nil { environment[key] = .some(nil) }
        for (key, value) in command.environment { environment[key] = value }
        moving.insert(process.sessionId)
        let finish: @MainActor (String?) -> Void = { [weak self] message in
            self?.moving.remove(process.sessionId)
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
            let result = try? Command.run(command.executable, command.arguments, deadline: 60,
                                          directory: URL(fileURLWithPath: process.cwd), environment: environment)
            let output = result?.output ?? ""
            let job = result?.succeeded == true ? LiveLaunch.jobId(fromBackgroundOutput: output) : nil
            let outcome: MoveHere.Outcome
            if let job { outcome = .started(job: job) }
            else if let result, !result.succeeded, !output.isEmpty { outcome = .refused(LiveLaunch.startFailure(fromOutput: output).message) }
            else { outcome = .unknown }
            DispatchQueue.main.async {
                if case .started(let job) = outcome, self?.open(job: job) == true { finish(nil); return }
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
                                       "running": live.surface.isRunning && !live.ended, "title": live.window.title]
            if includingText {
                view["text"] = live.surface.screenText(lines: 40)
                if let folder = describe(live.target).folder { view["folder"] = folder }
                if !live.frame.files.isHidden, let showing = live.frame.files.showingPath { view["showing"] = showing }
                view["chatShown"] = live.frame.showsChat
                if let chat = live.chat {
                    view["chatMessages"] = chat.messages.count
                    view["chatAsks"] = chat.asksInTerminal
                    view["chatCanSend"] = chat.canSend
                    view["chatText"] = String(chat.messages.map(\.content).joined(separator: " | ").suffix(400))
                }
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
            guard let view = live.window.contentView else { continue }
            view.wantsLayer = true
            let scale = live.window.backingScaleFactor
            // With the chat shown, the chat is what the picture must show.
            let terminal = live.frame.showsChat ? (live.frame.chatView ?? live.surface.view) : live.surface.view
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
            // The files' text is clipped from a layer render as the terminal's was.
            let files = live.frame.files
            if !files.isHidden, let side = files.bitmapImageRepForCachingDisplay(in: files.bounds) {
                files.cacheDisplay(in: files.bounds, to: side)
                if let image = side.cgImage { context.draw(image, in: files.convert(files.bounds, to: view)) }
            }
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-\(live.job).png"))
        }
    }

    /// Every window with its files open, and `relative` in their preview: for
    /// the pictures and the end-to-end suite (D136).
    func showFiles(opening relative: String?) {
        refreshHeaders()
        for live in lives.values {
            live.frame.openFiles()
            if let relative, let folder = describe(live.target).folder {
                live.frame.files.open((folder as NSString).appendingPathComponent(relative))
            }
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
        // The chats' followers go too: an ssh left reading would outlive LampBoard.
        for live in lives.values { live.chat?.stop() }
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
        replacement.chat = live.chat
        live.chat?.restartIfLost()
        // The old one has exited: ending it closes its pty and signals nothing.
        live.surface.onExit = nil
        live.surface.end(waiting: false)
        // The frame keeps its place; only the terminal inside the card changes.
        live.frame.replaceTerminal(live.surface.view, with: replacement.surface.view)
        replacement.surface.apply(preferences.liveAppearance)
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

    /// A live window is somewhere to come back to (D138): while one is open,
    /// LampBoard has a Dock icon, a place in ⌘Tab and a Window menu listing
    /// them; with the last one closed it is a menu-bar app again.
    /// Another window that needs the Dock and the menu while it is open: the Hub.
    var keepsDock: () -> Bool = { false }

    func refreshDockPresence() { updateDockPresence() }

    private func updateDockPresence() {
        let policy: NSApplication.ActivationPolicy = lives.isEmpty && !keepsDock() ? .accessory : .regular
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
        bringToFront(live.window)
        live.window.makeFirstResponder(live.surface.view)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: live.window.windowNumber, context: nil, characters: "v",
                                           charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) else { return }
        keyRouted = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        if !live.window.isKeyWindow, keyRouted,
           let item = NSApp.mainMenu?.items.flatMap({ $0.submenu?.items ?? [] }).first(where: { $0.keyEquivalent == "v" }),
           let action = item.action {
            NSApp.sendAction(action, to: live.surface.view, from: item)
        }
    }

    /// Whether the last ⌘V pressed found its menu item.
    private var keyRouted = false

    /// A message sent from the chat, as its Send would (D147), for the
    /// end-to-end suite.
    /// Through the same gate as the chat's Send: refused while Claude asks or is gone.
    func sendFromChat(_ text: String, into job: String) {
        guard let live = lives[job], !live.ended, live.chat?.canSend == true else { return }
        _ = live.surface.submit(text)
    }

    /// Every live window forward, the Dock icon's click; `false` with none open.
    func bringAllForward() -> Bool {
        guard !lives.isEmpty else { return false }
        NSApp.activate(ignoringOtherApps: true)
        for live in lives.values { live.window.makeKeyAndOrderFront(nil) }
        return true
    }

    /// The headers follow their rows: the lamp changes colour with the session.
    private func startClock() {
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHeaders() }
        }
    }

    /// The chat for `job`'s window: its transcript followed, its messages sent
    /// through the terminal.
    private func makeChat(for job: String) -> NSView? {
        guard let live = lives[job] else { return nil }
        guard let source = chatSource(live.target) else {
            return NSHostingView(rootView: Text("LampBoard cannot find this session's conversation to show it as a chat.")
                .foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        LiveChatTheme.apply(preferences.liveAppearance, chatFont: LiveChatTheme.vsCodeChatFont())
        let model = LiveChatModel(source: source)
        model.start()
        live.chat = model
        live.frame.onSwitch = { [weak self, weak model] chat in
            guard let live = self?.lives[job] else { return }
            // The keys go to what is shown: the chat's box, or the terminal.
            if chat { model?.requestFocus() } else { live.window.makeFirstResponder(live.surface.view) }
        }
        return NSHostingView(rootView: LiveChatView(
            model: model,
            send: { [weak self] text in
                guard let live = self?.lives[job], !live.ended, live.chat?.canSend == true else { return false }
                return live.surface.submit(text)
            },
            showTerminal: { [weak self] in self?.lives[job]?.frame.show(chat: false) }))
    }

    private func refreshHeaders() {
        for live in lives.values {
            let header = describe(live.target)
            // A message may go only while Claude is there and asks nothing: at a
            // dialog its Enter would answer the dialog, and with Claude gone it
            // would run in the shell left behind (the row goes with Claude).
            let status = header.status
            live.chat?.update(asking: status == .awaiting,
                              sendable: status != nil && status != .awaiting && !live.ended && live.surface.isRunning)
            live.frame.show(header, ended: live.ended)
            if live.window.title != header.title { live.window.title = header.title }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let live = lives.values.first(where: { $0.window === window }) else { return }
        live.surface.end(waiting: false)
        live.chat?.stop()
        LiveProcesses.forget(pid: live.surface.pid)
        lives[live.job] = nil
        if lives.isEmpty { clock?.invalidate(); clock = nil }
        updateDockPresence()
    }
}
