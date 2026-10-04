import AppKit
import LampBoardCore
import SwiftUI

/// The tutorial's tour in the trial panel: where it is, and what to do next.
///
/// Kept by step id in a domain of its own, not the trial's: every trial starts
/// on a fresh temporary home, and somebody who stopped at step 3 resumes there
/// next time. Nothing in it leaves the Mac.
@MainActor
final class TourController: ObservableObject {

    static let domain = "com.lampboard.app.tour"
    private static let key = "progress"

    let steps = Tour.steps()
    @Published private(set) var progress: TourProgress
    private let defaults = UserDefaults(suiteName: TourController.domain)

    init() {
        let stored = (defaults?.data(forKey: Self.key))
            .flatMap { try? JSONDecoder().decode(TourProgress.self, from: $0) } ?? TourProgress()
        progress = stored.resumed(in: steps)
        save()
    }

    var current: Tour.Step? { progress.current(in: steps) }

    /// Something happened in the panel. A gesture that is not the one the
    /// current step waits for changes nothing.
    func handle(_ event: Tour.Event) {
        let next = progress.after(event, in: steps)
        guard next != progress else { return }
        progress = next
        save()
    }

    func skip() { progress = progress.skipped(); save() }
    func resume() { progress = progress.resumed(in: steps); save() }

    private func save() {
        defaults?.set(try? JSONEncoder().encode(progress), forKey: Self.key)
    }
}

/// The band at the top of the trial panel. Always there in a trial, so a
/// screenshot taken there can never pass for somebody's real sessions.
struct TourBand: View {
    @ObservedObject var tour: TourController
    let compact: Bool

    /// Lines of the issue strip's height, as `PanelMetrics.height` counts them.
    static let lines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(compact ? "TRIAL" : "TRIAL · invented sessions")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(StatusPalette.lampMasterTint)
                if !compact {
                    Spacer(minLength: 4)
                    controls
                }
            }
            if !compact {
                Text(sentence)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, compact ? 4 : Layout.panelPadding + 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Layout.issueStripHeight * CGFloat(Self.lines))
        .background(StatusPalette.lampMasterTint.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tutorial trial with invented sessions. " + sentence)
    }

    @ViewBuilder
    private var controls: some View {
        switch tour.progress.status {
        case .inProgress:
            if let position = tour.progress.position(in: tour.steps) {
                Text("\(position.index) of \(position.count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(StatusPalette.timeColor)
            }
            Button("Skip") { tour.skip() }.buttonStyle(.plain).font(.system(size: 9, weight: .semibold))
        case .skipped, .notStarted:
            Button("Resume") { tour.resume() }.buttonStyle(.plain).font(.system(size: 9, weight: .semibold))
        case .finished:
            Button("Quit trial") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 9, weight: .semibold))
        }
    }

    private var sentence: String {
        switch tour.progress.status {
        case .inProgress: return tour.current?.text ?? ""
        case .finished: return "Done. Your own sessions are in your own panel: quit this trial."
        case .skipped, .notStarted: return "Tour paused. These sessions are invented; nothing here is yours."
        }
    }
}
