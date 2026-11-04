# Example app

This is a small Flutter consumer, with an embedded iOS PacketTunnel target using
the same WGCNE Swift SDK and generated Go core. It contains no usable service
credentials and does not simulate a successful connection.

From the repository root, fetch dependencies and build the native core:

```bash
flutter pub get
```

```bash
dart run wgc_ne:build_core --platform ios --output build/WGCCore.xcframework
```

Then run `flutter pub get` in `example/`. An unsigned compilation check is:

```bash
flutter build ios --release --no-codesign
```

The checked-in provider identifier is
`dev.idy.wgcne.wgcNeExample.PacketTunnel`. The shared Keychain group is the actual
App Identifier Prefix followed by `dev.idy.wgcne.wgcNeExample.wgc-ne`.
Set your own development team, identifiers, entitlements and provisioning on both
Runner and WGCPacketTunnel before installing on a physical device. Enter the
resolved provider/group identifiers and your own test configuration in the UI.

The app can start/stop a profile and display system/core status. Removing a
profile is a separate explicit action. A connected provider does not by itself
prove a reachable peer or working internet forwarding.

To exercise a compiled custom transport, build with
`--config example/wgc_ne.core.yaml` from the repository root and select
`{"type":"counter"}` in the configuration. That wrapper is transparent and
only counts bytes.

See [Apple integration](../docs/apple-integration.md) and
[validation limits](../docs/validation.md). Simulator or unsigned compilation is
not a physical VPN acceptance test.
