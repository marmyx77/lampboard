import AppKit
import LampBoardCore
import SwiftUI

/// Visual appearance of the five states.
///
/// The choice of colors is not decorative. With a dozen sessions open, the column
/// spends most of its time entirely red: if red shouted as loudly as green, the
/// eye would stop distinguishing the state that actually matters. So rest is
/// muted and brightness grows with urgency.
enum StatusPalette {

    /// The appearance the panel and its card are drawn in, whatever the Mac is set to.
    ///
    /// WHY IT IS NOT LEFT TO THE SYSTEM
    /// Half of this surface is written for a dark ground and cannot follow a
    /// light one: the hover wash and the block edges are `Color.white` at low
    /// opacity, the material is `.hudWindow`, and every lamp hue above was chosen
    /// and measured against that. The other half — the names, the timestamps, the
    /// badges — is `Color.primary`, which does follow.
    ///
    /// On a Mac in light mode the two halves disagreed, and the result was
    /// reported in the only words it deserved: black text on grey, unreadable.
    ///
    /// Measured on the two photographs of the same panel, one before this line
    /// and one after: a project's name against its own background was **4.5:1**
    /// following the system and **6.8:1** held dark. The ratio understates what
    /// the eye gets — it takes the darkest pixel in a stem against the commonest
    /// pixel of the background, where most of a twelve-point glyph over a
    /// translucent surface sits much nearer the middle, and the background itself
    /// is whatever window happens to be behind the panel. The direction is the
    /// point: the second number is the one everything here was tuned against.
    ///
    /// There were two ways out. Tune a second palette for a light ground — new
    /// hues, a glow that survives on white, every overlay inverted — which is a
    /// design pass and not a switch, and would double what has to be kept true.
    /// Or say what the panel already is: a dark instrument, like the dashboard of
    /// a car, which is dark whatever the weather outside. That is what it has
    /// been drawn, measured and photographed as since the first day.
    ///
    /// It applies to the panel and its tooltip, and to nothing else. Settings and
    /// the legend are ordinary windows full of ordinary controls, and they follow
    /// the Mac like every other window a person has open.
    static let appearance = NSAppearance(named: .darkAqua)

    static func color(for status: SessionStatus) -> Color {
        switch status {
        // `failed` shares the hue of `idle`: nothing is coming from either of them.
        // What tells them apart is brightness and glow, the same grammar the
        // palette already uses for urgency — so the difference reads in compact
        // mode too, where there is no text.
        case .idle, .failed:
            return Color(red: 0.85, green: 0.24, blue: 0.24)
        case .working:
            return Color(red: 0.98, green: 0.75, blue: 0.16)
        case .awaiting:
            return Color(red: 1.00, green: 0.45, blue: 0.10)
        case .ready:
            return Color(red: 0.20, green: 0.85, blue: 0.42)
        // The one cool hue in a warm palette, on purpose: everything else is a
        // shade of "attention", and this is the state that asks for none.
        case .waiting:
            return Color(red: 0.42, green: 0.66, blue: 0.98)
        }
    }

    /// Opacity at rest: the idle state stays readable without catching the eye.
    static func opacity(for status: SessionStatus) -> Double {
        status == .idle ? 0.45 : 1.0
    }

    /// Glow radius. Only the states asking for attention have one.
    static func glowRadius(for status: SessionStatus) -> CGFloat {
        switch status {
        case .idle: return 0
        case .working, .waiting: return 3
        case .awaiting, .ready, .failed: return 6
        }
    }

    /// Color of the timestamp in the row.
    ///
    /// `Color.primary` follows the system theme — white on dark, black on light —
    /// and the opacity is tuned to sit below the workspace name while staying
    /// readable. The weaker semantic hues (`.secondary`, `.tertiary`) over an
    /// `NSVisualEffectView` get attenuated a second time by vibrancy, and the
    /// result disappears.
    static let timeColor = Color.primary.opacity(0.62)

