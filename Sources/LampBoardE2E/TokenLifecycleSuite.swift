import LampBoardCore
import Foundation
import TestKit

/// The token's lifecycle across two startups.
///
/// This is the part with the worst consequences when it goes wrong — either the
/// endpoint stays open, or the secret survives having been readable — and it is
/// also the part the domain tests cannot touch, because it lives entirely in I/O.
///
/// Each case starts a **second instance** of the app against the same fake home,
/// on a different port, and watches what it decides to do.
enum TokenLifecycleSuite {

    static func suite(binaryURL: URL, home: URL, port: UInt16) -> TestSuite {
        TestSuite("E2E · token lifecycle", [

            TestCase("a restart reuses the existing token") { a in
                guard let before = readToken(in: home) else {
                    return a.fail("no token to reuse")
                }

                let second = AppUnderTest(binaryURL: binaryURL, port: port, home: home)
                defer { second.stopKeepingHome() }
                do { try second.startReusingHome() } catch {
                    return a.fail("second instance did not start: \(error)")
                }

                // Regenerating on every startup would invalidate every script
                // that saved the token, with nothing to justify it.
                a.expectEqual(second.tokenValue, before, "token")
            },

            TestCase("a token with permissions that are too wide gets regenerated") { a in
                guard let before = readToken(in: home) else {
                    return a.fail("no starting token")
                }

                let tokenURL = home.appendingPathComponent(".lampboard/token")
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: tokenURL.path
                )

                let second = AppUnderTest(binaryURL: binaryURL, port: port, home: home)
                defer { second.stopKeepingHome() }
                do { try second.startReusingHome() } catch {
                    return a.fail("second instance did not start: \(error)")
                }

                // A secret that has been readable by others must be considered
                // burned: repairing the permissions and keeping it would leave a
                // value in circulation that somebody may already have read.
                a.expect(
                    second.tokenValue != before,
                    "the token was not regenerated despite the wide permissions"
                )

                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: tokenURL.path
                )
                let permissions = (attributes?[.posixPermissions] as? NSNumber)?.int16Value ?? 0
                a.expectEqual(permissions & 0o777, 0o600, "permissions of the new token")
            },

            TestCase("the old token is no longer valid after regeneration") { a in
                let second = AppUnderTest(binaryURL: binaryURL, port: port, home: home)
                defer { second.stopKeepingHome() }
                do { try second.startReusingHome() } catch {
                    return a.fail("second instance did not start: \(error)")
                }

                let result = second.raw(
                    method: "GET",
                    path: AppConfig.sessionsPath,
                    token: .some(String(repeating: "0", count: AccessToken.byteCount * 2))
                )
                a.expectEqual(result.status, 401, "status")
            },

            TestCase("a corrupted token on disk gets replaced") { a in
                let tokenURL = home.appendingPathComponent(".lampboard/token")
                try? Data("this-is-not-a-token".utf8).write(to: tokenURL)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: tokenURL.path
                )

                let second = AppUnderTest(binaryURL: binaryURL, port: port, home: home)
                defer { second.stopKeepingHome() }
                do { try second.startReusingHome() } catch {
                    return a.fail("second instance did not start: \(error)")
                }

                guard let token = second.tokenValue else {
                    return a.fail("no token after the replacement")
                }
                a.expect(AccessToken.isWellFormed(token), "malformed token: \(token)")

                // And it has to actually work, not just have the right shape.
                a.expectEqual(
                    second.raw(method: "GET", path: AppConfig.sessionsPath).status,
                    200,
                    "status with the new token"
                )
            },

