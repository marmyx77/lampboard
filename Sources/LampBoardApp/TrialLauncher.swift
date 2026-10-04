import LampBoardCore
import Foundation

/// `lampboard tour`: starts the trial panel beside the real one.
///
/// A second process of this same binary, on a temporary home named so that
/// it, and only it, is deleted when the trial quits, and on a port nobody is
/// listening on. The real panel is not touched: the two never share a
/// process, a home or a port (D64).
enum TrialLauncher {

    static let ports: ClosedRange<UInt16> = 9_880...9_896

    static func run(json: Bool) -> Int32 {
        if json {
            print(DemoScript.standard.json())
            return 0
        }
        guard let executable = Bundle.main.executablePath else { return 1 }
        guard let port = ports.first(where: isFree) else {
            FileHandle.standardError.write(Data("No free port between \(ports.lowerBound) and \(ports.upperBound).\n".utf8))
            return 1
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(TrialStage.homePrefix + UUID().uuidString.prefix(8).lowercased())
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--trial", "--port", String(port), "--skip-setup-prompt"]
        var environment = ProcessInfo.processInfo.environment
        environment[AppConfig.homeOverrideVariable] = home.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("The trial did not start: \(error.localizedDescription)\n".utf8))
            return 1
        }
        print("A trial panel with invented sessions is starting on port \(port). Quit it from its menu.")
        return 0
    }

    /// Free when it can be bound on loopback: the test the server itself makes.
    static func isFree(_ port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