    /// The strip that says a click could not do its job.
    ///
    /// It borrows the `awaiting` hue rather than inventing one: the column already
    /// teaches that this shade means "this needs you", and a strip in a colour the
    /// panel has never used would read as belonging to some other application.
    static let warningTint = Color(red: 1.00, green: 0.45, blue: 0.10)

    /// The little capsule that offers to fix the fault the strip names.
    ///
    /// The strip's own hue is the `awaiting` amber, which says *this needs you*.
    /// The capsule is the `failed` red, which the column has already taught means
    /// *this is stopped*, and that is the truer word for a click that cannot
    /// raise a window. Two shades the panel already owns, doing the two jobs they
    /// already do: the sentence reports, the button acts.
    ///
    /// A word set in plain text next to a sentence reads as part of the sentence.
    /// An outline around it is the smallest mark that says "this is a control",
    /// and at ten points it is the only one that fits.
    static let fixTint = Color(red: 0.85, green: 0.24, blue: 0.24)

    /// The ring around a row that has something listening behind it.
    ///
    /// Exactly the `waiting` blue, and that is the whole idea: the column has
    /// already taught that this shade means "something is registered and nothing
    /// needs you". As a fill it says the row *is* that; as a ring it says the row
    /// *also* is that, without taking the colour that carries the news.
    static let listeningTint = Color(red: 0.42, green: 0.66, blue: 0.98)

    /// Text of the badge carrying the session or subagent count.
    static let badgeForeground = Color.primary.opacity(0.80)

    /// Badge background: enough to separate it from the name, not so much that it
    /// competes with the dot, which is the only thing meant to catch the eye.
    static let badgeBackground = Color.primary.opacity(0.14)

    /// The vertical rule marking a pinned project.
    /// Laid over the window material, and this is the one colour here that is
    /// about the **desktop** rather than about a session.
    ///
    /// The panel is translucent, so without this its brightness is decided by
    /// whatever wallpaper is behind it. On a light one the whole thing came up
    /// pale, the block that holds a project's conversations was a lighter wash on
    /// an already light ground, and the two were almost the same: reported as
    /// "you can hardly tell the blocks are anything different, and the smaller
    /// dots end up looking like a rendering fault".
    ///
    /// A fixed floor puts the contrast budget back in our hands. Six lit colours
    /// on a dark ground is what a board of lamps looks like; six on a pale one is
    /// a spreadsheet.
    static let panelScrim = Color.black.opacity(0.41)

    /// The well a project's conversations sit in: **darker** than the panel, not
    /// lighter.
    ///
    /// Lighter was the first attempt and it is the wrong direction on a surface
    /// that is already bright: it adds haze rather than shape. Darker reads as
    /// recessed, which is what a container is, and it gives the coloured dots
    /// inside it more contrast rather than less.
    static let blockWell = Color.black.opacity(0.39)

    /// One hairline along the well's edge, so it keeps its shape on a bright
    /// wallpaper where the fill alone would wash out.
    static let blockEdge = Color.white.opacity(0.08)

    static let pinMarker = Color.primary.opacity(0.35)

    /// Which agent a line belongs to, on the grip and nowhere else.
    ///
    /// The five status colours are spoken for, and a tint that could be mistaken
    /// for a state would be worse than no tint. These two are chosen against
    /// that: terracotta is Claude's own, kept at 80 percent because it is the one
    /// that has to stay clear of `failed` red, and teal is Codex's.
    ///
    /// The cell they live in is the last one on the line, two hundred points from
    /// the dot, and every line has one. That distance is what makes a second
    /// colour affordable here and nowhere else on the row.
    ///
    /// One honest cost: teal is the tested tint nearest `ready` green, so a Codex
    /// grip on a line that is genuinely green puts two greens on it. The distance
    /// between the cells is the mitigation, and if a day of use says otherwise
    /// this is the one line that has to change.
    static func agentTint(for harness: Harness) -> Color {
        switch harness {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.80)
        case .codex: return Color(red: 0.18, green: 0.83, blue: 0.75)
        }
    }

    /// The grip on a project's own row, which belongs to no agent.
    static let neutralGrip = Color.primary.opacity(0.46)
}

