import Foundation
import LampBoardCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Who answers each route of the hooks' port once `lampd` holds it (§2.3 of the
/// mobile plan, the table of routes): every route the Mac's
/// `SignalServer` knows has one owner here, and a route nobody named is refused
/// and logged. A white list for what is passed on, a black one for the rest.
///
/// `Scripts/check-lampd-routes.sh` reads the routes out of `SignalServer.swift`
/// and the mod's hooks and compares them with `lampd routes` (this table, as
/// JSON): a route of the Mac without a row here is red until it gets one (R1).
public enum HookRoutes {

    public enum Owner: String, Codable, Sendable {
        /// Read here and passed on to the Mac: answered at once, sent after.
        case readAndForward
        /// Answered here.
        case serve
        /// Passed on, its answer awaited and handed back, and read on the way:
        /// a question the Mac holds makes the row amber here (M9).
        case forwardAndObserve
        /// Passed on, byte for byte, both ways.
        case forward
        /// Not taken: nobody on the node may ask the Mac this (R2), or it is a
        /// route of the Mac's own clients.
        case refuse
        /// Not found, and said in the log: `lampboard watch` has no Linux build.
        case notFound
    }

    public struct Route: Codable, Equatable, Sendable {
        public let path: String
        public let owner: Owner
        /// How long a forwarded answer is awaited.
        public let wait: TimeInterval
        public let why: String
    }

    /// How long `/check` is held: the Mac's 55 s and a margin (§2.3).
    public static let checkWait: TimeInterval = 65
    /// How long `/question` is held (D86).
    public static let questionWait: TimeInterval = 30
    /// A hook's post, passed on after the answer: as long as the hook itself
    /// waits (`--max-time 2`).
    public static let signalWait: TimeInterval = 2
    /// The rest of what is passed on.
    public static let forwardWait: TimeInterval = 10

    public static let table: [Route] = [
        Route(path: AppConfig.signalPath, owner: .readAndForward, wait: signalWait, why: "colours; the Mac still sees the machine"),
        Route(path: AppConfig.modPath, owner: .readAndForward, wait: signalWait, why: "ring, cost, ⌛, hollow light, D160"),
        Route(path: AppConfig.healthPath, owner: .serve, wait: 0, why: "the mod asks /health before it speaks"),
        Route(path: AppConfig.checkPath, owner: .forwardAndObserve, wait: checkWait, why: "the Mac holds the question (D80); amber here at once (M9)"),
        Route(path: AppConfig.questionPath, owner: .forwardAndObserve, wait: questionWait, why: "as /check (D86)"),
        Route(path: AppConfig.sessionsPath, owner: .forward, wait: forwardWait, why: "/lamps shows what the Mac sees"),
        Route(path: AppConfig.modDecisionsPath, owner: .forward, wait: forwardWait, why: "project rules"),
        Route(path: AppConfig.modGovernorPath, owner: .forward, wait: forwardWait, why: "governor"),
        Route(path: AppConfig.modHoldPath, owner: .forward, wait: forwardWait, why: "hold"),
        Route(path: AppConfig.modRadarPath, owner: .forward, wait: forwardWait, why: "radar"),
        Route(path: AppConfig.bandPath, owner: .forward, wait: forwardWait, why: "band"),
        Route(path: AppConfig.bandOpenPath, owner: .forward, wait: forwardWait, why: "band"),
        Route(path: AppConfig.handoffPath, owner: .forward, wait: forwardWait, why: "handoff"),
        Route(path: AppConfig.lampMasterToolPath, owner: .forward, wait: forwardWait, why: "LampMaster from a session"),
        Route(path: AppConfig.modLookPath, owner: .forward, wait: forwardWait, why: "the look"),
        Route(path: AppConfig.modHelloPath, owner: .forward, wait: forwardWait, why: "signed commands"),
        Route(path: AppConfig.modInboxPath, owner: .forward, wait: forwardWait, why: "signed commands"),
        Route(path: AppConfig.modStreamPath, owner: .forward, wait: 24 * 3600, why: "signed commands, a stream"),
        Route(path: AppConfig.watchPath, owner: .notFound, wait: 0, why: "no lampboard for Linux; no caller on the node"),
        Route(path: AppConfig.nextPath, owner: .refuse, wait: 0, why: "starts or raises on the Mac: not from the node (R2)"),
        Route(path: AppConfig.openPath, owner: .refuse, wait: 0, why: "starts or raises on the Mac: not from the node (R2)"),
        Route(path: AppConfig.newConversationPath, owner: .refuse, wait: 0, why: "starts or raises on the Mac: not from the node (R2)"),
        Route(path: AppConfig.chatPath, owner: .refuse, wait: 0, why: "starts or raises on the Mac: not from the node (R2)"),
        Route(path: AppConfig.lampMasterPath, owner: .refuse, wait: 0, why: "the Mac's clients"),
        Route(path: AppConfig.lampMasterHandsPath, owner: .refuse, wait: 0, why: "the Mac's clients"),
        Route(path: AppConfig.decisionsPath, owner: .refuse, wait: 0, why: "the Mac's clients"),
        Route(path: AppConfig.livePath, owner: .refuse, wait: 0, why: "the Mac's clients"),
        Route(path: AppConfig.hubPath, owner: .refuse, wait: 0, why: "the Mac's clients"),
        Route(path: AppConfig.hubOpenPath, owner: .refuse, wait: 0, why: "the Mac's clients"),
        Route(path: AppConfig.hubFilesPath, owner: .refuse, wait: 0, why: "the Mac's clients"),
        Route(path: AppConfig.hubSendPath, owner: .refuse, wait: 0, why: "the Mac's clients"),
        Route(path: AppConfig.hubRemoteCheckPath, owner: .refuse, wait: 0, why: "the Mac's clients"),
        Route(path: AppConfig.checkAnswerPath, owner: .refuse, wait: 0, why: "the Mac's clients"),
    ]

