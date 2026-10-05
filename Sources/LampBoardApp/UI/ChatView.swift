import LampBoardCore
import SwiftUI

/// One conversation: the right-hand column of the extended window.
///
/// It knows nothing about the list beside it — it is handed a `ChatSession` and
/// draws it — which is what let the surrounding shape change from a window per
/// conversation to a single window with two columns without touching this file.
///
/// The composer at the bottom does **not** go through the VS Code extension —
/// that road is closed (N7). It leaves the message in a mailbox on disk, and a
/// listener registered as a second `Stop` hook carries it into the session at the
/// end of its next turn. See [D15](docs/04-decisions.md).
///
/// The consequence is visible and must stay visible: sending is not instant. If
/// Claude is working, the message waits for the turn to end.
struct ChatView: View {

    @ObservedObject var session: ChatSession

    /// Raises the VS Code window holding this session.
    let openInEditor: () -> Void

    @State private var draft = ""
    /// LampMaster's proposal arrives into an empty composer only: what the
    /// person was typing is theirs.
    @FocusState private var composerFocused: Bool

    /// Dictation. `nil` below macOS 26, which is what keeps the button off the
    /// screen on systems where it could not work.
    @StateObject private var dictation = DictationBox()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 260)
        // Switching conversation rebuilds this view from scratch — the shell keys
        // it on the session id — and closing the window destroys it. Either way the
        // microphone has to go with it: an open input device outliving the thing
        // that opened it is the failure the user cannot undo from inside the app.
        .onDisappear {
            guard #available(macOS 26.0, *), let service = dictation.service else { return }
            Task { await service.stop() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(StatusPalette.color(for: session.status))
                .frame(width: 9, height: 9)
                .opacity(StatusPalette.opacity(for: session.status))

            VStack(alignment: .leading, spacing: 1) {
                Text(session.conversation.title ?? session.workspace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(session.workspace.name)
                    .font(.system(size: 10))
                    .foregroundStyle(StatusPalette.timeColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if session.unread > 0 {
                Text("\(session.unread) new")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(StatusPalette.badgeBackground))
                    .foregroundStyle(StatusPalette.badgeForeground)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if !session.hasTranscript {
            filler("No transcript for this session yet.\nIt appears as soon as Claude Code signals something.")
        } else if session.conversation.entries.isEmpty {
            filler("Nothing said here yet.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // Said, rather than left to be inferred from a conversation
                        // that begins mid-sentence: the window holds a bounded tail,
                        // and a reader who cannot see the boundary cannot tell a
                        // trimmed history from a short one.
                        if session.conversation.omittedEntries > 0 {
                            centred(
                                "\(session.conversation.omittedEntries) earlier messages not shown",
                                italic: true
                            )
                        }
                        ForEach(session.conversation.entries) { entry in
                            row(for: entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                // Following the tail is the whole point of an open window: a chat
                // that has to be scrolled by hand to see the answer that just
                // arrived is a log file with rounded corners.
                .onChange(of: session.conversation.entries.count) {
                    guard let last = session.conversation.entries.last else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    guard let last = session.conversation.entries.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func filler(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(StatusPalette.timeColor)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(for entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .human:
            HStack {
                Spacer(minLength: 40)
                bubble(entry.text, background: Color.accentColor.opacity(0.22), markdown: false)
            }
        case .assistant:
            HStack {
                bubble(entry.text, background: StatusPalette.badgeBackground, markdown: true)
                Spacer(minLength: 40)
            }
        case .activity:
            centred(entry.text, italic: true)
        case .note:
            centred(entry.text, italic: false)
        }
    }

    /// - Parameter markdown: `false` for the user's own messages. They typed plain
    ///   text, so rendering their asterisks as bold would put emphasis in their
    ///   mouth that they did not write — and would eat the characters.
    @ViewBuilder
    private func bubble(_ text: String, background: Color, markdown: Bool) -> some View {
        Group {
            if markdown {
                MarkdownView(text: text)
            } else {
                Text(text)
                    .font(.system(size: 12))
                    // Selectable because the reason to keep this window open is
                    // often to copy a command out of it.
                    .textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
    }

    private func centred(_ text: String, italic: Bool) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(
                    italic
                        ? .system(size: 10).italic()
                        : .system(size: 10)
                )
                .foregroundStyle(StatusPalette.timeColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Footer

    /// The composer.
    ///
    /// Delivery is not instantaneous and the interface must not pretend it is: a
    /// message written while Claude is mid-turn waits on disk until the turn ends,
    /// which can be minutes. That is why sending puts the text into `pending` and
    /// shows it, instead of clearing the box and leaving you to wonder.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let pending = session.pending {
                notice(
                    session.listening
                        ? "waiting for the session to pick it up: \(pending)"
                        : "queued: this conversation is asleep, and it will go the "
                            + "moment anything happens there. ↗ opens it in VS Code.",
                    icon: session.listening ? "clock" : "moon.zzz",
                    tint: session.listening ? StatusPalette.timeColor : .orange
                )
            } else if !session.canSend {
                notice(
                    "reading only: turn on \"Let the panel answer your sessions\" "
                        + "in the panel menu",
                    icon: "lock",
                    tint: StatusPalette.timeColor
                )
            } else if !session.listening {
                notice(
                    "this conversation is asleep: a message will wait for it, not vanish",
                    icon: "moon.zzz",
                    tint: StatusPalette.timeColor
                )
            }
            if let error = session.sendError {
                notice(error, icon: "exclamationmark.triangle", tint: .orange)
            }
            if let explanation = dictation.explanation {
                notice(explanation, icon: "mic.slash", tint: StatusPalette.timeColor)
            }

            HStack(spacing: 8) {
                if session.canSend, #available(macOS 26.0, *), let service = dictation.service {
                    DictationButton(service: service) { heard in
                        // What was heard is appended, not substituted: you may
                        // have typed half the message before reaching for the
                        // microphone, and eating that would be unforgivable.
                        draft = draft.trimmed.isEmpty
                            ? heard
                            : draft.trimmed + " " + heard
                        composerFocused = true
                    }
                }

                TextField(
                    session.canSend ? "Message…" : "Reading only",
                    text: $draft, axis: .vertical
                )
                .disabled(!session.canSend)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(.system(size: 12))
                    .focused($composerFocused)
                    .onSubmit(submit)
                    .onReceive(session.$proposed.compactMap { $0 }) { proposal in
                        // Taken once, after the delivery: cleared inside it, the
                        // value would be stored over the nil and come back on the
                        // next mount (a review finding).
                        DispatchQueue.main.async { if session.proposed == proposal { session.proposed = nil } }
                        // What the person was typing stays theirs, and keeps the focus where it was.
                        guard draft.trimmed.isEmpty else { return }
                        draft = proposal
                        composerFocused = true
                    }

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmed.isEmpty || !session.canSend)
                .help("Send: it arrives at the end of the session's current turn")

                Button(action: openInEditor) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Open this session in VS Code")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func notice(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(2)
        }
        .foregroundStyle(tint)
    }

    /// Clears the box only when the message was actually written.
    ///
    /// A composer that empties on a refused send loses what you typed, and the
    /// refusals here are the recoverable kind — no window open, message too long —
    /// where the text is exactly what you want back.
    private func submit() {
        guard !draft.trimmed.isEmpty else { return }
        if session.send(draft) {
            draft = ""
        }
        composerFocused = true
    }
}