/// Interface measurements, gathered here so magic numbers don't scatter through
/// the views.
enum Layout {
    /// The traffic light itself.
    ///
    /// Eleven for most of this project's life, and two points too small: on a
    /// 27-inch display at arm's length the difference between the dimmed red of
    /// a resting session and the full red of a dead turn is a difference in
    /// brightness across eleven points, which is exactly the kind of judgement
    /// a glance from across the desk cannot make.
    static let dotSize: CGFloat = 13

    /// The dot on a conversation inside an opened block, in the **narrow** panel.
    ///
    /// Only there. In the wide panel a conversation's dot is the same size as its
    /// project's, and that is a correction: a smaller one read as an
    /// inconsistency rather than as a hierarchy, and it weakened the one mark the
    /// whole app exists for. The hierarchy is carried by the well the lines sit
    /// in, by a lighter type and by a dimmer name, none of which is the light.
    ///
    /// At 35 points there is no well and no name, so size is all there is.
    static let compactSubDotSize: CGFloat = 9
    /// Thickness of the listening ring, drawn inside the dot. Enough to see from
    /// across a room, and it still leaves a core large enough to read the colour
    /// underneath — which is the whole point of a ring rather than a colour.
    static let listeningRing: CGFloat = 2.5
    /// The context ring, beside the light and slightly larger than it.
    ///
    /// Larger, and that is deliberate rather than an oversight: it has to hold a
    /// letter inside a stroked circle, and the letter was illegible at eleven
    /// points — reported from use, in exactly those words. The light keeps the
    /// eye anyway, because it is the only saturated thing on the row and this one
    /// is grey.
    static let contextRingSize: CGFloat = 16
    /// Three points of sixteen. Thick, and deliberately so: the first version
    /// was two points of eleven, and on screen the consumed arc did not separate
    /// from the track behind it — the ring read as a letter in a circle, which is
    /// half of what it is. Three points leaves ten of clear middle, which is
    /// still more than a capital needs.
    static let contextRingWidth: CGFloat = 3
    /// The letter in the middle of that ring.
    static let contextRingLetter: CGFloat = 8.5
    /// The gap between the light and its context ring.
    ///
    /// Tighter than the row's own spacing, because they are one thing said twice
    /// — this session's state, and this session's room — and because the seven
    /// points the row uses everywhere else are seven points off the name.
    static let dotToRing: CGFloat = 4
    static let rowHeight: CGFloat = 24
    static let rowSpacing: CGFloat = 2
    static let panelPadding: CGFloat = 8
    static let cornerRadius: CGFloat = 12

    /// Width of the conversation list in the extended window.
    ///
    /// Wider than the panel's 240 because it carries a second line — what was
    /// last said — and a preview truncated to three words is not a preview.
    static let sidebarWidth: CGFloat = 260

    static let compactWidth: CGFloat = 35
    /// Wide enough for a readable workspace name plus the timestamp.
    /// Long but common names ("internal-admin-console") fit almost entirely:
    /// below this threshold, middle truncation makes them indistinguishable.
    static let expandedWidth: CGFloat = 240

    static func width(compact: Bool) -> CGFloat {
        compact ? compactWidth : expandedWidth
    }

