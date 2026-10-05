import AppKit
import Combine
import LampBoardCore

/// The bar at the top of the wide panel wired in (D77): what it searches, what
/// its results do, `⌘K` while the panel holds the keyboard, and the panel
/// remeasured when its results come and go.
///
/// Its own file for the reason `PanelQueue.swift` is one: `PanelController`
/// stays under the eight hundred lines this project refuses.
extension PanelController {

    func wireBar() {
        bar.onOpenSession = { [weak self] id in
            guard let self, let session = self.session(named: id) else { return }
            self.activate(session: session)
        }
        bar.onAction = { [weak self] action in
            switch action {
            case .settings: self?.onOpenSettings?()
            case .gettingStarted: GettingStartedWindowController.shared.show()
            case .tour: TrialLauncher.startFromMenu()
            case .checkForUpdates: self?.checkForUpdates()
            case .legend: self?.onOpenLegend?()
            }
        }
        // The same door a session's MCP call comes through: the same switch,
        // limits and daily ceiling (D62), and the answer drawn for the person.
        bar.onAsk = { [weak self] question in
            guard let lampMaster = self?.lampMaster else { return "LampMaster is not available." }
            let body = (try? JSONSerialization.data(withJSONObject: [
                "tool": LampMasterMCP.Tool.askLampMaster.rawValue, "arguments": ["question": question],
            ])) ?? Data()
            return await lampMaster.tool(body).text
        }
        // Through the Plancia's composer, opened on that session: the same
        // switch, the same box or mailbox, and the message seen as it goes.
        bar.onSend = { [weak self] id, message in
            guard let self, let session = self.session(named: id) else {
                Diagnostics.log("bar: send to \(id) refused, no such session")
                return "That session is gone."
            }
            // On another machine: into its box there, over ssh (B3). No Plancia
            // can show it, so the bar says where it went.
            if let host = session.workspace.host {
                let content = PeerBox.preamble + "\n" + message.trimmingCharacters(in: .whitespacesAndNewlines)
                let sent = await Task.detached { RemotePeerSender.send(content: content, to: session.id, on: host) }.value
                switch sent {
                case .success: return "Sent to \(session.displayName) on \(host): it answers in its own window there."
                case .failure(let error): return "Not sent to \(host): \(error.short)"
                }
            }
            self.openPlancia(sessionId: id)
            guard let thread = self.plancia.thread, thread.sessionId == id else {
                Diagnostics.log("bar: send to \(id) refused, its Plancia did not open")
                return "Its Plancia did not open."
            }
            return thread.send(message) ? nil : (thread.sendError ?? "It did not go.")
        }
        bar.onAskSession = { [weak self] id, question in
            guard let desk = self?.askDesk else { return "Asking is not available." }
            return await desk.ask(sessionId: id, question: question, host: self?.session(named: id)?.workspace.host)
        }
        // What was said (0.7): the index the app keeps, read off the main actor.
        if let index = searchIndex {
            bar.onSearch = { words in
                index.search(words, limit: 5).map { hit in
                    CommandBar.Found(sessionId: hit.sessionId,
                                     title: hit.title ?? hit.cwd.map { ($0 as NSString).lastPathComponent } ?? String(hit.sessionId.prefix(8)),
                                     cwd: hit.cwd, snippet: hit.snippet)
                }
            }
        }
        bar.onConversation = { [weak self] id, foundCwd in
            if let self, let session = self.session(named: id) {
                self.activate(session: session)
                return "Opened."
            }
            // Not open anywhere this panel sees: Claude Code resumes it from its folder.
            // A command a person will paste: an id of a session's shape, and a
            // folder with no line break or control character, quoted for the shell.
            guard ModReport.isSessionId(id) else { return "That conversation has an id this panel will not put in a command." }
            let cwd = foundCwd.flatMap { path in
                path.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } ? path : nil
            }
            let command = (cwd.map { "cd '\($0.replacingOccurrences(of: "'", with: "'\\''"))' && " } ?? "") + "claude --resume \(id)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            return "Closed. To resume it, paste in a terminal (copied): \(command)"
        }
        bar.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.resizeToFit(self.store.state)
        }
        barKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow, !self.isCompact,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "k" else { return event }
            self.bar.focus()
            return nil
        }
        barHotKey = GlobalHotKey { [weak self] in self?.summonBar() }
        barHotKey?.apply(preferences.barShortcut)
        NotificationCenter.default.publisher(for: .barShortcutChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.barHotKey?.apply(self.preferences.barShortcut)
            }
            .store(in: &cancellables)

        // Which sessions can be asked without disturbing comes with their mods.
        askDesk?.$askable
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshBar() }
            .store(in: &cancellables)
        // The switch decides whether a question can be asked, and the bar says so.
        lampMaster?.$snapshot
            .map(\.enabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshBar() }
            .store(in: &cancellables)
        refreshBar()
    }

    /// The shortcut from anywhere: the panel comes up holding the keyboard, its
    /// bar open. Without activating the app — the panel is non-activating, so
    /// the application underneath stays the active one.
    func summonBar() {
        panel.orderFrontRegardless()
        panel.makeKey()
        guard !isCompact else { return }
        bar.focus()
    }

    /// What typing in the bar and `⏎` do, for `--bar-type` on a fake home:
    /// waits up to two minutes for the text to find something it can act on,
    /// then submits once. `{first}` stands for the first row's name, which a
    /// test cannot know in advance.
    func typeIntoBar(_ text: String, attempts: Int = 60) {
        if isCompact, !store.state.sessions.isEmpty { toggleCompact() }
        refreshBar()
        // A row that has answered once: before, there is nothing to ask it about.
        // Its first word: `@name` ends at a space, and the rest would be the message.
        let first = currentRendering.rows.first.flatMap { row -> String? in
            guard row.primary.lastMessage != nil else { return nil }
            return RowActivity.flat(row.displayName).split(separator: " ").first.map(String.init)
        } ?? "{first}"
        bar.focus()
        bar.text = text.replacingOccurrences(of: "{first}", with: first)
        guard bar.shownResults.first?.sessionId != nil || bar.shownResults.first?.action != nil else {
            guard attempts > 0 else { return Diagnostics.log("bar-type: nothing found for it") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.typeIntoBar(text, attempts: attempts - 1) }
            return
        }
        Diagnostics.log("bar-type: \(bar.shownResults[0].title)")
        bar.submit()
        // Pinned, so the Plancia stays to be photographed.
        plancia.pinned = true
    }

    func refreshBar() {
        bar.update(rows: currentRendering.rows, lampMasterEnabled: lampMaster?.snapshot.enabled ?? false,
                   sendingEnabled: preferences.messageSendingEnabled, askable: askDesk?.askable ?? [])
    }
}
