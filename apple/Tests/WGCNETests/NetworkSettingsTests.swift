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