    /// The strip under the rows: the width control on the left, under the lights,
    /// and the legend and the menu on the right, under the drag handles.
    ///
    /// **It is one more row of the column, and that is the whole point.** At 19
    /// points with 9-point glyphs it was a hint that controls existed; at 22 it
    /// was controls in a band of its own height, which read — accurately — as a
    /// strip bolted underneath. It is now a hairline and a band exactly as tall
    /// as a row, so the footer belongs to the same rhythm as everything above it
    /// instead of interrupting it.
    static let footerHeight: CGFloat = footerRule + rowHeight
    /// The band the glyphs live in: one row, so their centres sit on the same
    /// pitch the lights do.
    static let footerBand: CGFloat = rowHeight
    /// The hairline that says where the rows end. Without it the glyphs float on
    /// the same surface as the column and read as debris; with it they are a
    /// region. One point, at a tenth of the primary colour: any stronger and it
    /// becomes a border, which this panel does not have anywhere else.
    static let footerRule: CGFloat = 1
    /// The glyphs down there. Same size as a row's name, and the same colour:
    /// they are part of the panel's text, not a toolbar bolted under it.
    ///
    /// All three are `.circle` variants, and that is not decoration. A gear, a
    /// question mark in a circle and a pair of loose diagonal arrows have the same
    /// point size and nothing else in common: the arrows are two thin marks with
    /// no bounding shape and an ink that hangs to one corner, so beside two round
    /// outlines they read as smaller, lower and unrelated. Enclosed, all three are
    /// 15 × 15, one silhouette, one weight — which is the difference between three
    /// glyphs and a set of controls.
    static let footerGlyph: CGFloat = 12

    /// The line that appears only when a click could not raise a window.
    ///
    /// The panel grows by it rather than the strip overlapping a row: a widget
    /// that covers its own content to complain is worse than one that is a few
    /// points taller for as long as the fault lasts.
    static let issueStripHeight: CGFloat = 17

    /// A line inside an opened block: one conversation.
    ///
    /// Shorter than a row and not by much. It has to read as subordinate without
    /// becoming a different kind of object, and the dot inside it is 9 points
    /// against the row's 13, so two points of height is the whole difference the
    /// eye needs.
    static let subRowHeight: CGFloat = 22

    /// The block's own inset: the fill and hairline that hold a project and its
    /// conversations together.
    static let blockInset: CGFloat = 3

    /// The spine down the left of an opened block, and how far in it sits.
    ///
    /// Inside the row's own padding, so it costs the names nothing. A leading
    /// gutter would have taken 13 points off **every** name in the column, on a
    /// 240 point panel, for a minority of rows.
    static let spineWidth: CGFloat = 1.5
    static let spineInset: CGFloat = 3

    /// How many conversations an opened block shows before a tail line.
    ///
    /// Twelve sub-rows is 264 points of panel for one project, past
    /// `maxVisibleRows`, and a column that scrolls is a column where the row that
    /// needs you can be off screen. Six is what the narrowest surface can hold,
    /// and it is the same cap the summary uses, so the panel and the card cannot
    /// say two different things about one project.
    static let subRowCap = 6

    /// Height needed for `rowCount` rows and `subRowCount` opened conversations,
    /// capped at `maxVisibleRows` worth of lines, plus the footer and, while
    /// there is one, the issue strip.
    ///
    /// Counted in **lines** rather than rows since a project can be opened: the
    /// window has to grow by exactly what it drew, or the last conversation is
    /// cut off by the footer.
    /// The panel's own measurements, handed to the arithmetic in Core.
    static var sizes: PanelMetrics.Sizes {
        PanelMetrics.Sizes(
            row: rowHeight, subRow: subRowHeight, spacing: rowSpacing,
            blockInset: blockInset, tail: tailHeight, padding: panelPadding,
            footer: footerHeight, issueStrip: issueStripHeight
        )
    }

    /// The "and N more" line under a project showing more than it can.
    static let tailHeight: CGFloat = 16

    /// How tall one row draws. Delegates, because arithmetic that decides whether
    /// a row can be seen is not drawing and belongs where a test can call it.
    static func blockHeight(
        rowCount: Int, shownConversations: Int, hasTail: Bool, compact: Bool
    ) -> CGFloat {
        PanelMetrics.blockHeight(
            rowCount: rowCount, shownConversations: shownConversations,
            hasTail: hasTail, compact: compact, sizes: sizes
        )
    }

    static func height(ofBlocks blocks: [CGFloat], extras: Int, showsIssue: Bool) -> CGFloat {
        PanelMetrics.height(ofBlocks: blocks, extras: extras, showsIssue: showsIssue, sizes: sizes)
    }

}
