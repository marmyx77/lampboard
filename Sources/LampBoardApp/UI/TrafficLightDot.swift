import LampBoardCore
import SwiftUI

/// A single traffic light.
///
/// Blinking is reserved for the state that blocks the work: if green blinked too,
/// with twelve sessions open the screen would turn into a Christmas tree and
/// neither signal would be noticed any more.
struct TrafficLightDot: View {
    let status: SessionStatus

    /// `true` when the dot stays lit steadily instead of blinking.
    ///
    /// What gets silenced is the **movement**, not the signal: the amber color
    /// stays. Blinking in peripheral vision is impossible to ignore, and that is
    /// exactly what is wanted — until you're working next to a session that has
    /// been waiting for half an hour and you don't intend to answer yet.
    var calm: Bool = false

    /// `true` when something is still listening behind this row — a monitor
    /// registered and not yet triggered.
    ///
    /// Drawn as a ring rather than as a colour of its own, because it is not a
    /// state: the turn ended green, or red, or it is working again, and *besides
    /// that* an ear is open. Giving it a colour would have meant choosing which
    /// of the two facts to hide, and the one it used to hide was the answer
    /// sitting unread underneath.
    var listening: Bool = false

    /// Solid, dashed when stuck, hollow without the mod (R4).
    var style: LampStyle = .solid

    /// Two views, not one view with two behaviours.
    ///
    /// The first version toggled a `@State` flag on the same circle and relied on
    /// SwiftUI to cancel the `repeatForever` animation when the flag went back.
    /// It did not: the render that ends the amber changes the *status*, and the
    /// opacity returns to rest in that same render, unanimated; by the time the
    /// flag flips there is no opacity change left to animate, so the running
    /// animation is never replaced and keeps pulsing under every colour that
    /// follows — yellow, green, and finally the red of an idle row.
    ///
    /// Here the blinking dot is a different view. When the status stops blinking
    /// the view is removed, and a removed view takes its animations with it.
    var body: some View {
        if status.shouldBlink && !calm {
            glowing(circle.blinking(to: 0.25)).transition(.identity)
        } else {
            glowing(circle).transition(.identity)
        }
    }

    private var color: Color { StatusPalette.color(for: status) }

    private var circle: some View {
        disc
            .frame(width: Layout.dotSize, height: Layout.dotSize)
            // Drawn *inside* the dot's own circle with `strokeBorder`, so a ring
            // costs no layout: eleven points is eleven points whether or not
            // anything is listening, and a column whose rows changed width when
            // a monitor appeared would be worse than the problem.
            .overlay {
                if listening {
                    Circle().strokeBorder(
                        StatusPalette.listeningTint, lineWidth: Layout.listeningRing
                    )
                }
            }
            .opacity(StatusPalette.opacity(for: status))
    }

    /// The lamp's body: the shape says what the colour cannot (UX §11: never
    /// colour alone). A ring for a session no mod speaks for; a dashed ring in the
    /// working yellow for one stuck on a tool.
    @ViewBuilder
    private var disc: some View {
        switch style {
        case .solid:
            Circle().fill(color)
        case .stalled:
            Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 2.4, dash: [2.6, 1.8]))
        case .hollow:
            Circle().strokeBorder(color, lineWidth: 2)
        }
    }

    private func glowing<Dot: View>(_ dot: Dot) -> some View {
        dot.shadow(color: color.opacity(0.8), radius: StatusPalette.glowRadius(for: status))
    }
}