            // The repair that makes requiring a token possible, in a home of its
            // own: the shared one has an instance running, and a case that
            // restarted it would take every later case down with it.
            //
            // Two launches. The first is an instance on **another** port, and it
            // has to leave the hooks exactly as it found them: the first version
            // of the repair reinstalled at its own port, and a case in the
            // installation suite that starts the bare binary on 9903 turned the
            // whole shared installation towards a process that then exited. The
            // second is the instance the hooks are addressed to, and it has to
            // bring both halves up to the token while keeping the shape they had:
            // `PreToolUse` and the message listener stay registered.
            TestCase("a launch repairs the hooks addressed to it, and only those") { a in
                let own = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lampboard-e2e-repair-\(ProcessInfo.processInfo.processIdentifier)")
                try? FileManager.default.removeItem(at: own)
                for sub in [".claude", ".lampboard"] {
                    try? FileManager.default.createDirectory(
                        at: own.appendingPathComponent(sub), withIntermediateDirectories: true
                    )
                }
                defer { try? FileManager.default.removeItem(at: own) }

                // What 0.4.0 wrote: both halves without a token, every optional
                // registration on.
                let scriptURL = own.appendingPathComponent(".lampboard/hook.sh")
                let rewakeURL = own.appendingPathComponent(".lampboard/rewake.sh")
                let settingsURL = own.appendingPathComponent(".claude/settings.json")
                let addressed: UInt16 = port &+ 5
                let stale = HookConfigMerger.install(
                    into: [:],
                    scriptPath: scriptURL.path,
                    rewakeScriptPath: rewakeURL.path,
                    registerMessageDelivery: true,
                    events: HookConfigMerger.defaultEvents + HookConfigMerger.toolEvents,
                    endpoint: HookConfigMerger.endpoint(port: addressed, token: nil)
                )
                guard let staleBytes = try? JSONSerialization.data(withJSONObject: stale, options: [.sortedKeys]),
                      (try? staleBytes.write(to: settingsURL)) != nil,
                      (try? HookScriptBuilder.script(port: addressed, token: nil).write(
                          to: scriptURL, atomically: true, encoding: .utf8
                      )) != nil
                else { return a.fail("could not lay out the stale installation") }
                let staleScript = try? String(contentsOf: scriptURL, encoding: .utf8)

                let stranger = AppUnderTest(binaryURL: binaryURL, port: port &+ 6, home: own)
                do { try stranger.startReusingHome() } catch {
                    return a.fail("the instance on another port did not start: \(error)")
                }
                stranger.stopKeepingHome()
                a.expectEqual(
                    try? Data(contentsOf: settingsURL), staleBytes,
                    "an instance on another port rewrote settings.json"
                )
                a.expectEqual(
                    try? String(contentsOf: scriptURL, encoding: .utf8), staleScript,
                    "an instance on another port rewrote the script"
                )

                let owner = AppUnderTest(binaryURL: binaryURL, port: addressed, home: own)
                defer { owner.stopKeepingHome() }
                do { try owner.startReusingHome() } catch {
                    return a.fail("the addressed instance did not start: \(error)")
                }
                guard let token = owner.tokenValue else { return a.fail("no token after the launch") }

                guard let data = try? Data(contentsOf: settingsURL),
                      let repaired = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return a.fail("settings.json unreadable after the repair") }
                a.expect(
                    !HookConfigMerger.lacksToken(in: repaired, scriptPath: scriptURL.path, token: token),
                    "a native hook still lacks the token"
                )
                let script = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
                a.expect(script.contains(token), "the script still lacks the token")
                a.expect(HookScriptBuilder.posts(script, to: addressed), "the script changed listener")
                a.expectEqual(
                    HookConfigMerger.nativePorts(in: repaired), [addressed], "the hooks changed listener"
                )

                let events = HookConfigMerger.installedEvents(in: repaired, scriptPath: scriptURL.path)
                for event in HookConfigMerger.toolEvents {
                    a.expect(events.contains(event), "\(event) was dropped by the repair")
                }
                a.expect(
                    HookConfigMerger.isInstalled(in: repaired, scriptPath: rewakeURL.path),
                    "message delivery was dropped by the repair"
                )
            },

            // The other stale installation in the world: the one written under
            // the project's previous name, command hooks only, never reinstalled.
            // The menu called it "not installed" and the repair did not see it.
            // One launch has to bring it forward: current path, native form, the
            // token, and the event added since — with the old registrations gone.
            TestCase("a launch brings an installation under the previous name to the current one") { a in
                let own = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lampboard-e2e-rename-\(ProcessInfo.processInfo.processIdentifier)")
                try? FileManager.default.removeItem(at: own)
                let legacyDirectory = own.appendingPathComponent(".clawd-light")
                for directory in [own.appendingPathComponent(".claude"), legacyDirectory] {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                defer { try? FileManager.default.removeItem(at: own) }

                let addressed: UInt16 = port &+ 7
                let legacyScript = legacyDirectory.appendingPathComponent("hook.sh")
                let settingsURL = own.appendingPathComponent(".claude/settings.json")
                let stale = HookConfigMerger.install(
                    into: [:], scriptPath: legacyScript.path, rewakeScriptPath: nil,
                    registerMessageDelivery: false,
                    events: HookConfigMerger.defaultEvents.filter { $0 != "PostToolUseFailure" }
                )
                guard (try? JSONSerialization.data(withJSONObject: stale, options: [.sortedKeys]).write(to: settingsURL)) != nil,
                      (try? HookScriptBuilder.script(port: addressed, token: nil).write(
                          to: legacyScript, atomically: true, encoding: .utf8
                      )) != nil
                else { return a.fail("could not lay out the previous name's installation") }

                let owner = AppUnderTest(binaryURL: binaryURL, port: addressed, home: own)
                defer { owner.stopKeepingHome() }
                do { try owner.startReusingHome() } catch {
                    return a.fail("the instance did not start: \(error)")
                }
                guard let token = owner.tokenValue else { return a.fail("no token after the launch") }

                guard let data = try? Data(contentsOf: settingsURL),
                      let repaired = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return a.fail("settings.json unreadable after the launch") }
                let current = own.appendingPathComponent(".lampboard/hook.sh")
                a.expect(
                    !HookConfigMerger.hasCommandHook(at: legacyScript.path, in: repaired),
                    "the previous name's registrations are still there"
                )
                a.expectEqual(HookConfigMerger.nativePorts(in: repaired), [addressed], "native, and addressed as before")
                a.expect(
                    !HookConfigMerger.lacksToken(in: repaired, scriptPath: current.path, token: token),
                    "a native hook lacks the token"
                )
                a.expect(
                    HookConfigMerger.installedEvents(in: repaired, scriptPath: current.path)
                        .contains("PostToolUseFailure"),
                    "the event added since the previous name is not registered"
                )
                let script = (try? String(contentsOf: current, encoding: .utf8)) ?? ""
                a.expect(script.contains(token), "the current script lacks the token")
                a.expect(HookScriptBuilder.posts(script, to: addressed), "the current script changed listener")
            },
        ])
    }

    private static func readToken(in home: URL) -> String? {
        let url = home.appendingPathComponent(".lampboard/token")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmed
    }
}
