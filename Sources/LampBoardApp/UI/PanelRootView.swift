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
    /// "I'm away" (A1), and the line said on return clicked away.
    var toggleAway: () -> Void = {}
    var dismissAwayNote: () -> Void = {}
    /// Opens or closes the «Resting» line at the foot of the column (U2).
    var toggleResting: () -> Void = {}
    /// «New session…» (D133).
    var newSession: () -> Void = {}
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
    /// Away, said from this menu or by a locked screen (A1).
    var isAway = false
    /// How many projects are hidden, for the ⋯'s «Show 3 hidden projects».
    var hiddenCount = 0
}

/// Root of the SwiftUI hierarchy hosted inside the floating panel.
struct PanelRootView: View {
    @ObservedObject var store: StateStore
    let flags: PanelFlags
    let options: ColumnOptions
    let mutedWorkspaces: Set<String>
    let calmWorkspaces: Set<String>
    let expandedRows: Set<String>
    /// The session in the foreground (G1), or none.
    var focusedSession: String? = nil
    let actions: PanelActions
    let rowActions: RowActions
    /// The account's allowance, when the switch is on. Its own observable rather
    /// than a field on the store: it is the one figure here that belongs to the
    /// account instead of to a session, and it comes from a different place.
    @ObservedObject var allowance: AllowanceMonitor
    /// LampMaster's line draws itself only while it is switched on.
    let lampMaster: LampMasterService?
    let openLampMaster: () -> Void
    /// What LampMaster's cards do, for its Plancia.
    var lampMasterActions: LampMasterActions? = nil
    /// What the Plancia header's buttons do.
    var planciaActions: PlanciaActions? = nil
    /// The three sample rows, while they are in the panel (U4).
    @ObservedObject var samples: SampleStage
    /// The tip at the top, when one is due (U5).
    @ObservedObject var tips: TipStage
    /// What waits: the asks under their rows, the bar's count; nil in the narrow panel.
    var queue: WaitingQueueModel? = nil
    /// The bar at the top; nil in the narrow panel.
    var bar: CommandBarModel? = nil
    /// The Plancia, while a session is open in it (D79), on the side toward the
    /// middle of the screen.
    var plancia: PlanciaModel? = nil
    var planciaLeading = false
    var activity: ActivityRecorder? = nil
    var openInEditor: (String) -> Void = { _ in }
    var closePlancia: () -> Void = {}

