import LampBoardCore
import SwiftUI

/// Actions offered by the panel's context menu.
struct PanelActions {
    /// Opens the extended window — the conversation list plus a conversation.
    let openExtended: () -> Void
    /// Opens the Settings window: what does not fit in this menu.
    let openSettings: () -> Void
    /// Opens the legend: what the six colours and the two rings mean, with a
    /// live count of each beside it.
    let openLegend: () -> Void
    let toggleCompact: () -> Void
    /// Moves the panel between its own window and the menu bar.
    let toggleHome: () -> Void
    /// Shows or hides the lamp in the menu bar, leaving the panel where it is.
    let toggleMenuBarIcon: () -> Void
    let toggleSessionTab: () -> Void
    let toggleOnlyWaiting: () -> Void
    let toggleNotifications: () -> Void
    let toggleMessageSending: () -> Void
    let togglePresence: () -> Void
    /// Shows the account's allowance at the foot of the column. The one switch
    /// here that makes the app talk to a service instead of to this Mac.
    let toggleUsage: () -> Void
    let toggleTerminalSessions: () -> Void
    let muteForAnHour: () -> Void
    let clearMute: () -> Void
    let toggleLaunchAtLogin: () -> Void
    let installHooks: () -> Void
    let uninstallHooks: () -> Void
    let requestAccessibility: () -> Void
    /// The strip's button: explain the permission, then open the pane that grants it.
    let fixIssue: (PanelIssue) -> Void
    let showHiddenAgain: () -> Void
    let clearSessions: () -> Void
    /// Asks GitHub whether there is a newer release, and offers to install it.
    let checkForUpdates: () -> Void
    let quit: () -> Void
}

/// The menu's checkmarks, gathered together so twelve of them don't travel separately.
struct PanelFlags {
    let compact: Bool
    /// Where the panel lives right now.
    let home: PanelHome
    /// Whether the lamp is in the menu bar.
    let showsMenuBarIcon: Bool
    let opensSessionTab: Bool
    let onlyWaiting: Bool
    let notificationsEnabled: Bool
    let messageSendingEnabled: Bool
    let presenceEnabled: Bool
    let usageEnabled: Bool
    let showsTerminalSessions: Bool
    let mutedUntil: Date?
    let hasHidden: Bool
    let hooksInstalled: Bool

    /// The agents on this machine with no hooks registered, by name.
    ///
    /// One menu line for two agents, and it says which one is missing rather
    /// than sending you to look: a second entry in an already long menu costs
    /// more than it explains.
    let hooksMissingFrom: [String]
    let launchesAtLogin: Bool
    let canLaunchAtLogin: Bool
}

/// Root of the SwiftUI hierarchy hosted inside the floating panel.
struct PanelRootView: View {
    @ObservedObject var store: StateStore
    let flags: PanelFlags
    let options: ColumnOptions
    let mutedWorkspaces: Set<String>
    let calmWorkspaces: Set<String>
    let expandedRows: Set<String>
    let actions: PanelActions
    let rowActions: RowActions
    /// The account's allowance, when the switch is on. Its own observable rather
    /// than a field on the store: it is the one figure here that belongs to the
    /// account instead of to a session, and it comes from a different place.
    @ObservedObject var allowance: AllowanceMonitor


    var body: some View {
        VStack(spacing: 0) {
            TrafficLightColumn(
                store: store,
                compact: flags.compact,
                options: options,
                notificationsEnabled: flags.notificationsEnabled,
                mutedWorkspaces: mutedWorkspaces,
                calmWorkspaces: calmWorkspaces,
                actions: rowActions,
                expandedRows: expandedRows,
                onRevealHidden: actions.showHiddenAgain
            )
            AllowanceStrip(reports: allowance.reports, quiet: allowance.quiet, compact: flags.compact)
            issueStrip
            footer
        }
        .background(PanelBackground().overlay(StatusPalette.panelScrim))
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        // The panel menu stays reachable from the margins: over the rows it is
        // shadowed by the row menu, which is more specific and therefore takes the
        // right precedence. The global entries are not duplicated into every row
        // because a fifteen-item menu cannot be read.
        .contextMenu { menu }
    }

