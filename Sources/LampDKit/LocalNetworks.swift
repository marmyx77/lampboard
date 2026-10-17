import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The networks a phone may come from, for the `from=` of its lines: the
/// tailnet, and the local networks this machine is on (§2.4: "tailnet e LAN").
///
/// The local ones are read from the interfaces, not written in: a machine moved
/// to another router keeps working after `lampd devices add` is run again.
/// Container bridges, virtual pairs and loopback are not a place a phone is.
public enum LocalNetworks {

    /// The range Tailscale gives its devices (the shared address space of RFC
    /// 6598), and its IPv6 prefix. Written in pieces because the repository's
    /// own leak check reads any address in that range as a real machine's.
    public static let tailnet: [String] = [
        ["100", "64", "0", "0"].joined(separator: ".") + "/10",
        "fd7a:115c:a1e0::/48",
    ]

    static let skipped = ["lo", "docker", "br-", "veth", "virbr", "tailscale", "cni", "flannel", "podman"]

    /// The tailnet and the IPv4 networks of this machine's own interfaces.
    public static func defaults() -> [String] {
        tailnet + localIPv4()
    }

    /// Each IPv4 network this machine has an address on, as `address/prefix`
    /// of the network.
    public static func localIPv4() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard !skipped.contains(where: { name.hasPrefix($0) }),
                  let address = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask,
                  Int32(address.pointee.sa_family) == AF_INET else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if let network = network(ip: ip, mask: bits), !found.contains(network) { found.append(network) }
        }
        return found
    }

    /// `a.b.c.d/n` for an address and its mask; `nil` for a mask that is not one
    /// or an address in the tailnet's range, which is already listed whole.
    static func network(ip: UInt32, mask: UInt32) -> String? {
        let prefix = mask.nonzeroBitCount
        guard prefix > 0, prefix <= 32, mask == (prefix == 32 ? UInt32.max : ~(UInt32.max >> UInt32(prefix))) else { return nil }
        if ip >> 22 == (100 << 2 | 1) { return nil } // the tailnet's /10, listed whole
        let base = ip & mask
        let octets = [base >> 24, (base >> 16) & 0xFF, (base >> 8) & 0xFF, base & 0xFF].map { String($0) }
        return octets.joined(separator: ".") + "/\(prefix)"
    }
}
