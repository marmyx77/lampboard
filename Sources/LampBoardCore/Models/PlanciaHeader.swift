import Foundation

/// The Plancia's header (UX §5): under the session's name, on one line, what a
/// person wants to know before acting on it — which machine, which surface and
/// agent, which model, how full its context is, what it has cost. What is not
/// known is left out rather than guessed.
public enum PlanciaHeader {

    public static func facts(_ session: SessionState) -> String {
        var parts = [session.workspace.host ?? "this Mac", "\(session.origin)", session.harness.displayName]
        if let reading = session.context {
            parts.append(model(reading.model))
            parts.append(reading.window.map { "\(tokens(reading.tokens)) of \(tokens($0))" } ?? tokens(reading.tokens))
        }
        if let cost = session.costUSD, cost > 0 { parts.append(String(format: "$%.2f", cost)) }
        return parts.map { RowActivity.flat($0) }.joined(separator: " · ")
    }

    /// `claude-opus-5-5` reads as "Opus 5.5"; a date or a `[1m]` after it is
    /// dropped. Any other model as it came.
    public static func model(_ id: String) -> String {
        let bare = id.split(separator: "[").first.map(String.init) ?? id
        let parts = bare.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude" else { return id }
        let numbers = parts.dropFirst(2).prefix { $0.count <= 2 && Int($0) != nil }
        guard !numbers.isEmpty else { return id }
        return parts[1].capitalized + " " + numbers.joined(separator: ".")
    }

    /// 142,300 → "142k"; 1,250,000 → "1.3M".
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(Int((Double(count) / 1_000).rounded()))k" }
        return "\(count)"
    }
}
