// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Warnings are errors where Scripts/test.sh and CI build (`LAMPBOARD_STRICT=1`), and
// only in our own targets. That used to be `-Xswiftc -warnings-as-errors` on the
// command line, which reaches every target, the vendored one included (D129).
let strictWarnings = ProcessInfo.processInfo.environment["LAMPBOARD_STRICT"] == "1"
let strict: [SwiftSetting] = [.swiftLanguageMode(.v5)]
    + (strictWarnings ? [.unsafeFlags(["-warnings-as-errors"])] : [])

// The Core and its domain suite also build on Linux, for the service that keeps
// a Linux machine's sessions, and the Core builds for iOS. Linux has no
// CryptoKit, so there — and only there — the Core takes the same API from
// swift-crypto. The Mac app never links it: on the Mac and on iOS the Core uses
// the system's CryptoKit.
#if os(Linux)
let crypto: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
let crypto: [Target.Dependency] = []
#endif

// The ssh stack of NodeLink (D175): Citadel on swift-nio-ssh. Every one of these
// is pinned to what was measured in W0 of the mobile plan, Citadel and its fork
// of swift-nio-ssh to a commit rather than a range, because a fork of a third
// party is read once and then must not move under us (S-C, S-R). Only the
// targets that talk ssh name them; the Mac app links none of them, and
// Scripts/check-app-links.sh is the gate that says so.
let sshPackages: [Package.Dependency] = [
    // 0.12.1
    .package(url: "https://github.com/orlandos-nl/Citadel.git", revision: "ae8562f895de06ccb86fdb1cbb65fd99c8976e12"),
    // 0.3.7 of the fork Citadel depends on, not apple/swift-nio-ssh: read at
    // this commit (docs/04-decisions.md, D175).
    .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", revision: "d88989f3d3bb1dfb2a38ce4af598afbf7fc3095c"),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
    // Declared on every platform because Citadel needs it everywhere; the Core
    // takes it on Linux alone (above).
    .package(url: "https://github.com/apple/swift-crypto.git", "3.15.1"..<"4.0.0"),
]
let ssh: [Target.Dependency] = [
    .product(name: "Citadel", package: "Citadel"),
    .product(name: "NIOSSH", package: "swift-nio-ssh"),
    .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "Crypto", package: "swift-crypto"),
]

let package = Package(
    name: "LampBoard",
    platforms: [.macOS(.v14), .iOS(.v17)],
    // Declared so that it can be built on its own, as the iOS app will use it
    // and as Scripts/test-ios.sh builds it: Xcode makes no scheme for a target
    // that no product names. The executables need no line here; a root
    // package's executable targets are products by themselves.
    products: [
        .library(name: "LampBoardCore", targets: ["LampBoardCore"]),
        .library(name: "LampBoardNodeLink", targets: ["LampBoardNodeLink"]),
    ],
    dependencies: sshPackages,
    targets: [
        // Pure logic: parsing, workspace resolution, state machine.
        // No dependency on AppKit — entirely verifiable.
        .target(
            name: "LampBoardCore",
            dependencies: crypto,
            swiftSettings: strict
        ),
        // A mini assertion framework. It exists because the macOS Command Line
        // Tools, without Xcode, provide neither XCTest nor complete swift-testing.
        .target(
            name: "TestKit",
            swiftSettings: strict
        ),
        // The `v1` protocol's conformance battery (W1 of the mobile plan): the
        // same cases against any source a byte stream reaches — the reference
        // source in memory today, `lampd` and the Mac over ssh later. A library,
        // so that every runner can take it; the Mac app does not link it.
        .target(
            name: "ProtocolConformance",
            dependencies: ["LampBoardCore", "TestKit"],
            swiftSettings: strict
        ),
        // The phone's way into a machine (D175): one ssh connection, the host key
        // pinned, a read key that only opens `v1` and an action key, every
        // operation with a deadline of its own. The iPhone and iPad app and the
        // Linux checks use it; the Mac app does not link it.
        .target(
            name: "LampBoardNodeLink",
            dependencies: ["LampBoardCore"] + ssh,
            swiftSettings: strict
        ),
        // The reference `v1` source as a node serves it: a daemon on a Unix
        // socket and the thin `stdio` process sshd runs for a restricted key,
        // the shape `lampd` will have. Only the checks run it.
        .executableTarget(
            name: "V1ReferenceNode",
            dependencies: ["LampBoardCore", "ProtocolConformance"],
            swiftSettings: strict
        ),
        // The conformance battery and the key bites over a real ssh, through
        // NodeLink: `Scripts/test-nodelink.sh` runs it against a node in a container.
        .executableTarget(
            name: "NodeLinkCheck",
            dependencies: ["LampBoardCore", "LampBoardNodeLink", "ProtocolConformance", "TestKit"],
            swiftSettings: strict
        ),
        // Executable test suite: `swift run LampBoardTests`.
        .executableTarget(
            name: "LampBoardTests",
            dependencies: ["LampBoardCore", "TestKit", "ProtocolConformance", "LampBoardNodeLink"] + crypto,
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
        // The live view's chat (D147): message views and the transcript reader
        // from Clarc (Apache 2.0), vendored like SwiftTerm. Vendor/Clarc says
        // which files were taken and what was changed.
        .target(
            name: "ClarcChatKit",
            path: "Vendor/Clarc/Sources/ClarcChatKit",
            // Upstream is written with the main actor as its default isolation.
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-suppress-warnings", "-default-isolation", "MainActor"])]
        ),
        // AppKit/SwiftUI shell: floating panel, HTTP server, window focus.
        .executableTarget(
            name: "LampBoardApp",
            dependencies: ["LampBoardCore", "SwiftTerm", "ClarcChatKit"],
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
