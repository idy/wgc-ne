import Darwin
import Foundation
import WGCNE
import WGCCore

/// Compile this file in the PacketTunnel extension alongside WGCCore.xcframework.
/// The WGCNE Swift package deliberately does not compile or link this adapter.
public final class WGCCoreEngine: CoreEngine {
    private let lock = NSLock()
    private var handle: UInt64?
    private static let maximumJSONBytes = 128 * 1024

    public init() throws {
        guard WGCNEABIVersion() == 1 else { throw WGCNEError.coreUnavailable }
    }

    deinit { stop() }

    public func validate(configuration: Data) throws -> WGCNetworkSettings {
        guard !configuration.isEmpty, configuration.count <= Self.maximumJSONBytes else {
            throw WGCNEError.invalidConfiguration
        }
        lock.lock()
        defer { lock.unlock() }
        let response = configuration.withUnsafeBytes { bytes in
            WGCNEValidate(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(bytes.count))
        }
        return try WGCABIEnvelope<WGCNetworkSettings>.decode(takeResponse(response))
    }

    public func start(ownedFileDescriptor: Int32, configuration: Data) throws {
        // The Swift side owns the descriptor until the ABI is actually invoked.
        guard ownedFileDescriptor >= 0, !configuration.isEmpty,
              configuration.count <= Self.maximumJSONBytes else {
            if ownedFileDescriptor >= 0 { close(ownedFileDescriptor) }
            throw WGCNEError.invalidConfiguration
        }
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else { close(ownedFileDescriptor); throw WGCNEError.coreFailure }
        let response = configuration.withUnsafeBytes { bytes in
            // WGCNEStart ALWAYS owns the descriptor from this point onward.
            WGCNEStart(ownedFileDescriptor, bytes.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(bytes.count))
        }
        let started = try WGCABIEnvelope<StartResult>.decode(takeResponse(response))
        guard started.handle != 0 else { throw WGCNEError.invalidResponse }
        handle = started.handle
    }

    public func status() throws -> WGCCoreStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return try WGCCoreStatus(state: "stopped") }
        return try WGCABIEnvelope<WGCCoreStatus>.decode(takeResponse(WGCNEStatus(handle)))
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        self.handle = nil
        WGCNEStop(handle)
    }

    private struct StartResult: Decodable { let handle: UInt64 }

    private func takeResponse(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let pointer else { throw WGCNEError.coreFailure }
        defer { WGCNEFree(pointer) }
        let length = strnlen(pointer, Self.maximumJSONBytes + 1)
        guard length > 0, length <= Self.maximumJSONBytes else { throw WGCNEError.invalidResponse }
        return Data(bytes: pointer, count: length)
    }
}
