import Foundation
import LampBoardCore

/// `lampboard decide`, `decisions` and `undecide` (D105): the decision board,
/// changed and read through the running panel, which is its only writer.
extension CommandLineInterface {

    static func runDecisions(verb: String, arguments: [String], port: UInt16) -> Int32 {
        let change: DecisionBoardExchange.Change?
        switch verb {
        case "decide":
            guard arguments.count >= 2 else { return usage() }
            change = .pin(repository: arguments[0], text: arguments[1...].joined(separator: " "))
        case "undecide":
            guard arguments.count == 2, let number = Int(arguments[1]) else { return usage() }
            change = .remove(repository: arguments[0], number: number)
        default:
            guard arguments.count <= 1 else { return usage() }
            change = nil
        }
        let body = change.flatMap(Self.encode)
        switch LocalClient.decisions(change: body, port: port) {
        case .failure(let error):
            print(error.localizedDescription)
            return 1
        case .success(let board):
            let repository: String?
            switch change {
            case .pin(let name, _), .remove(let name, _): repository = name
            case nil: repository = arguments.first
            }
            print(listing(board, repository: repository))
            return 0
        }
    }

    static func listing(_ board: DecisionBoard, repository: String?) -> String {
        let names = repository.map { [$0] } ?? board.repositories.keys.sorted()
        guard !names.isEmpty else { return "No decisions pinned." }
        return names.map { name in
            let decisions = board.decisions(for: name)
            guard !decisions.isEmpty else { return "\(name): no decisions pinned." }
            return ([name + ":"] + decisions.enumerated().map { "  \($0.offset + 1). \($0.element.text)" })
                .joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func encode(_ change: DecisionBoardExchange.Change) -> Data? {
        let object: [String: Any]
        switch change {
        case .pin(let repository, let text): object = ["repo": repository, "text": text]
        case .remove(let repository, let number): object = ["repo": repository, "remove": number]
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    private static func usage() -> Int32 {
        print("""
        Usage: lampboard decide <repo> <text>
               lampboard decisions [repo]
               lampboard undecide <repo> <n>
        """)
        return 2
    }
}
