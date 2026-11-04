import Foundation
import NetworkExtension
import XCTest
@testable import WGCNE

final class NetworkSettingsTests: XCTestCase {
    func testDualStackSettingsAndRouteMasks() throws {
        let settings = try WGCNetworkSettings(
            addresses: ["10.7.0.2/24", "fd00:7::2/64"], mtu: 1280,
            dnsServers: ["198.18.0.2", "fd00:7::53"],
            includedRoutes: ["0.0.0.0/0", "::/0"],
            excludedRoutes: ["203.0.113.10/32", "2001:db8::17/128"])
        let native = try settings.makeTunnelNetworkSettings()
        XCTAssertEqual(native.ipv4Settings?.addresses, ["10.7.0.2"])
        XCTAssertEqual(native.ipv4Settings?.subnetMasks, ["255.255.255.0"])
        XCTAssertEqual(native.ipv4Settings?.includedRoutes?.first?.destinationSubnetMask, "0.0.0.0")
        XCTAssertEqual(native.ipv6Settings?.networkPrefixLengths, [64])
        XCTAssertEqual(native.ipv6Settings?.excludedRoutes?.first?.destinationAddress, "2001:db8::17")
        XCTAssertEqual(native.dnsSettings?.matchDomains, [""])
        XCTAssertEqual(native.mtu, 1280)
    }

    func testInvalidNetworkSettingsFailClosed() {
        for address in ["host.invalid/32", "10.0.0.2/33", "fe80::1%en0/64", "10.0.0.2/-1"] {
            XCTAssertThrowsError(try WGCNetworkSettings(addresses: [address], mtu: 1280,
                dnsServers: ["198.18.0.2"], includedRoutes: [], excludedRoutes: []))
        }
        XCTAssertThrowsError(try WGCNetworkSettings(addresses: ["10.0.0.2/32"], mtu: 1280,
            dnsServers: ["resolver.invalid"], includedRoutes: [], excludedRoutes: []))
        XCTAssertThrowsError(try WGCNetworkSettings(addresses: ["10.0.0.2/32"], mtu: 1280,
            dnsServers: ["198.18.0.2"], includedRoutes: ["::/0"], excludedRoutes: []))
        XCTAssertThrowsError(try WGCNetworkSettings(addresses: ["fd00::2/128"], mtu: 1000,
            dnsServers: ["198.18.0.2"], includedRoutes: [], excludedRoutes: []))
    }

    func testDerivedExclusionBoundAllowsInputRoutesAndAllPeerEndpoints() throws {
        let inputRoutes = (0..<1024).map { "10.\($0 / 256).\($0 % 256).0/24" }
        let endpoints = (0..<32).map { "203.0.113.\($0)/32" }
        let excluded = inputRoutes + endpoints
        let settings = try WGCNetworkSettings(addresses: ["10.7.0.2/32"], mtu: 1280,
            dnsServers: ["198.18.0.2"], includedRoutes: inputRoutes, excludedRoutes: excluded)
        let native = try settings.makeTunnelNetworkSettings()
        XCTAssertEqual(native.ipv4Settings?.includedRoutes?.count, 1024)
        XCTAssertEqual(native.ipv4Settings?.excludedRoutes?.count, 1056)
        XCTAssertThrowsError(try WGCNetworkSettings(addresses: settings.addresses, mtu: settings.mtu,
            dnsServers: settings.dnsServers, includedRoutes: inputRoutes + ["0.0.0.0/0"], excludedRoutes: excluded))
        XCTAssertThrowsError(try WGCNetworkSettings(addresses: settings.addresses, mtu: settings.mtu,
            dnsServers: settings.dnsServers, includedRoutes: inputRoutes, excludedRoutes: excluded + ["::/0"]))
    }

    func testABISettingsDecodeUsesDerivedExclusionBound() throws {
        var result: [String: Any] = [
            "addresses": ["10.7.0.2/32", "fd00:7::2/128"], "mtu": 1280,
            "dns_servers": ["198.18.0.2"], "included_routes": ["0.0.0.0/0", "::/0"],
            "excluded_routes": (0..<1056).map { "2001:db8::\(String($0, radix: 16))/128" }
        ]
        func decode() throws -> WGCNetworkSettings {
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
            return try WGCABIEnvelope<WGCNetworkSettings>.decode(data)
        }
        let settings = try decode()
        XCTAssertEqual(settings.excludedRoutes.count, 1056)
        XCTAssertEqual(try settings.makeTunnelNetworkSettings().ipv6Settings?.excludedRoutes?.count, 1056)
        result["excluded_routes"] = settings.excludedRoutes + ["198.51.100.1/32"]
        XCTAssertThrowsError(try decode()) { XCTAssertEqual($0 as? WGCNEError, .invalidConfiguration) }
        result["excluded_routes"] = settings.excludedRoutes
        result["included_routes"] = Array(repeating: "0.0.0.0/0", count: 1025)
        XCTAssertThrowsError(try decode()) { XCTAssertEqual($0 as? WGCNEError, .invalidConfiguration) }
    }

    func testGenericAddressAndMTURangesRemainSupported() throws {
        let addresses = (1...64).map { "10.7.0.\($0)/32" }
        for mtu in [576, 65535] {
            let settings = try WGCNetworkSettings(addresses: addresses, mtu: mtu,
                dnsServers: ["198.18.0.2"], includedRoutes: [], excludedRoutes: [])
            XCTAssertEqual(try settings.makeTunnelNetworkSettings().ipv4Settings?.addresses.count, 64)
        }
        XCTAssertThrowsError(try WGCNetworkSettings(addresses: addresses + ["10.7.0.65/32"], mtu: 1280,
            dnsServers: ["198.18.0.2"], includedRoutes: [], excludedRoutes: []))
    }

    func testUtunLookupRequiresUniqueAddressOwnership() throws {
        let addresses: Set<String> = ["10.7.0.2", "fd00:7::2"]
        XCTAssertEqual(try UtunFileDescriptor.selectInterface(addresses: addresses, interfaces: [
            "en0": addresses, "utun4": ["100.64.0.1"], "utun9": addresses
        ]), "utun9")
        XCTAssertThrowsError(try UtunFileDescriptor.selectInterface(addresses: addresses, interfaces: [
            "utun4": addresses, "utun9": addresses
        ]))
        XCTAssertThrowsError(try UtunFileDescriptor.selectInterface(addresses: addresses, interfaces: [
            "en0": addresses, "utun4": ["10.7.0.2"]
        ]))
        XCTAssertThrowsError(try UtunFileDescriptor.selectInterface(addresses: [], interfaces: ["utun4": addresses]))
    }

    func testStatusDropsUnknownAndSensitiveFields() throws {
        let data = Data("""
        {"ok":true,"result":{"state":"running","bytes_sent":7,"private_key":"must-not-escape","configuration":{"token":"secret"}}}
        """.utf8)
        let status = try WGCABIEnvelope<WGCCoreStatus>.decode(data)
        XCTAssertEqual(status.bytesSent, 7)
        XCTAssertNil(status.dictionary["private_key"])
        XCTAssertNil(status.dictionary["configuration"])
        XCTAssertThrowsError(try WGCABIEnvelope<WGCCoreStatus>.decode(Data("{\"ok\":false,\"error\":\"sensitive\"}".utf8))) { error in
            XCTAssertEqual(error as? WGCNEError, .coreFailure)
            XCTAssertFalse(error.localizedDescription.contains("sensitive"))
        }
    }
}
