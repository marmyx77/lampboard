import Foundation
import LampBoardCore

/// Recorded hook flows, reduced the way `lampd` will reduce them when it takes
/// the hooks in tee (W5): the payloads read by the Core's decoder, each signal
/// applied by the Core's reducer, the row read as the read endpoint writes it.
///
/// It exists before the tee so that the parity with the Mac is held from now
/// (§6.2, "parity on recordings"): the same flows, played into the real Mac app
/// by its end-to-end suite and replayed here, must leave every session in the
/// same state after every event. Both are compared with one golden file in the
/// repository; a reducer that drifts on either side turns it red.
///
/// A flow is JSON lines `{"at": <seconds>, "entrypoint": "cli", "payload": {…}}`,
/// the shape the fake node's flows are recorded in.
public enum HookReplay {

    public struct Step: Codable, Equatable, Sendable {
        public let event: String
        public let session: String
        public let status: String
        public let activeSubagents: Int

        public init(event: String, session: String, status: String, activeSubagents: Int) {
            self.event = event
            self.session = session
            self.status = status
            self.activeSubagents = activeSubagents
        }
    }

    public struct Event: Sendable {
        public let at: TimeInterval
        public let entrypoint: String?
        public let payload: Data
        public let session: String
        public let name: String
    }

    /// The events of a flow, in the order they are played.
    public static func events(in text: String) throws -> [Event] {
        var out: [Event] = []
        for (number, line) in text.split(separator: "\n").enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let at = (object["at"] as? NSNumber)?.doubleValue,
                  let payload = object["payload"] as? [String: Any],
                  let session = payload["session_id"] as? String,
                  let name = payload["hook_event_name"] as? String else {
                throw LampDError.invalid("line \(number + 1) is not a recorded hook event")
            }
            out.append(Event(at: at, entrypoint: object["entrypoint"] as? String,
                             payload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                             session: session, name: name))
        }
        return out.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    /// Each event's effect on its session, as the read endpoint would show it.
    /// An event the decoder refuses (one Claude Code sends and no hook is
    /// registered for) leaves the state as it was, as it does on the Mac.
    public static func replay(_ events: [Event], workspace: String, start: Date) -> [Step] {
        var state = TrafficLightState()
        return events.map { event in
            let now = start.addingTimeInterval(event.at)
            if let signal = try? HookPayloadDecoder.decode(event.payload, entrypoint: event.entrypoint) {
                state = StateReducer.reduce(state, action: .signal(signal, workspace: Workspace(path: workspace), origin: .editor), now: now)
            }
            let snapshot = state.sessions[event.session].map { SessionsCodec.snapshot(of: $0) }
            return Step(event: event.name, session: event.session, status: snapshot?.status ?? "absent",
                        activeSubagents: snapshot?.activeSubagents ?? 0)
        }
    }
}
