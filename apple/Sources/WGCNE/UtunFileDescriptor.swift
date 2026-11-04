import Darwin
import Foundation

/// Uses public interface/socket APIs only. Address ownership must identify exactly
/// one utun, and the duplicated socket is checked again before ownership transfers.
internal enum UtunFileDescriptor {
    // Darwin's SYSPROTO_CONTROL is not exported by Swift's iOS Darwin module.
    private static let systemControlProtocol: Int32 = 2
    private static let utunOptionInterfaceName: Int32 = 2

    static func duplicate(for settings: WGCNetworkSettings) throws -> Int32 {
        let expectedAddresses = try settings.addresses.map { try IPCIDR($0).address.string }
        let interfaces = try interfaceAddresses()
        let interface = try selectInterface(addresses: Set(expectedAddresses), interfaces: interfaces)
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { throw WGCNEError.tunnelUnavailable }
        let maximum = Int32(min(limit.rlim_cur, 65536))
        for descriptor in 0..<maximum {
            guard interfaceName(descriptor) == interface else { continue }
            let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard owned >= 0 else { continue }
            guard interfaceName(owned) == interface else { close(owned); continue }
            // Fail closed if the interface assignment changed during descriptor lookup.
            do {
                guard try selectInterface(addresses: Set(expectedAddresses), interfaces: interfaceAddresses()) == interface else {
                    throw WGCNEError.tunnelUnavailable
                }
            } catch { close(owned); throw WGCNEError.tunnelUnavailable }
            return owned
        }
        throw WGCNEError.tunnelUnavailable
    }

    static func selectInterface(addresses: Set<String>, interfaces: [String: Set<String>]) throws -> String {
        let candidates = interfaces.filter { name, assigned in
            name.hasPrefix("utun") && !addresses.isEmpty && addresses.isSubset(of: assigned)
        }.map { $0.key }
        guard candidates.count == 1, let candidate = candidates.first else { throw WGCNEError.tunnelUnavailable }
        return candidate
    }

    private static func interfaceName(_ descriptor: Int32) -> String? {
        var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var length = socklen_t(name.count)
        guard getsockopt(descriptor, systemControlProtocol, utunOptionInterfaceName, &name, &length) == 0,
              length > 0, length <= name.count, name.contains(0) else { return nil }
        let value = String(cString: name)
        return value.hasPrefix("utun") ? value : nil
    }

    private static func interfaceAddresses() throws -> [String: Set<String>] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { throw WGCNEError.tunnelUnavailable }
        defer { freeifaddrs(first) }
        var result: [String: Set<String>] = [:]
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("utun"), let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let converted: Bool
            if family == AF_INET {
                converted = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { source in
                    var ip = source.pointee.sin_addr
                    return inet_ntop(AF_INET, &ip, &output, socklen_t(output.count)) != nil
                }
            } else if family == AF_INET6 {
                converted = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { source in
                    var ip = source.pointee.sin6_addr
                    return inet_ntop(AF_INET6, &ip, &output, socklen_t(output.count)) != nil
                }
            } else { continue }
            if converted { result[name, default: []].insert(String(cString: output)) }
        }
        return result
    }
}
