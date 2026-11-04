import Foundation

/// Implementations consume ownedFileDescriptor on EVERY path, including thrown errors.
/// Calls are serialized on the provider's worker queue; they must return in bounded time.
/// Go adapters live outside this package so the SDK never requires a generated binary.
public protocol CoreEngine: AnyObject {
    func validate(configuration: Data) throws -> WGCNetworkSettings
    func start(ownedFileDescriptor: Int32, configuration: Data) throws
    func status() throws -> WGCCoreStatus
    func stop()
}

public struct WGCCoreStatus: Codable, Equatable, Sendable {
    public let state: String
    public let publicKey: String?
    public let bytesSent: UInt64
    public let bytesReceived: UInt64
    public let packetsSent: UInt64
    public let packetsReceived: UInt64
    public let coreVersion: String?

    enum CodingKeys: String, CodingKey {
        case state, publicKey = "public_key", bytesSent = "bytes_sent"
        case bytesReceived = "bytes_received", packetsSent = "packets_sent"
        case packetsReceived = "packets_received", coreVersion = "core_version"
    }

    public init(state: String, publicKey: String? = nil, bytesSent: UInt64 = 0,
                bytesReceived: UInt64 = 0, packetsSent: UInt64 = 0,
                packetsReceived: UInt64 = 0, coreVersion: String? = nil) throws {
        guard ["running", "stopped"].contains(state),
              [bytesSent, bytesReceived, packetsSent, packetsReceived].allSatisfy({ $0 <= UInt64(Int64.max) }),
              coreVersion.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true else {
            throw WGCNEError.invalidResponse
        }
        if let publicKey {
            guard let bytes = Data(base64Encoded: publicKey), bytes.count == 32,
                  bytes.base64EncodedString() == publicKey else { throw WGCNEError.invalidResponse }
        }
        self.state = state
        self.publicKey = publicKey
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.packetsSent = packetsSent
        self.packetsReceived = packetsReceived
        self.coreVersion = coreVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            state: values.decode(String.self, forKey: .state),
            publicKey: values.decodeIfPresent(String.self, forKey: .publicKey),
            bytesSent: values.decodeIfPresent(UInt64.self, forKey: .bytesSent) ?? 0,
            bytesReceived: values.decodeIfPresent(UInt64.self, forKey: .bytesReceived) ?? 0,
            packetsSent: values.decodeIfPresent(UInt64.self, forKey: .packetsSent) ?? 0,
            packetsReceived: values.decodeIfPresent(UInt64.self, forKey: .packetsReceived) ?? 0,
            coreVersion: values.decodeIfPresent(String.self, forKey: .coreVersion)
        )
    }

    public var dictionary: [String: Any] {
        var result: [String: Any] = [
            "state": state, "bytes_sent": bytesSent, "bytes_received": bytesReceived,
            "packets_sent": packetsSent, "packets_received": packetsReceived
        ]
        if let publicKey { result["public_key"] = publicKey }
        if let coreVersion { result["core_version"] = coreVersion }
        return result
    }
}

public struct WGCABIEnvelope<Value: Decodable>: Decodable {
    public let ok: Bool
    public let result: Value?

    public static func decode(_ data: Data) throws -> Value {
        guard !data.isEmpty, data.count <= WGCContract.maximumJSONBytes else {
            throw WGCNEError.invalidResponse
        }
        do {
            let envelope = try JSONDecoder().decode(Self.self, from: data)
            guard envelope.ok else { throw WGCNEError.coreFailure }
            guard let result = envelope.result else { throw WGCNEError.invalidResponse }
            return result
        } catch let error as WGCNEError { throw error }
        catch { throw WGCNEError.invalidResponse }
    }
}

public enum WGCConnectionState: String, Codable, Sendable {
    case disconnected, connecting, connected, disconnecting, reasserting, invalid
}

public struct WGCStatus: Equatable, Sendable {
    public let state: WGCConnectionState
    public let core: WGCCoreStatus?

    public init(state: WGCConnectionState, core: WGCCoreStatus? = nil) {
        self.state = state
        self.core = core
    }

    public var dictionary: [String: Any] {
        var value: [String: Any] = ["state": state.rawValue]
        if let core { value["core"] = core.dictionary }
        return value
    }
}
