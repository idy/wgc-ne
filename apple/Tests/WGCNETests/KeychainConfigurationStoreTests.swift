import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import WGCNE

final class KeychainConfigurationStoreTests: XCTestCase {
    private let group = "TEAM.dev.example.shared"
    private let configuration = Data("{\"version\":1}".utf8)

    func testReadQueryUsesOnlyPersistentReferenceForLookup() throws {
        let reference = Data([1, 2, 3])
        let query = try KeychainConfigurationStore.readQuery(reference: reference, accessGroup: group)
        var expectedKeys: Set<String> = [
            kSecValuePersistentRef as String,
            kSecReturnData as String,
            kSecReturnAttributes as String,
            kSecUseAuthenticationContext as String
        ]
        #if os(macOS)
        expectedKeys.insert(kSecUseDataProtectionKeychain as String)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        #endif
        XCTAssertEqual(Set(query.keys), expectedKeys, "Item-attribute filters must not accompany a persistent reference")
        XCTAssertEqual(query[kSecValuePersistentRef as String] as? Data, reference)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
    }

    func testReadQueryRejectsEmptyAndOversizedReferences() {
        for reference in [Data(), Data(repeating: 1, count: 4097)] {
            XCTAssertThrowsError(try KeychainConfigurationStore.readQuery(reference: reference, accessGroup: group)) {
                XCTAssertEqual($0 as? WGCNEError, .invalidProfile)
            }
        }
    }

    func testReadQueryAcceptsMaximumReferenceLength() throws {
        let reference = Data(repeating: 1, count: 4096)
        let query = try KeychainConfigurationStore.readQuery(reference: reference, accessGroup: group)
        XCTAssertEqual(query[kSecValuePersistentRef as String] as? Data, reference)
    }

    func testReadQueryRejectsInvalidAccessGroups() {
        for invalidGroup in ["", "TEAM.invalid group", "TEAM.共享", String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try KeychainConfigurationStore.readQuery(reference: Data([1]), accessGroup: invalidGroup)) {
                XCTAssertEqual($0 as? WGCNEError, .invalidProfile)
            }
        }
    }

    func testReadResultReturnsConfigurationBytes() throws {
        let data = try KeychainConfigurationStore.configurationData(from: attributes as CFDictionary, accessGroup: group)
        XCTAssertEqual(data, configuration)
    }

    func testReadResultAcceptsAbsentSynchronizableAttribute() throws {
        var result = attributes
        result.removeValue(forKey: kSecAttrSynchronizable as String)
        XCTAssertEqual(try KeychainConfigurationStore.configurationData(from: result as CFDictionary, accessGroup: group), configuration)
    }

    func testReadResultRejectsMissingOwnershipOrData() {
        for key in [kSecAttrService, kSecAttrAccessGroup, kSecValueData] {
            var result = attributes
            result.removeValue(forKey: key as String)
            XCTAssertThrowsError(try KeychainConfigurationStore.configurationData(from: result as CFDictionary, accessGroup: group)) {
                XCTAssertEqual($0 as? WGCNEError, .keychainFailure)
            }
        }
    }

    func testReadResultRejectsForeignService() {
        var result = attributes
        result[kSecAttrService as String] = "dev.example.other.configuration"
        XCTAssertThrowsError(try KeychainConfigurationStore.configurationData(from: result as CFDictionary, accessGroup: group)) {
            XCTAssertEqual($0 as? WGCNEError, .keychainFailure)
        }
    }

    func testReadResultRequiresExactAccessGroup() {
        for otherGroup in ["TEAM.dev.example.other", group.lowercased(), group + ".other"] {
            var result = attributes
            result[kSecAttrAccessGroup as String] = otherGroup
            XCTAssertThrowsError(try KeychainConfigurationStore.configurationData(from: result as CFDictionary, accessGroup: group)) {
                XCTAssertEqual($0 as? WGCNEError, .keychainFailure)
            }
        }
    }

    func testReadResultRejectsSynchronizableItems() {
        var result = attributes
        result[kSecAttrSynchronizable as String] = kCFBooleanTrue
        XCTAssertThrowsError(try KeychainConfigurationStore.configurationData(from: result as CFDictionary, accessGroup: group)) {
            XCTAssertEqual($0 as? WGCNEError, .keychainFailure)
        }
    }

    func testReadResultRejectsMalformedResults() {
        var wrongDataType = attributes
        wrongDataType[kSecValueData as String] = "configuration"
        let results: [CFTypeRef?] = [nil, configuration as CFData, [] as CFArray, wrongDataType as CFDictionary]
        for result in results {
            XCTAssertThrowsError(try KeychainConfigurationStore.configurationData(from: result, accessGroup: group)) {
                XCTAssertEqual($0 as? WGCNEError, .keychainFailure)
            }
        }
    }

    func testReadResultRejectsEmptyAndOversizedData() {
        for data in [Data(), Data(repeating: 1, count: WGCContract.maximumJSONBytes + 1)] {
            var result = attributes
            result[kSecValueData as String] = data
            XCTAssertThrowsError(try KeychainConfigurationStore.configurationData(from: result as CFDictionary, accessGroup: group)) {
                XCTAssertEqual($0 as? WGCNEError, .keychainFailure)
            }
        }
    }

    func testReadResultAcceptsMaximumDataLength() throws {
        let data = Data(repeating: 1, count: WGCContract.maximumJSONBytes)
        var result = attributes
        result[kSecValueData as String] = data
        XCTAssertEqual(try KeychainConfigurationStore.configurationData(from: result as CFDictionary, accessGroup: group), data)
    }

    private var attributes: [String: Any] {
        [
            kSecAttrService as String: WGCContract.keychainService,
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: configuration
        ]
    }
}
