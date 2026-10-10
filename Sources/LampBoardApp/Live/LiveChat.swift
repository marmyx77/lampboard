import AppKit
import ClarcChatKit
import LampBoardCore
import SwiftUI

/// The live view's chat (D147): a session's conversation read from its
/// transcript and drawn the way Clarc draws it, beside the terminal and never
/// instead of it. Reading only: what is written goes to the session through the
/// terminal, the one writer it has, and only while Claude is there to take it.
@MainActor
final class LiveChatModel: ObservableObject {

    /// Where the transcript is: a file here, or a path on another machine.
    enum Source: Equatable {
        case local(URL)
        case remote(host: String, path: String)
    }

    @Published private(set) var messages: [ChatMessage] = []
    /// Said above the conversation when it cannot be read.
    @Published private(set) var problem: String?
    /// The session waits for an answer only its own dialog can take.
    @Published private(set) var asksInTerminal = false
    /// Whether a message may be sent: Claude runs there and waits on no dialog.
    @Published private(set) var canSend = false
    /// Bumped when the chat is shown, for its box to take the keys.
    @Published private(set) var focusRequest = 0

    private let source: Source
    private var buffer = TranscriptLineBuffer()
    private var offset: UInt64 = 0
    private var timer: Timer?
    private var follower: Process?
    private var stopped = false
    private var retries = 0
    private var rebuildPending = false

    init(source: Source) { self.source = source }

    func start() {
        stopped = false
        switch source {
        case .local(let url): startLocal(url)
        case .remote(let host, let path): startRemote(host: host, path: path)
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        endFollower()
    }

    /// The terminal was attached again: a remote follower lost with the
    /// connection starts again too.
    func restartIfLost() {
        guard case .remote(let host, let path) = source, follower == nil, !stopped else { return }
        retries = 0
        startRemote(host: host, path: path)
    }

    /// What the window knows of the session, once a second: published only
    /// when it changes, so the bubbles are not drawn again for nothing.
    func update(asking: Bool, sendable: Bool) {
        if asksInTerminal != asking { asksInTerminal = asking }
        if canSend != sendable { canSend = sendable }
    }

    func requestFocus() { focusRequest += 1 }

    // MARK: - This Mac: the file, read where it was left

    private func startLocal(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
        // A long session's file runs to megabytes: its last four are plenty
        // for its last lines, the first of them cut and dropped.
        let start = size > 4_000_000 ? size - 4_000_000 : 0
        offset = start
        readLocal(url, skippingFirstLine: start > 0)
        // Always: a transcript not written yet (a new session's) appears later.
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readLocal(url, skippingFirstLine: false) }
        }
    }

    private func readLocal(_ url: URL, skippingFirstLine: Bool) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 else {
            if messages.isEmpty, problem == nil { problem = "Waiting for the conversation's first message." }
            return
        }
        // Shorter than where reading stopped: replaced or cut. Read it again whole.
        if size < offset {
            offset = 0
            buffer = TranscriptLineBuffer()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard var data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        if skippingFirstLine, let newline = data.firstIndex(of: 0x0A) { data.removeSubrange(data.startIndex...newline) }
        if buffer.append(data) { scheduleRebuild() }
    }

    // MARK: - Another machine: its last lines over ssh, then each new one

    private func startRemote(host: String, path: String) {
        guard RemoteHostList.isUsable(host), !host.hasPrefix("-") else { problem = "That machine's name cannot be given to ssh."; return }
        // `-n 800` sends the last lines again: a new connection starts clean.
        buffer = TranscriptLineBuffer()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHHardening.options + ["-T", "-o", "ServerAliveInterval=30", "-o", "ConnectTimeout=10",
                                                    "--", host, LiveChatSource.remoteFollow(path: path)]
        let output = Pipe()
        // Held open: when it closes, the remote end stops following.
        process.standardInput = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            // In order, on the main queue; one rebuild for a burst.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.buffer.append(data) { self.scheduleRebuild() }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.followerEnded(host: host, path: path) } }
        }
        do {
            try process.run()
            follower = process
        } catch {
            problem = "LampBoard could not reach \(host) to read the conversation."
        }
    }

    /// The connection ended: said, and tried again, less often each time.
    private func followerEnded(host: String, path: String) {
        follower = nil
        guard !stopped else { return }
        problem = "The connection to \(host) dropped: reading the conversation again…"
        retries += 1
        let delay = min(60, 2 * pow(2, Double(min(retries, 5))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.follower == nil else { return }
                self.startRemote(host: host, path: path)
            }
        }
    }

    private func endFollower() {
        guard let follower else { return }
        self.follower = nil
        follower.terminationHandler = nil
        (follower.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
        if follower.isRunning { follower.terminate() }
    }

    // MARK: - Lines to messages, Clarc's way

    /// One rebuild for a burst of lines: a transcript's last 800 arrive in
    /// dozens of pieces, and each rebuild decodes them all.
    private func scheduleRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildPending = false
                self.messages = CLILineToBlocksMapper.map(lines: CLILineDecoder.decode(self.buffer.lines))
                self.retries = 0
                self.problem = nil
            }
        }
    }
}

/// The chat itself: the conversation, and a box that sends to the session.
struct LiveChatView: View {
    @ObservedObject var model: LiveChatModel
    /// Sends a message to the session, as if typed and Enter pressed; `false`
    /// when it could not be.
    let send: (String) -> Bool
    let showTerminal: () -> Void

    @State private var draft = ""
    @State private var windowState = WindowState()
    @State private var bridge = ChatBridge()
    @FocusState private var boxFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.secondary).padding(.top, 10)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.messages) { MessageBubble(message: $0) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                // The last message, not their count: past 800 lines the count
                // stays flat while the conversation goes on.
                .onChange(of: model.messages.last?.id) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            if model.asksInTerminal {
                HStack {
                    Text("The session is asking something its own dialog answers.")
                    Spacer()
                    Button("Answer in the terminal", action: showTerminal)
                }
                .font(.callout)
                .padding(10)
                .background(.orange.opacity(0.15))
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(model.canSend ? "Message the session…" : "Sending waits until Claude is there and asks nothing",
                          text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .focused($boxFocused)
                    .onSubmit(submit)
                Button("Send", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .background(ClaudeTheme.background)
        .foregroundStyle(ClaudeTheme.textPrimary)
        .environment(windowState)
        .environment(bridge)
        // A link in a reply opens only on the web: a transcript's text can carry
        // any scheme, and its label need not match its target.
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
        .onChange(of: model.focusRequest) { _, _ in boxFocused = true }
        .onAppear { boxFocused = true }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.canSend else { return }
        // Kept when it could not go: a message is never lost to a closed terminal.
        if send(text) { draft = "" }
    }
}
