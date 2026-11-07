# Apple integration

WGC NE provides a native Swift package and a Flutter control plugin. The host
application must supply its own embedded PacketTunnel target and signing setup.
The same SDK sources can serve Flutter or a native Swift app.

## Prerequisites

- macOS with Xcode, Go 1.26+, and Flutter/Dart for Flutter hosts.
- iOS 15+ or macOS 12+ deployment targets for the native SDK.
- App and extension identifiers owned by the same development team. The extension
  identifier must start with the containing app identifier and a dot.
- Packet Tunnel Network Extension capability and a shared Keychain access group
  on both targets. Preserve an existing product's identity and data when adopting
  the plugin; do not uninstall it as a migration strategy.

The macOS SDK does not install a System Extension or privileged helper. A macOS
host must choose and provision its supported Network Extension packaging. App
Store acceptance and entitlement approval are outside the SDK's build result.

## Add an extension

For an existing Flutter iOS project, the explicit setup helper adds the target,
links the core and native SDK, and merges the required entitlements:

```bash
dart run wgc_ne:setup_ios --project ios/Runner.xcodeproj --core build/WGCCore.xcframework
```

It preserves a backup and refuses an existing target/provider folder. It does not
choose a development team, register identifiers, or sign an application. By
default it references the WGCNE Swift package at version 0.2.2; `--sdk` selects a
local checkout during development. Inspect the generated project changes and
finish provisioning in Xcode. The helper requires Python 3.9+, `plutil`, and
Xcode's `xcodebuild`. It reads Runner's effective settings for every configuration,
merges the entitlement file selected by Xcode, and derives each default provider
identifier from that configuration's app identifier. An explicit `--provider-id`
must belong to every containing-app configuration. The default shared Keychain
group uses the Release app identifier (or the first configuration if Release is
absent); `--keychain-group` selects a different shared suffix.

For manual integration, create a Network Extension target in Xcode using the Packet Tunnel Provider
extension type. Embed it in the app. Add the WGCNE Swift package from this repo to
the extension target; a Flutter host uses the plugin in its containing app.
Do not start Flutter inside the provider.

Build and link your core:

```bash
dart run wgc_ne:build_core --platform ios --output build/WGCCore.xcframework
```

Add the generated XCFramework to the extension target as a linked static library
(do not embed the static library as a dynamic framework). Add
`apple/GoAdapter/WGCCoreEngine.swift` to the extension's sources. The C module
`WGCCore` is provided by the generated framework's headers/module map.

Link Foundation, Security, CoreFoundation, and libresolv. iOS also needs UIKit for
the upstream core's platform support. A shared native package does not imply a
shared installed provider: each application signs its own extension.

The provider subclass injects `WGCCoreEngine` into the generic Swift provider.
The extension's `NSExtensionPrincipalClass` must name that subclass. The example
integration and generated template use the exact SDK API.

## Protect configuration

Give both targets the same explicit Keychain access group, such as the resolved
`TEAMID.com.example.app.wgc-ne`. Xcode entitlements can use
`$(AppIdentifierPrefix)com.example.app.wgc-ne`; the runtime API needs its resolved
value. This is a Keychain access group, not an App Group container identifier.

The SDK stores configuration as `AfterFirstUnlockThisDeviceOnly` Keychain data.
Only an opaque profile reference, access-group name, and ownership marker are
stored in VPN preferences. Do not replace this with a plaintext private key in
`providerConfiguration`, Dart logs, UserDefaults, or crash reports.

An App Group is not required by this storage/IPC design. If the consuming app
adds shared files, it is responsible for the corresponding container entitlement,
permissions, and file protection.

## Lifecycle

The containing app requests VPN permission and starts its owned manager. The
provider retrieves configuration, calls the core's validation API, applies the
returned IPv4/IPv6/DNS routes, locates its own utun, and transfers a duplicate of
that descriptor to Go. Start owns that duplicate even when it fails.

The core returns a handle only after startup succeeds. Stop closes the core
before network settings are removed. Provider IPC exposes redacted status and
counters. Startup errors must remain errors; an elapsed timer or a stored
preference is not evidence of a connected VPN.

A default full-tunnel configuration requires real peer credentials and compatible
server routing/allowed-address configuration. Test device behavior on an actual
signed extension; Simulator host UI and standalone Swift tests cannot establish
system VPN forwarding or background operation.