    /// The one line that says a click went nowhere, where the eye already is.
    ///
    /// This used to live only at the bottom of the context menu, and the result
    /// was measured on a fresh install: the click activated the editor without
    /// choosing a window, which reads as a half-working app rather than a missing
    /// permission, and the sentence explaining it was three levels away. Nobody
    /// opens a context menu to find out why something they just did worked oddly.
    ///
    /// It appears only for faults the person can fix from here, and it disappears
    /// by itself the moment the permission arrives.
    @ViewBuilder
    private var issueStrip: some View {
        if let issue = store.issue {
            Button { actions.fixIssue(issue) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(StatusPalette.warningTint)

                    // In compact mode the panel is thirty-five points wide: the
                    // triangle is the whole message, and the strip is the button.
                    // A word squeezed in there would be truncated to two letters,
                    // which says less than the glyph alone.
                    if !flags.compact {
                        Text(issue.summary)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.primary.opacity(0.65))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        // A capsule, not a word. Set as plain text it read as the
                        // end of the sentence beside it, and the one thing the
                        // strip has to do is look pressable.
                        Text(issue.actionTitle)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StatusPalette.fixTint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        StatusPalette.fixTint.opacity(0.85), lineWidth: 1
                                    )
                            )
                    }
                }
                .padding(.horizontal, flags.compact ? 4 : Layout.panelPadding + 6)
                .frame(maxWidth: .infinity, alignment: flags.compact ? .center : .leading)
                .frame(height: Layout.issueStripHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tooltip(issue.summary + ". Click to fix.")
        }
    }

    /// The strip under the rows: legend, width, menu.
    ///
    /// The gear came first, and for a reason worth keeping: a menu that exists
    /// only behind a right-click on an empty edge is a menu nobody finds —
    /// reported by use, after a week of not finding it. The same argument brought
    /// the other two here. Switching to the strip was a menu entry, and switching
    /// back meant opening a menu inside a panel thirty-five points wide.
    private var footer: some View {
        VStack(spacing: 0) {
            // Where the rows end. Inset to the column's own padding, so it lines
            // up with the content and stops short of the rounded corners.
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: Layout.footerRule)
                .padding(.horizontal, flags.compact ? 6 : Layout.panelPadding)

            Group {
                if flags.compact {
                    // Thirty-five points wide: there is no left and no right down
                    // there, only a middle. The legend stays out — two glyphs is
                    // what the strip can hold without them touching.
                    HStack(spacing: 3) {
                        sizeButton
                        menuButton
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 3) {
                        // Under the lights, in their column: it is the control
                        // that decides whether the lights are all there is.
                        sizeButton
                        homeButton
                        Spacer(minLength: 0)
                        legendButton
                        menuButton
                    }
                    // The row's own inset, so the gear lands in the drag handles'
                    // column and the width control in the lights'.
                    .padding(.horizontal, Layout.panelPadding + 6)
                }
            }
            .frame(height: Layout.footerBand)
        }
        .frame(height: Layout.footerHeight)
    }

    private var sizeButton: some View {
        FooterButton(
            symbol: flags.compact
                ? "arrow.up.left.and.arrow.down.right.circle"
                : "arrow.down.right.and.arrow.up.left.circle",
            help: flags.compact
                ? "Widen the panel: names, times, context and the drag handles"
                : "Traffic lights only: a strip thirty-five points wide",
            // The width of a light, so the glyph's centre is the lights' centre.
            width: Layout.dotSize,
            action: actions.toggleCompact
        )
    }

    /// Sends the panel to the menu bar, or brings it back.
    ///
    /// Beside the width control and not beside the gear, because the two are the
    /// same kind of thing: they both change what the panel *is* rather than what
    /// it shows. One decides how wide, the other decides where.
    private var homeButton: some View {
        FooterButton(
            symbol: flags.home == .menuBar
                ? "menubar.arrow.down.rectangle"
                : "menubar.arrow.up.rectangle",
            help: flags.home.moveAwayVerb,
            action: actions.toggleHome
        )
    }

    /// The door to the legend, and it is a question mark because that is the
    /// shape of the question: the column has six colours and two rings, and
    /// nothing else on screen says what they are.
    private var legendButton: some View {
        FooterButton(
            symbol: "questionmark.circle",
            help: "What the lights mean: and how many of each there are right now",
            action: actions.openLegend
        )
    }

    /// Three dots and not a gear, and the reason is half legibility and half
    /// accuracy. A gear inside a circle at twelve points is a shape inside a
    /// shape: rendered and looked at, its teeth merge with the ring and it comes
    /// out a grey blob beside a crisp question mark. And this button does not open
    /// settings — it opens the panel's menu, which holds the view switches, the
    /// hooks, the update check and the quit. `…` is what macOS puts on that
    /// button everywhere else.
    private var menuButton: some View {
        FooterButton(
            symbol: "ellipsis.circle",
            help: "Options and Settings: the same menu as a right-click on the panel's edge",
            action: openMenuUnderPointer
        )
    }

    /// Opens the panel's context menu where the pointer is.
    ///
    /// Not a SwiftUI `Menu`: a pop-up button carries the metrics of a control —
    /// its own height, its own label offset — and however it was framed the
    /// gear came out low and cut. The context menu already exists on the root
    /// view; a synthetic right-click at the pointer is all it takes to open it,
    /// and the gear stays a plain glyph the size of the handles.
    private func openMenuUnderPointer() {
        guard let window = NSApp.windows.first(where: { $0 is FloatingPanel }) else { return }
        let location = window.mouseLocationOutsideOfEventStream
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { return }
            window.sendEvent(event)
        }
    }

    @ViewBuilder
    private var menu: some View {
        // First, and on its own, because it is the only entry that opens something
        // rather than changing how this panel looks. Everything below it is a
        // setting; this is the door.
        Button("Open the conversations…", action: actions.openExtended)
        Button("What the lights mean…", action: actions.openLegend)
        Button("Settings…", action: actions.openSettings)

        Divider()

        Button(check(flags.compact, "Traffic lights only"), action: actions.toggleCompact)
        Button(
            check(flags.home == .menuBar, "Live in the menu bar"),
            action: actions.toggleHome
        )
        Button(
            check(flags.showsMenuBarIcon, "Show a lamp in the menu bar"),
            action: actions.toggleMenuBarIcon
        )
        Button(check(flags.onlyWaiting, "Show only what's waiting"), action: actions.toggleOnlyWaiting)
        Button(check(flags.showsTerminalSessions, "Show terminal sessions"), action: actions.toggleTerminalSessions)
        // The wording says what it costs, not just what it does: VS Code asks for
        // confirmation on every invocation, and for sessions with no Claude panel —
        // the integrated-terminal ones — the extension opens a new tab instead of
        // reusing one.
        Button(
            check(flags.opensSessionTab, "Click also opens the tab (VS Code asks for confirmation)"),
            action: actions.toggleSessionTab
        )

        if flags.hasHidden {
            Button("Bring hidden projects back into the column", action: actions.showHiddenAgain)
        }

        Divider()

        Button(check(flags.notificationsEnabled, "Alert me when a session gets blocked"),
               action: actions.toggleNotifications)

        if flags.notificationsEnabled {
            if let until = flags.mutedUntil {
                Button("Resume alerts (muted until \(Self.time(until)))",
                       action: actions.clearMute)
            } else {
                Button("Mute alerts for one hour", action: actions.muteForAnHour)
            }
        }

        Button(check(flags.presenceEnabled, "Suppress phone push notifications while I'm at the Mac"),
               action: actions.togglePresence)

        Button(check(flags.usageEnabled, "Show how much of your allowance is left…"),
               action: actions.toggleUsage)

        Divider()

        if flags.hooksInstalled {
            Button(
                check(flags.messageSendingEnabled, "Let the panel answer your sessions…"),
                action: actions.toggleMessageSending
            )

            Button("Remove the hooks", action: actions.uninstallHooks)
        } else {
            Button(
                flags.hooksMissingFrom.isEmpty
                    ? "Install the hooks…"
                    : "Install the hooks (\(flags.hooksMissingFrom.joined(separator: " and ")))…",
                action: actions.installHooks
            )
        }

        if flags.canLaunchAtLogin {
            Button(check(flags.launchesAtLogin, "Launch at login"), action: actions.toggleLaunchAtLogin)
        }

        if !VSCodeFocuser.hasAccessibilityPermission {
            Button("Grant the Accessibility permission…", action: actions.requestAccessibility)
        }

        Button("Clear the list", action: actions.clearSessions)

        // Never automatic, and never silent. macOS grants Accessibility to a
        // signing identity, so a replacement signed with ours inherits the run
        // of the machine without asking anybody: an app with that permission
        // asks before it replaces itself.
        Button("Check for updates…", action: actions.checkForUpdates)

        if let error = store.lastError {
            Divider()
            Text(error)
        }

        Divider()

        Button("Quit lampboard", action: actions.quit)
    }

    /// Switch entries are distinguished by a checkmark.
    /// SwiftUI offers no `Toggle` inside `contextMenu` that looks right here.
    private func check(_ on: Bool, _ title: String) -> String {
        on ? "✓ \(title)" : title
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// One glyph in the footer.
///
/// It carries the timestamp's colour rather than a fainter one of its own. The
/// first version was nine points at 0.32 opacity, which read as a watermark:
/// reported from use, in five words: too small, and really hard to see.
/// These are controls, and the panel's own text is the right weight for them.
private struct FooterButton: View {
    let symbol: String
    let help: String
    /// The glyph's own width by default, so two of them sitting side by side are
    /// separated by the spacing and nothing else. The width control passes the
    /// width of a light instead, so it centres in the lights' column.
    var width: CGFloat = 15
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Layout.footerGlyph, weight: .regular))
                .foregroundStyle(hovering ? Color.primary.opacity(0.95) : StatusPalette.timeColor)
                // The pill is wider than the layout box and overflows it evenly,
                // so the glyph keeps its column while the highlight gets room to
                // be a target. Same shape and same white as a row's own hover:
                // the footer borrows the column's language instead of inventing
                // one for three glyphs.
                .frame(width: width + 8, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.12 : 0))
                )
                .frame(width: width, height: Layout.footerBand)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tooltip(help)
        .onHover { hovering = $0 }
    }
}

/// Translucent panel background.
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
