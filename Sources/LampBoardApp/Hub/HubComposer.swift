import ClarcChatKit
import LampBoardCore
import SwiftUI

/// The Hub's message box (D154): one draft per session, a question before
/// sending over the person's own draft, and a sent message kept in sight until
/// the transcript has it. Apart from `HubModel`, so typing redraws the box and
/// nothing else (P1).
@MainActor
final class HubComposer: ObservableObject {

    /// A message sent and not yet in the transcript.
    struct Pending: Equatable {
        let session: String
        let text: String
        /// The user messages the transcript held when it went, for the receipt.
        let before: [String]
    }

    enum Outcome: String { case sent, confirm, refused }

    @Published var text = "" { didSet { if confirming, text != oldValue { confirming = false } } }
    @Published private(set) var pending: Pending?
    /// Send was pressed over the person's own draft: the next Send goes.
    @Published private(set) var confirming = false
    @Published private(set) var band: String?

    private var drafts: [String: String] = [:]
    private var session: String?

    /// The box follows the open session: each keeps its own draft.
    func show(session id: String?) {
        guard id != session else { return }
        if let session { drafts[session] = text }
        session = id
        text = id.flatMap { drafts[$0] } ?? ""
        confirming = false
    }

    func ask() { confirming = true }

    func show(band: String?) { if self.band != band { self.band = band } }

    /// The text left the box; it stays in sight until it arrives.
    func sent(_ text: String, session: String, before: [String]) {
        pending = Pending(session: session, text: text, before: before)
        self.text = ""
        confirming = false
    }

    /// Whether the transcript now holds the message: then it goes.
    func check(userTexts: [String], session: String) {
        guard let pending, pending.session == session,
              HubWrite.arrived(pending.text, before: pending.before, now: userTexts) else { return }
        self.pending = nil
    }

    /// The message did not go after all: back in the box, before what was typed since.
    func failed(session: String) {
        guard let pending, pending.session == session else { return }
        self.pending = nil
        let back = text.isEmpty ? pending.text : pending.text + "\n" + text
        if self.session == session { text = back } else { drafts[session] = back }
    }

    /// The user messages of a conversation, as text, for the receipt.
    static func userTexts(_ messages: [ChatMessage]) -> [String] {
        messages.filter { $0.role == .user }.map(\.content)
    }
}

/// The box under the conversation: the band, the message waiting for its
/// receipt, the question over a draft, and Send.
struct HubComposerView: View {
    @ObservedObject var composer: HubComposer
    let submit: () -> Void
    let canWrite: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let band = composer.band {
                Text(band).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                    .accessibilityIdentifier("hub.band")
            }
            if let pending = composer.pending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Sending: \(pending.text)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                .accessibilityIdentifier("hub.pending")
            }
            if composer.confirming {
                Text("Something is typed in the session's own box. Send anyway? Yours goes first; what is typed there stays.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .accessibilityIdentifier("hub.confirm")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(canWrite ? "Message the session…" : "Read only from here", text: $composer.text, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                    .disabled(!canWrite)
                Button(composer.confirming ? "Send anyway" : "Send", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canWrite || composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("hub.send")
            }
        }
        .padding(12)
    }
}
