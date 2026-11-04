import Darwin
import Foundation
import NetworkExtension

internal struct IPAddress: Equatable {
    let family: Int32
    let bytes: [UInt8]
    let string: String

    init(_ value: String) throws {
        guard !value.isEmpty, !value.contains("%"), value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw WGCNEError.invalidConfiguration
        }
        var v4 = in_addr()
        var v6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            family = AF_INET
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
        } else if value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            family = AF_INET6
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
        } else { throw WGCNEError.invalidConfiguration }
        string = Self.format(bytes, family: family)
    }

    static func format(_ bytes: [UInt8], family: Int32) -> String {
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let success = bytes.withUnsafeBytes { source in
            inet_ntop(family, source.baseAddress, &output, socklen_t(output.count)) != nil
        }
        return success ? String(cString: output) : ""
    }
}

internal struct IPCIDR {
    let address: IPAddress
    let prefix: Int

    init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let prefix = Int(parts[1]) else { throw WGCNEError.invalidConfiguration }
        let address = try IPAddress(String(parts[0]))
        guard (0...(address.family == AF_INET ? 32 : 128)).contains(prefix) else {
            throw WGCNEError.invalidConfiguration
        }
        self.address = address
        self.prefix = prefix
    }

    var subnetMask: String {
        let mask = (0..<4).map { index -> UInt8 in
            let count = min(8, max(0, prefix - index * 8))
            return count == 0 ? 0 : UInt8(255 << (8 - count) & 255)
        }
        return IPAddress.format(mask, family: AF_INET)
    }

    var networkAddress: String {
        let network = address.bytes.enumerated().map { index, byte -> UInt8 in
            let count = min(8, max(0, prefix - index * 8))
            let mask: UInt8 = count == 0 ? 0 : UInt8(255 << (8 - count) & 255)
            return byte & mask
        }
        return IPAddress.format(network, family: address.family)
    }
}

/// Public, validated settings returned by the core's offline validation operation.
public struct WGCNetworkSettings: Codable, Equatable, Sendable {
    public let addresses: [String]
    public let mtu: Int
    public let dnsServers: [String]
    public let includedRoutes: [String]
    public let excludedRoutes: [String]

    enum CodingKeys: String, CodingKey {
        case addresses, mtu, dnsServers = "dns_servers"
        case includedRoutes = "included_routes", excludedRoutes = "excluded_routes"
    }

    public init(addresses: [String], mtu: Int, dnsServers: [String],
                includedRoutes: [String], excludedRoutes: [String]) throws {
        // Derived exclusions also include up to 32 peer endpoint host routes.
        guard (1...64).contains(addresses.count), (576...65535).contains(mtu),
              (1...8).contains(dnsServers.count), includedRoutes.count <= 1024,
              excludedRoutes.count <= 1056 else { throw WGCNEError.invalidConfiguration }
        let parsedAddresses = try addresses.map(IPCIDR.init)
        let families = Set(parsedAddresses.map { $0.address.family })
        if families.contains(AF_INET6), mtu < 1280 { throw WGCNEError.invalidConfiguration }
        _ = try dnsServers.map(IPAddress.init)
        let included = try includedRoutes.map(IPCIDR.init)
        _ = try excludedRoutes.map(IPCIDR.init)
        guard included.allSatisfy({ families.contains($0.address.family) }),
              Set(parsedAddresses.map { $0.address.string }).count == addresses.count else {
            throw WGCNEError.invalidConfiguration
        }
        self.addresses = addresses
        self.mtu = mtu
        self.dnsServers = dnsServers
        self.includedRoutes = includedRoutes
        self.excludedRoutes = excludedRoutes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(addresses: values.decode([String].self, forKey: .addresses),
                      mtu: values.decode(Int.self, forKey: .mtu),
                      dnsServers: values.decode([String].self, forKey: .dnsServers),
                      includedRoutes: values.decode([String].self, forKey: .includedRoutes),
                      excludedRoutes: values.decode([String].self, forKey: .excludedRoutes))
    }

    public func makeTunnelNetworkSettings() throws -> NEPacketTunnelNetworkSettings {
        let assigned = try addresses.map(IPCIDR.init)
        let included = try includedRoutes.map(IPCIDR.init)
        let excluded = try excludedRoutes.map(IPCIDR.init)
        let result = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        result.mtu = NSNumber(value: mtu)
        let v4 = assigned.filter { $0.address.family == AF_INET }
        if !v4.isEmpty {
            let settings = NEIPv4Settings(addresses: v4.map { $0.address.string }, subnetMasks: v4.map { $0.subnetMask })
            settings.includedRoutes = included.filter { $0.address.family == AF_INET }.map {
                NEIPv4Route(destinationAddress: $0.networkAddress, subnetMask: $0.subnetMask)
            }
            settings.excludedRoutes = excluded.filter { $0.address.family == AF_INET }.map {
                NEIPv4Route(destinationAddress: $0.networkAddress, subnetMask: $0.subnetMask)
            }
            result.ipv4Settings = settings
        }
        let v6 = assigned.filter { $0.address.family == AF_INET6 }
        if !v6.isEmpty {
            let settings = NEIPv6Settings(addresses: v6.map { $0.address.string },
                                          networkPrefixLengths: v6.map { NSNumber(value: $0.prefix) })
            settings.includedRoutes = included.filter { $0.address.family == AF_INET6 }.map {
                NEIPv6Route(destinationAddress: $0.networkAddress, networkPrefixLength: NSNumber(value: $0.prefix))
            }
            settings.excludedRoutes = excluded.filter { $0.address.family == AF_INET6 }.map {
                NEIPv6Route(destinationAddress: $0.networkAddress, networkPrefixLength: NSNumber(value: $0.prefix))
            }
            result.ipv6Settings = settings
        }
        let dns = NEDNSSettings(servers: try dnsServers.map { try IPAddress($0).string })
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        result.dnsSettings = dns
        return result
    }
}
