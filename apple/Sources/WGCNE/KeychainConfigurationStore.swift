import Foundation
import LocalAuthentication
import Security

internal protocol ConfigurationStore: AnyObject, Sendable {
    func put(_ configuration: Data, accessGroup: String) throws -> Data
    func read(reference: Data, accessGroup: String) throws -> Data
    func delete(reference: Data, accessGroup: String) throws
}

/// Persistent references are safe to keep in VPN preferences. The referenced bytes
/// are available only to targets entitled for the caller's shared access group.
internal final class KeychainConfigurationStore: ConfigurationStore {
    func put(_ configuration: Data, accessGroup: String) throws -> Data {
        guard WGCContract.validIdentifier(accessGroup), !configuration.isEmpty,
              configuration.count <= WGCContract.maximumJSONBytes else {
            throw WGCNEError.invalidConfiguration
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: WGCContract.keychainService,
            kSecAttrAccount as String: UUID().uuidString,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: configuration,
            kSecReturnPersistentRef as String: true,
            kSecUseAuthenticationContext as String: Self.noninteractiveContext()
        ]
        var result: CFTypeRef?
        guard SecItemAdd(query as CFDictionary, &result) == errSecSuccess,
              let reference = result as? Data, !reference.isEmpty else {
            throw WGCNEError.keychainFailure
        }
        return reference
    }

    func read(reference: Data, accessGroup: String) throws -> Data {
        let query = try Self.readQuery(reference: reference, accessGroup: accessGroup)
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            throw WGCNEError.keychainFailure
        }
        return try Self.configurationData(from: result, accessGroup: accessGroup)
    }

    internal static func readQuery(reference: Data, accessGroup: String) throws -> [String: Any] {
        guard !reference.isEmpty, reference.count <= 4096,
              WGCContract.validIdentifier(accessGroup) else { throw WGCNEError.invalidProfile }
        // Keep persistent-reference lookup separate from ownership checks on the returned attributes.
        var query: [String: Any] = [
            kSecValuePersistentRef as String: reference,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: noninteractiveContext()
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    internal static func configurationData(from result: CFTypeRef?, accessGroup: String) throws -> Data {
        guard let attributes = result as? [String: Any],
              attributes[kSecAttrService as String] as? String == WGCContract.keychainService,
              attributes[kSecAttrAccessGroup as String] as? String == accessGroup,
              attributes[kSecAttrSynchronizable as String] as? Bool != true,
              let data = attributes[kSecValueData as String] as? Data, !data.isEmpty,
              data.count <= WGCContract.maximumJSONBytes else { throw WGCNEError.keychainFailure }
        return data
    }

    func delete(reference: Data, accessGroup: String) throws {
        let result = SecItemDelete(try referenceQuery(reference, accessGroup: accessGroup) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw WGCNEError.keychainFailure
        }
    }

    private static func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func referenceQuery(_ reference: Data, accessGroup: String) throws -> [String: Any] {
        guard !reference.isEmpty, reference.count <= 4096,
              WGCContract.validIdentifier(accessGroup) else { throw WGCNEError.invalidProfile }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: WGCContract.keychainService,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValuePersistentRef as String: reference,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: Self.noninteractiveContext()
        ]
    }
}
