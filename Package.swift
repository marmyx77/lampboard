// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Warnings are errors where Scripts/test.sh and CI build (`LAMPBOARD_STRICT=1`), and
// only in our own targets. That used to be `-Xswiftc -warnings-as-errors` on the
// command line, which reaches every target, the vendored one included (D129).
let strictWarnings = ProcessInfo.processInfo.environment["LAMPBOARD_STRICT"] == "1"
let strict: [SwiftSetting] = [.swiftLanguageMode(.v5)]
    + (strictWarnings ? [.unsafeFlags(["-warnings-as-errors"])] : [])

let package = Package(
    name: "LampBoard",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: parsing, workspace resolution, state machine.
        // No dependency on AppKit — entirely verifiable.
        .target(
            name: "LampBoardCore",
            swiftSettings: strict
        ),
        // A mini assertion framework. It exists because the macOS Command Line
        // Tools, without Xcode, provide neither XCTest nor complete swift-testing.
        .target(
            name: "TestKit",
            swiftSettings: strict
        ),
        // Executable test suite: `swift run LampBoardTests`.
        .executableTarget(
            name: "LampBoardTests",
            dependencies: ["LampBoardCore", "TestKit"],
            swiftSettings: strict
        ),
        // The terminal emulator behind the live view (D129): SwiftTerm,
        // vendored rather than fetched. Its sources, licence and the record of
        // what was changed are in Vendor/SwiftTerm; VENDORED.md says why.
        .target(
            name: "SwiftTerm",
            path: "Vendor/SwiftTerm/Sources/SwiftTerm",
            // Upstream's warnings are upstream's: they are not fixed here, and
            // they are not allowed to drown ours.
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-suppress-warnings"])]
        ),
        // AppKit/SwiftUI shell: floating panel, HTTP server, window focus.
        .executableTarget(
            name: "LampBoardApp",
            dependencies: ["LampBoardCore", "SwiftTerm"],
            swiftSettings: strict,
            // The system's SQLite, for the search index's FTS5 (0.7): nothing bundled.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // End-to-end tests: they launch the real binary and talk to it over HTTP.
        //
        // It lives in a separate target because it is the only one that needs to
        // spawn processes and wait on the network: keeping it together with the
        // domain tests would slow down a suite that has to stay instantaneous.
        .executableTarget(
            name: "LampBoardE2E",
            dependencies: ["LampBoardCore", "TestKit"],
            swiftSettings: strict
        ),
    ]
)
