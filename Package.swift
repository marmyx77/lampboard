// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LampBoard",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: parsing, workspace resolution, state machine.
        // No dependency on AppKit — entirely verifiable.
        .target(
            name: "LampBoardCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // A mini assertion framework. It exists because the macOS Command Line
        // Tools, without Xcode, provide neither XCTest nor complete swift-testing.
        .target(
            name: "TestKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Executable test suite: `swift run LampBoardTests`.
        .executableTarget(
            name: "LampBoardTests",
            dependencies: ["LampBoardCore", "TestKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // AppKit/SwiftUI shell: floating panel, HTTP server, window focus.
        .executableTarget(
            name: "LampBoardApp",
            dependencies: ["LampBoardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
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
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
