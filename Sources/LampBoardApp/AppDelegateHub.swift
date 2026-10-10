import Foundation
import LampBoardCore

/// The Hub's wiring to the server's test routes and the other machines'
/// conversations for ⌘K (M7), apart from the delegate's start.
extension AppDelegate {

    /// The Hub's routes on the server: what it shows, opening it, Send, the
    /// files column, a reply as it arrives, and the remote index probe.
    func wireHub(_ server: SignalServer) {
        server.onHubReport = { [weak self] in Self.onMain(timeout: 2) { self?.hub?.report() } }
        server.onHubOpen = { [weak self] id, mode in
            Self.onMain(timeout: 2) {
                self?.hub.map { hub in
                    if let mode = mode.flatMap(HubWrite.Mode.init(rawValue:)) { hub.model.mode = mode }
                    hub.show(session: id)
                    return true
                }
            } ?? false
        }
        server.onHubCompose = { [weak self] text, confirm in
            Self.onMain(timeout: 2) { () -> String? in
                guard let model = self?.hub?.model else { return nil }
                // As the person would: type it, Send; Send again to answer the question.
                if model.composer.text != text { model.composer.text = text }
                var outcome = model.submit()
                if outcome == .confirm, confirm { outcome = model.submit() }
                return outcome.rawValue
            } ?? nil
        }
        server.onRemoteIndex = { [searchIndex] host, query in
            // One small pass: the newest few transcripts are enough to prove the way,
            // and a test index holds as little of a real machine as it can.
            await AppDelegate.indexRemote(host: host, into: searchIndex, budgetFiles: 5, budgetBytes: 4 << 20)
            let hits = searchIndex.search(query, limit: 20)
            return ["hits": hits.map { ["session": $0.sessionId, "host": $0.host ?? "this Mac"] }]
        }
        server.onModStream = { [weak self] session, turn, text, done in
            DispatchQueue.main.async { self?.hub?.model.heard(stream: text, turn: turn, done: done, session: session) }
        }
        server.onHubFiles = { [weak self] body in Self.onMain(timeout: 2) { self?.hub?.applyTest(body) } ?? false }
    }

    /// The other machines' conversations for ⌘K (M7): every two minutes, each
    /// machine's transcripts listed through the panel's ssh and only their new
    /// bytes read, a budget a pass, the newest first.
    func startRemoteIndexing() {
        let index = searchIndex
        remoteIndexTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                let hosts = await MainActor.run { self?.preferences.remoteHosts ?? [] }
                if Preferences().searchIndexed {
                    for host in hosts { await Self.indexRemote(host: host, into: index) }
                }
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
    }

    nonisolated static func indexRemote(host: String, into index: SearchIndex,
                                        budgetFiles: Int = 40, budgetBytes: Int = 8 << 20) async {
        guard let listing = await ProjectSource.ssh(host, RemoteTranscripts.list()) else { return }
        var files = 0, bytes = 0, messages = 0
        for file in RemoteTranscripts.parse(listing) where files < budgetFiles && bytes < budgetBytes {
            guard let start = index.nextOffset(for: file),
                  let script = RemoteTranscripts.read(path: file.path, from: start, limit: 2 << 20),
                  let data = await ProjectSource.sshData(host, script), !data.isEmpty else { continue }
            files += 1; bytes += data.count
            messages += index.ingest(host: host, file: file, from: start, chunk: data) ?? 0
        }
        if files > 0 { Diagnostics.log("index: \(files) transcripts of \(host), \(messages) messages") }
    }

}