    /// The route of a request: its path without a query. `GET /check` lists
    /// the Mac's waiting questions for a test's home: a client's, refused.
    public static func route(method: String, path: String) -> Route? {
        let bare = String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if bare == AppConfig.checkPath && method != "POST" {
            return Route(path: bare, owner: .refuse, wait: 0, why: "GET /check is the Mac's clients'")
        }
        return table.first { $0.path == bare }
    }

    /// The table as `lampd routes` prints it.
    public static func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(table), as: UTF8.self)
    }
}

/// The hooks' port on this machine: what `~/.lampboard/port` says (the Mac's
/// repair writes it, D48, and the hooks read it), or the port derived from the
/// account as the Mac derives it.
public enum HookPortFile {
    public static func primary(paths: LampDPaths) -> UInt16 {
        if let text = try? String(contentsOfFile: paths.hookPortFile, encoding: .utf8),
           let port = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines)), port >= 1024 {
            return port
        }
        return AppConfig.remotePort(forUID: Int(getuid()))
    }
}

/// `LAMPD_HOOK_PORT`: the checks' way to give the service a hooks' port of its
/// own without systemd. Taken only in a home made for a check — one with
/// `LAMPBOARD_HOME` set, or the fake node's `~/.lampd-fixture` — so that nothing
/// pointed at a real machine's port can start (the gate «fake node isolated»).
public enum HookPortOverride {
    public static let variable = "LAMPD_HOOK_PORT"

    public static func port(environment: [String: String], paths: LampDPaths) -> Result<UInt16?, LampDError> {
        guard let text = environment[variable], !text.isEmpty else { return .success(nil) }
        guard let port = UInt16(text), port >= 1024 else { return .failure(.invalid("\(variable)=\(text) is not a port")) }
        let checkHome = environment[AppConfig.homeOverrideVariable].map { !$0.isEmpty } ?? false
        var directory: ObjCBool = false
        let fixture = FileManager.default.fileExists(atPath: paths.home + "/.lampd-fixture", isDirectory: &directory) && directory.boolValue
        guard checkHome || fixture else {
            return .failure(.invalid("\(variable) is for a check's home only (LAMPBOARD_HOME, or a fake node): refused here"))
        }
        return .success(port)
    }
}
