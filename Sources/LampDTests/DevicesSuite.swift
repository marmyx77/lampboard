import Foundation
import LampBoardCore
import LampDKit
import TestKit

/// The phones' lines in `authorized_keys` (§2.4, ADR-65 point 8): what they
/// allow, and that nothing else in the file is ever touched.
enum DevicesSuite {

    static let house = """
    # the home mesh
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample laptop
    from="192.0.2.0/24" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherOtherOtherOtherOtherOtherOtherOther12 build-box

    """

    static let suite = TestSuite("lampd: devices and authorized_keys", [

        TestCase("The read key's line forces v1 and nothing else; the action key's allows a terminal") { t in
            let lines = AuthorizedKeys.lines(device: "phone-1", readKey: F.key(seed: 1), actionKey: F.key(seed: 2),
                                             from: "192.0.2.0/24", command: "/home/dev/.local/bin/lampd")
            t.expectEqual(lines.count, 2, "two lines")
            t.expect(lines[0].hasPrefix("restrict,from=\"192.0.2.0/24\",command=\"/home/dev/.local/bin/lampd v1-stdio --device phone-1\" "),
                     "read: restrict, from=, the forced command: \(lines[0])")
            t.expect(!lines[0].contains("pty"), "read: no terminal")
            t.expect(lines[0].hasSuffix(" lampboard-device:phone-1:read"), "read: the marker")
            t.expect(lines[1].hasPrefix("restrict,pty,from=\"192.0.2.0/24\" "), "action: restrict, pty, from=")
            t.expect(!lines[1].contains("command="), "action: no forced command")
            t.expect(lines[1].hasSuffix(" lampboard-device:phone-1:action"), "action: the marker")
        },

        TestCase("Adding and revoking leave every other line exactly as it was") { t in
            let added = try? AuthorizedKeys.rewrite(house, removing: "phone-1", adding: ["a lampboard-device:phone-1:read"])
            t.expectEqual(added, house + "a lampboard-device:phone-1:read\n", "appended after the others, nothing moved")
            let back = try? AuthorizedKeys.rewrite(added ?? "", removing: "phone-1", adding: [])
            t.expectEqual(back, house, "revoked: the file as it was")
            let noNewline = "ssh-ed25519 AAAA laptop"
            t.expectEqual(try? AuthorizedKeys.rewrite(noNewline, removing: "x", adding: []), noNewline,
                          "a file without a final newline and nothing to do is given back as it is")
            t.expectEqual(try? AuthorizedKeys.rewrite(noNewline, removing: nil, adding: ["b lampboard-device:x:read"]),
                          noNewline + "\nb lampboard-device:x:read\n", "and one that grows keeps its line whole")
        },

        TestCase("Revoking one device leaves the other's lines") { t in
            let two = "k1 lampboard-device:one:read\nk2 lampboard-device:one:action\nk3 lampboard-device:two:read\n"
            t.expectEqual(try? AuthorizedKeys.rewrite(two, removing: "one", adding: []), "k3 lampboard-device:two:read\n", "only one's")
        },

        TestCase("Only a well-formed marker at the end of a line makes it LampBoard's") { t in
            t.expect(AuthorizedKeys.owner(of: "ssh-ed25519 AAAA lampboard-device:phone-1:read") != nil, "a marker")
            t.expect(AuthorizedKeys.owner(of: "ssh-ed25519 AAAA lampboard-device:phone-1:shell") == nil, "an unknown role")
            t.expect(AuthorizedKeys.owner(of: "ssh-ed25519 AAAA lampboard-device:Phone:read") == nil, "an id out of shape")
            t.expect(AuthorizedKeys.owner(of: "ssh-ed25519 AAAA lampboard-device:phone-1:read laptop") == nil,
                     "a marker that is not the last word")
            t.expect(AuthorizedKeys.owner(of: "# lampboard-device:phone-1") == nil, "a comment that names one")
        },

        TestCase("A key is one key of a phone's type, nothing that could become syntax") { t in
            if case .success(let key) = AuthorizedKeys.publicKey(F.key() + " phone") {
                t.expectEqual(key, F.key(), "the comment is dropped")
            } else { t.expect(false, "a P-256 key is a key") }
            t.expect((try? AuthorizedKeys.publicKey(F.key("ssh-ed25519")).get()) != nil, "an Ed25519 key is a key")
            for bad in [
                "command=\"id\" " + F.key(),
                F.key("ssh-rsa"),
                F.key() + "\nssh-ed25519 AAAA",
                "ecdsa-sha2-nistp256 not\"base64",
                "ecdsa-sha2-nistp256 " + F.key("ssh-ed25519").split(separator: " ")[1],
            ] {
                if case .success = AuthorizedKeys.publicKey(bad) { t.expect(false, "accepted: \(bad)") }
            }
        },

        TestCase("from= takes addresses and networks only") { t in
            t.expect((try? AuthorizedKeys.fromList(["192.0.2.0/24", "fd7a:115c:a1e0::/48"]).get()) != nil, "networks")
            t.expect((try? AuthorizedKeys.fromList(["192.0.2.0/24\",command=\"id"]).get()) == nil, "a quote")
            t.expect((try? AuthorizedKeys.fromList([]).get()) == nil, "nothing")
        },

        TestCase("A device's id is a plain word, and one is made from its name") { t in
            t.expect(AuthorizedKeys.isDeviceId("iphone-3fa2c1"), "a word")
            for bad in ["", "-x", "Phone", "a b", "a;b", String(repeating: "a", count: 41)] {
                t.expect(!AuthorizedKeys.isDeviceId(bad), "refused: \(bad)")
            }
            let made = DeviceIds.make(name: "Sam's iPhone", readKey: F.key())
            t.expect(made.hasPrefix("sam-s-iphone-") && AuthorizedKeys.isDeviceId(made), "made: \(made)")
            t.expect(made != DeviceIds.make(name: "Sam's iPhone", readKey: F.key(seed: 9)), "two keys, two ids")
        },

        TestCase("devices add writes the two lines and the entry; revoke takes them; the house stays") { t in
            let paths = F.home("devices")
            defer { F.remove(paths) }
            try? FileManager.default.createDirectory(atPath: paths.home + "/.ssh", withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: paths.authorizedKeys, contents: Data(house.utf8),
                                           attributes: [.posixPermissions: 0o600])
            let store = DevicesStore(paths: paths)
            guard case .success(let addition) = DevicesStore.addition(
                id: "phone-1", name: "Example phone", readKey: F.key(seed: 1), actionKey: F.key(seed: 2),
                from: ["192.0.2.0/24"], command: "/home/dev/.local/bin/lampd") else { t.expect(false, "refused"); return }
            t.expectNil((try? store.add(addition)) == nil ? "failed" : nil, "added")
            let text = (try? String(contentsOfFile: paths.authorizedKeys, encoding: .utf8)) ?? ""
            t.expect(text.hasPrefix(house), "the house first, unchanged")
            t.expectEqual(AuthorizedKeys.devices(in: text).first?.roles, [.read, .action], "two lines")
            t.expectEqual(store.entries().map(\.name), ["Example phone"], "the entry")
            let mode = ((try? FileManager.default.attributesOfItem(atPath: paths.authorizedKeys))?[.posixPermissions] as? Int) ?? 0
            t.expectEqual(mode, 0o600, "still the account's alone")
            t.expectEqual(store.v1Devices().map(\.id), ["phone-1"], "listed for v1")
            t.expectEqual(try? store.revoke("phone-1"), true, "revoked")
            t.expectEqual(try? String(contentsOfFile: paths.authorizedKeys, encoding: .utf8), house, "the file as it was")
            t.expectEqual(store.entries().count, 0, "no entry")
            t.expectEqual(try? store.revoke("phone-1"), false, "a second time: nothing to revoke")
        },

        TestCase("A key already on another line is refused, and nothing is written") { t in
            let paths = F.home("twice")
            defer { F.remove(paths) }
            let store = DevicesStore(paths: paths)
            let read = F.key(seed: 1), action = F.key(seed: 2)
            guard case .success(let one) = DevicesStore.addition(id: "one", name: "One", readKey: read, actionKey: action,
                                                                 from: ["192.0.2.0/24"], command: "/x/lampd"),
                  case .success(let two) = DevicesStore.addition(id: "two", name: "Two", readKey: read, actionKey: F.key(seed: 3),
                                                                 from: ["192.0.2.0/24"], command: "/x/lampd")
            else { t.expect(false, "refused"); return }
            t.expect((try? store.add(one)) != nil, "the first")
            let before = try? String(contentsOfFile: paths.authorizedKeys, encoding: .utf8)
            t.expect((try? store.add(two)) == nil, "the second, with the same read key, refused")
            t.expectEqual(try? String(contentsOfFile: paths.authorizedKeys, encoding: .utf8), before, "unchanged")
            t.expect((try? store.add(one)) != nil, "the same device again replaces its own lines")
            let text = (try? String(contentsOfFile: paths.authorizedKeys, encoding: .utf8)) ?? ""
            t.expectEqual(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2, "still two lines")
        },

        TestCase("A link in place of authorized_keys is not written through") { t in
            let paths = F.home("link")
            defer { F.remove(paths) }
            try? FileManager.default.createDirectory(atPath: paths.home + "/.ssh", withIntermediateDirectories: true)
            let target = paths.home + "/elsewhere"
            _ = FileManager.default.createFile(atPath: target, contents: Data("keep\n".utf8))
            try? FileManager.default.createSymbolicLink(atPath: paths.authorizedKeys, withDestinationPath: target)
            guard case .success(let addition) = DevicesStore.addition(id: "phone-1", name: "Phone", readKey: F.key(seed: 1),
                                                                      actionKey: F.key(seed: 2), from: ["192.0.2.0/24"],
                                                                      command: "/x/lampd") else { t.expect(false, "refused"); return }
            t.expect((try? DevicesStore(paths: paths).add(addition)) == nil, "refused")
            t.expectEqual(try? String(contentsOfFile: target, encoding: .utf8), "keep\n", "what it points at is intact")
        },

        TestCase("The checks before writing: a name, an absolute command without spaces, two different keys") { t in
            func refused(_ result: Result<DevicesStore.Addition, LampDError>) -> Bool {
                if case .failure = result { return true } else { return false }
            }
            t.expect(refused(DevicesStore.addition(id: "p", name: "", readKey: F.key(seed: 1), actionKey: F.key(seed: 2),
                                                   from: ["192.0.2.0/24"], command: "/x/lampd")), "no name")
            t.expect(refused(DevicesStore.addition(id: "p", name: "P", readKey: F.key(seed: 1), actionKey: F.key(seed: 2),
                                                   from: ["192.0.2.0/24"], command: "lampd")), "a relative command")
            t.expect(refused(DevicesStore.addition(id: "p", name: "P", readKey: F.key(seed: 1), actionKey: F.key(seed: 2),
                                                   from: ["192.0.2.0/24"], command: "/x/lampd --role action")), "a command with words")
            t.expect(refused(DevicesStore.addition(id: "p", name: "P", readKey: F.key(seed: 1), actionKey: F.key(seed: 1),
                                                   from: ["192.0.2.0/24"], command: "/x/lampd")), "one key twice")
        },

        TestCase("The phone's networks: the tailnet, and this machine's own") { t in
            t.expectEqual(LocalNetworks.tailnet.count, 2, "v4 and v6")
            t.expect(LocalNetworks.defaults().starts(with: LocalNetworks.tailnet), "the tailnet first")
            t.expect(LocalNetworks.localIPv4().allSatisfy { !$0.hasPrefix("127.") }, "never loopback")
        },
    ])
}
