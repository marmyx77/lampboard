// swift-tools-version: 6.0
//
// Test vectors for the relay, written by the Core itself.
//
// The relay is JavaScript and the sources that call it are Swift. Rather than
// re-deriving the wire format by hand, the relay's tests read what the Core's
// own `RelayPushRequest`, `RelayCapability` and `PushEnvelope` produce. When the
// Core changes its format, `relay/scripts/make-vectors.sh` regenerates the file
// and the relay's tests say what no longer matches.
import PackageDescription

// The Core takes CryptoKit's API from swift-crypto on Linux, and so does this.
#if os(Linux)
let cryptoPackage: [Package.Dependency] = [.package(url: "https://github.com/apple/swift-crypto.git", "3.15.1"..<"4.0.0")]
let crypto: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
let cryptoPackage: [Package.Dependency] = []
let crypto: [Target.Dependency] = []
#endif

let package = Package(
    name: "RelayVectors",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "LampBoard", path: "../..")] + cryptoPackage,
    targets: [
        .executableTarget(
            name: "RelayVectors",
            dependencies: [.product(name: "LampBoardCore", package: "LampBoard")] + crypto
        ),
    ]
)
