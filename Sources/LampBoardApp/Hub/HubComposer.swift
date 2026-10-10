import AppKit
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
    /// Whether the session's own box holds a draft, as its mod said.
    @Published private(set) var boxHasDraft = false

    private var drafts: [String: String] = [:]
    private var session: String?

    /// The box follows the open session: each keeps its own draft.
    func show(session id: String?) {
        guard id != session else { return }
        if let session { drafts[session] = text }
        session = id
        text = id.flatMap { drafts[$0] } ?? ""
        confirming = false
        boxHasDraft = false
    }

    func ask() { confirming = true }

    /// A file cited where it was dropped (D157): `@path` at `index` (a
    /// character offset, clamped), with a space either side where words touch.
    func insert(citation path: String, at index: Int?) {
        let token = path.hasPrefix("@") ? path : "@" + path
        let chars = Array(text)
        let at = min(max(index ?? chars.count, 0), chars.count)
        let before = at > 0 && !chars[at - 1].isWhitespace ? " " : ""
        let after = at < chars.count && !chars[at].isWhitespace ? " " : (at == chars.count ? " " : "")
        text = String(chars[..<at]) + before + token + after + String(chars[at...])
    }

    /// A command ran: the box empties, nothing waits for a receipt.
    func ran() {
        text = ""
        confirming = false
    }

    func show(band: String?) { if self.band != band { self.band = band } }

    func heard(draft: Bool) { if boxHasDraft != draft { boxHasDraft = draft } }

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

/// The box under the conversation (the proposal's `.composer`): the message
/// waiting for its receipt, the question over a draft, and the bordered text.
struct HubComposerView: View {
    @ObservedObject var composer: HubComposer
    let submit: () -> Void
    let canWrite: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pending = composer.pending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Sending: \(pending.text)").font(.system(size: 11)).foregroundStyle(HubPalette.muted).lineLimit(2)
                }
                .accessibilityIdentifier("hub.pending")
            }
            if composer.confirming {
                Text("Something is typed in the session's own box. Send again to send anyway: yours goes first, what is typed there stays.")
                    .font(.system(size: 11)).foregroundStyle(HubPalette.amber)
                    .accessibilityIdentifier("hub.confirm")
            }
            HubTextView(composer: composer, editable: canWrite, submit: submit)
                .frame(minHeight: 44, maxHeight: 160)
                .padding(.horizontal, 4).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(HubPalette.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(HubPalette.line, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if composer.text.isEmpty {
                        Text(canWrite ? "Write to the session… drop a file to cite it, / for commands" : "Read only from here")
                            .font(HubPalette.body).foregroundStyle(HubPalette.muted).allowsHitTesting(false)
                            .padding(.leading, 9).padding(.top, 6)
                    }
                }
        }
    }
}

/// The composer's text, as AppKit edits it: a file dropped from the project's
/// tree lands as `@path` where the pointer is, each `@path` drawn as a pill,
/// Return sends and Shift-Return starts a line.
struct HubTextView: NSViewRepresentable {
    @ObservedObject var composer: HubComposer
    let editable: Bool
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let old = scroll.documentView as? NSTextView
        let text = DropTextView(frame: old?.frame ?? .zero)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.font = .systemFont(ofSize: 13)
        text.textColor = NSColor(srgbRed: 0xE4 / 255, green: 0xE8 / 255, blue: 0xEB / 255, alpha: 1)
        text.insertionPointColor = .white
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.delegate = context.coordinator
        text.onDrop = { [weak composer] path, index in composer?.insert(citation: path, at: index) }
        text.setAccessibilityIdentifier("hub.composer")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let text = scroll.documentView as? DropTextView else { return }
        text.isEditable = editable
        if text.string != composer.text {
            let caret = composer.text.utf16.count
            text.string = composer.text
            text.setSelectedRange(NSRange(location: caret, length: 0))
        }
        Self.pills(in: text)
    }

    /// `@path` tokens drawn as pills, nothing else styled.
    static func pills(in text: NSTextView) {
        guard let storage = text.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: whole)
        storage.addAttribute(.foregroundColor, value: NSColor(srgbRed: 0xE4 / 255, green: 0xE8 / 255, blue: 0xEB / 255, alpha: 1), range: whole)
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: whole)
        if let pattern = try? NSRegularExpression(pattern: "(?<![\\w@])@[^\\s@]+") {
            for match in pattern.matches(in: storage.string, range: whole) {
                storage.addAttribute(.backgroundColor, value: NSColor(srgbRed: 0x22 / 255, green: 0x36 / 255, blue: 0x4A / 255, alpha: 1), range: match.range)
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), range: match.range)
            }
        }
        storage.endEditing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HubTextView
        init(_ parent: HubTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            if parent.composer.text != text.string { parent.composer.text = text.string }
            HubTextView.pills(in: text)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            parent.submit()
            return true
        }
    }
}

/// A text view that takes a dropped `@path` (the project's tree drags one)
/// at the character under the pointer, through the composer's own insert.
final class DropTextView: NSTextView {
    var onDrop: ((String, Int?) -> Void)?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dropped = sender.draggingPasteboard.string(forType: .string),
              dropped.hasPrefix("@"), !dropped.contains("\n") else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        let offset = string.utf16.count >= index ? String(string.utf16.prefix(index)).map { $0.count } : nil
        onDrop?(dropped, offset)
        return true
    }
}