    @Environment(\.columnFillsWidth) private var inHub

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let plancia, planciaLeading { planciaColumn(plancia) }
            column
            if let plancia, !planciaLeading { planciaColumn(plancia) }
        }
        .modifier(PanelChrome(inHub: inHub))
    }

    private func planciaColumn(_ model: PlanciaModel) -> some View {
        HStack(spacing: 0) {
            if !planciaLeading { Divider() }
            PlanciaView(model: model, store: store, activity: activity, openInEditor: openInEditor, close: closePlancia,
                        lampMaster: lampMaster, lampMasterActions: lampMasterActions, actions: planciaActions, queue: queue)
            if planciaLeading { Divider() }
        }
    }

    private var column: some View {
        VStack(spacing: 0) {
            // In the Hub the rows stand alone (D150): no tip, no strips, no footer.
            if let tip = tips.current, !inHub {
                TipBand(tip: tip, compact: flags.compact, dismiss: tips.dismiss)
            }
            if samples.isOn || TrialStage.mode != nil {
                SampleBand(demo: TrialStage.mode != nil, compact: flags.compact, remove: samples.stop)
            }
            // The bar carries what the queue and LampMaster's row used to say above
            // the rows: how many wait, and the reviewer's star (U2).
            if let bar {
                CommandBarView(model: bar, queue: queue, onlyWaiting: flags.onlyWaiting,
                               toggleOnlyWaiting: actions.toggleOnlyWaiting,
                               lampMaster: lampMaster, openLampMaster: openLampMaster)
            }
            // The narrow panel has no bar: LampMaster keeps its line there.
            if let lampMaster, flags.compact {
                LampMasterStrip(service: lampMaster, compact: true, open: openLampMaster)
            }
            TrafficLightColumn(
                store: store,
                compact: flags.compact,
                options: options,
                notificationsEnabled: flags.notificationsEnabled,
                mutedWorkspaces: mutedWorkspaces,
                calmWorkspaces: calmWorkspaces,
                focusedSession: focusedSession,
                actions: rowActions,
                expandedRows: expandedRows,
                onRevealHidden: actions.showHiddenAgain,
                conflicts: activity.map { FileConflicts.find($0.logs, live: Set(store.state.sessions.keys), now: Date()) } ?? [:],
                samples: samples,
                connected: flags.hooksInstalled,
                connect: actions.installHooks,
                queue: queue,
                toggleResting: actions.toggleResting
            )
            if !inHub {
                AllowanceStrip(reports: allowance.reports, quiet: allowance.quiet, compact: flags.compact,
                               forecasts: allowance.forecasts)
            }
            issueStrip
            if !inHub { footer }
        }
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
        if store.issue == nil, let note = store.awayNote {
            // What happened while the person was away (A1), in the issue's place
            // and height, until it is clicked away.
            Button(action: actions.dismissAwayNote) {
                HStack(spacing: 5) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(StatusPalette.lampMasterTint)
                    if !flags.compact {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.primary.opacity(0.65))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, flags.compact ? 4 : Layout.panelPadding + 6)
                .frame(maxWidth: .infinity, alignment: flags.compact ? .center : .leading)
                .frame(height: Layout.issueStripHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tooltip(note)
            .accessibilityLabel(note)
        } else if let issue = store.issue {
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

    /// The panel's ⋯ (U3): seven entries, built in Core (`Menus.panel`).
    /// Everything that used to follow them lives in Settings.
    private var menu: some View {
        MenuEntriesView(
            entries: Menus.panel(
                PanelMenuState(onlyWaiting: flags.onlyWaiting, mutedUntil: flags.mutedUntil,
                               isAway: flags.isAway, hiddenCount: flags.hiddenCount),
                time: Self.time
            ),
            perform: perform
        )
    }

    private func perform(_ command: MenuCommand) {
        switch command {
        case .openConversations: actions.openExtended()
        case .newSession: actions.newSession()
        case .legend: actions.openLegend()
        case .capabilities: CapabilitiesWindowController.shared.show()
        case .onlyWaiting: actions.toggleOnlyWaiting()
        case .muteForAnHour: actions.muteForAnHour()
        case .resumeAlerts: actions.clearMute()
        case .away: actions.toggleAway()
        case .showHidden: actions.showHiddenAgain()
        case .settings: actions.openSettings()
        case .quit: actions.quit()
        default: break
        }
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
/// The panel's own frame: the dark material, rounded, with its hairline. In the
/// Hub the sidebar is the material, full height, and the rows sit in it (D150).
private struct PanelChrome: ViewModifier {
    let inHub: Bool

    func body(content: Content) -> some View {
        if inHub {
            content
        } else {
            content
                .background(PanelBackground().overlay(StatusPalette.panelScrim))
                .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
    }
}

struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The line at the top while invented rows are in the panel: «Samples», and the
/// way to take them away (U4). In the demo used for screenshots it says so
/// instead, so a picture taken there never passes for somebody's real sessions.
private struct SampleBand: View {
    let demo: Bool
    let compact: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(compact ? "S" : demo ? "DEMO · invented sessions" : "Samples · three invented rows")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(StatusPalette.lampMasterTint)
                .lineLimit(1)
            if !compact {
                Spacer(minLength: 4)
                if !demo {
                    Button("Remove", action: remove)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StatusPalette.fixTint)
                        .accessibilityLabel("Remove the sample rows")
                }
            }
        }
        .padding(.horizontal, compact ? 4 : Layout.panelPadding + 6)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .frame(height: Layout.issueStripHeight)
        .contentShape(Rectangle())
        .onTapGesture { if compact && !demo { remove() } }
        .tooltip(demo ? "The rows here are invented, played from a script for pictures and tests."
                      : "Three invented rows that show the panel at work. Click Remove to take them away.")
    }
}

/// One tip, the first time what it speaks of happens (U5): two lines at the top
/// of the panel, and *Got it*. In the narrow panel a light bulb, its sentence a
/// hover away, a click putting it away.
struct TipBand: View {
    static let lines = 2
    let tip: Tips.Tip
    let compact: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StatusPalette.lampMasterTint)
            if !compact {
                Text(tip.text)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Got it", action: dismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StatusPalette.fixTint)
            }
        }
        .padding(.horizontal, compact ? 4 : Layout.panelPadding + 6)
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .frame(height: Layout.issueStripHeight * CGFloat(compact ? 1 : Self.lines), alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { if compact { dismiss() } }
        .tooltip(tip.text)
        .accessibilityElement(children: .combine)
    }
}

