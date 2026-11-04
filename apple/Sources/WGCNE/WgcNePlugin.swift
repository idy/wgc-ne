#if canImport(Flutter)
import Flutter
#elseif canImport(FlutterMacOS)
import FlutterMacOS
#endif

#if canImport(Flutter) || canImport(FlutterMacOS)
import Foundation

/// The CocoaPods targets compile these same SDK sources. The extension links only
/// the Swift package and its Go adapter, so no Flutter dependency enters the provider.
public final class WgcNePlugin: NSObject, FlutterPlugin {
    @MainActor private lazy var client = WGCNEClient()
    @MainActor private var calls: [UUID: Task<Void, Never>] = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        #if os(macOS)
        let messenger = registrar.messenger
        #else
        let messenger = registrar.messenger()
        #endif
        let channel = FlutterMethodChannel(name: "dev.idy.wgc_ne/methods", binaryMessenger: messenger)
        registrar.addMethodCallDelegate(WgcNePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard ["start", "stop", "status", "removeProfile"].contains(call.method) else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard let arguments = call.arguments as? [String: Any],
              let provider = arguments["providerBundleIdentifier"] as? String,
              WGCContract.validIdentifier(provider) else {
            result(Self.flutterError(.invalidArguments))
            return
        }
        Task { @MainActor in
            let id = UUID()
            let task = Task { @MainActor in
                defer { self.calls.removeValue(forKey: id) }
                do {
                    let status: WGCStatus
                    switch call.method {
                    case "start":
                        guard let group = arguments["keychainAccessGroup"] as? String,
                              let configuration = arguments["configuration"] as? String,
                              arguments["localizedDescription"] == nil || arguments["localizedDescription"] is String else {
                            throw WGCNEError.invalidArguments
                        }
                        status = try await self.client.start(
                            providerBundleIdentifier: provider, keychainAccessGroup: group,
                            configurationJSON: configuration,
                            localizedDescription: arguments["localizedDescription"] as? String)
                    case "stop": status = try await self.client.stop(providerBundleIdentifier: provider)
                    case "removeProfile": status = try await self.client.removeProfile(providerBundleIdentifier: provider)
                    default: status = try await self.client.status(providerBundleIdentifier: provider)
                    }
                    result(status.dictionary)
                } catch { result(Self.flutterError(WGCNEError.redacted(error))) }
            }
            self.calls[id] = task
        }
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        Task { @MainActor in
            calls.values.forEach { $0.cancel() }
            calls.removeAll()
        }
    }

    private static func flutterError(_ error: WGCNEError) -> FlutterError {
        FlutterError(code: error.code, message: error.message, details: nil)
    }
}
#endif
