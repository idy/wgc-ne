import Foundation

/// Errors intentionally contain no configuration, platform error descriptions, or credentials.
public enum WGCNEError: String, Error, LocalizedError, Sendable {
    case invalidArguments = "invalid_arguments"
    case invalidConfiguration = "invalid_configuration"
    case invalidProfile = "invalid_profile"
    case profileConflict = "profile_conflict"
    case keychainFailure = "keychain_failure"
    case preferencesFailure = "preferences_failure"
    case tunnelStartFailed = "tunnel_start_failed"
    case providerUnavailable = "provider_unavailable"
    case coreUnavailable = "core_unavailable"
    case coreFailure = "core_failure"
    case invalidResponse = "invalid_response"
    case tunnelUnavailable = "tunnel_unavailable"
    case timeout
    case cancelled
    case internalError = "internal_error"

    public var code: String { rawValue }
    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .invalidArguments: return "The provider or Keychain identifiers are invalid."
        case .invalidConfiguration: return "The tunnel configuration is invalid."
        case .invalidProfile: return "The owned VPN profile has invalid metadata."
        case .profileConflict: return "The provider has an ambiguous or differently owned VPN profile."
        case .keychainFailure: return "The shared Keychain configuration could not be accessed."
        case .preferencesFailure: return "VPN preferences could not be updated or loaded."
        case .tunnelStartFailed: return "The system could not start the VPN tunnel."
        case .providerUnavailable: return "The tunnel provider is unavailable."
        case .coreUnavailable: return "A compatible tunnel core must be supplied by the extension."
        case .coreFailure: return "The tunnel core could not complete the operation."
        case .invalidResponse: return "The tunnel provider returned an invalid response."
        case .tunnelUnavailable: return "The tunnel's own network interface could not be identified."
        case .timeout: return "The tunnel operation timed out."
        case .cancelled: return "The tunnel operation was cancelled."
        case .internalError: return "The tunnel operation could not be completed."
        }
    }

    public static func redacted(_ error: Error) -> WGCNEError {
        if let safe = error as? WGCNEError { return safe }
        if error is CancellationError { return .cancelled }
        return .internalError
    }
}

internal enum WGCContract {
    static let maximumJSONBytes = 128 * 1024
    static let keychainService = "dev.idy.wgc_ne.configuration"
    static let referenceKey = "configurationReference"
    static let accessGroupKey = "keychainAccessGroup"
    static let ownerKey = "ownerBundleIdentifier"

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 46 || $0 == 45 || $0 == 95
        }
    }

    static func configurationData(_ json: String) throws -> Data {
        let data = Data(json.utf8)
        guard !data.isEmpty, data.count <= maximumJSONBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
              version.doubleValue == 1,
              let key = object["private_key"] as? String,
              let keyData = Data(base64Encoded: key), keyData.count == 32,
              keyData.base64EncodedString() == key,
              let addresses = object["addresses"] as? [String], !addresses.isEmpty,
              let peers = object["peers"] as? [[String: Any]], !peers.isEmpty else {
            throw WGCNEError.invalidConfiguration
        }
        return data
    }
}
