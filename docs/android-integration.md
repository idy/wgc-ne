# Android integration

WGC NE runs the shared Go core inside an app-owned Android `VpnService`. Flutter
controls consent, start/stop, and status over the existing method channel. Packets
stay in the native service and Go runtime. The service can outlive the Activity
and Flutter engine, and stops on system VPN revocation or terminal core failure.

The platform follows the `VpnService` / JNI / Go integration pattern used by
[letsolo](https://github.com/idy/letsolo), with its own lifecycle and configuration
implementation. It does not import letsolo's application policy or service code.

## Requirements

- Android 6.0 / API 23 or newer; compile SDK 36 and JDK 17.
- Go 1.26+ and Android NDK r28 or newer, on macOS or Linux, to build the core.
  The default NDK location is `ANDROID_HOME/ndk/28.2.13676358`.
- A host minimum SDK compatible with its Flutter version. The native plugin
  supports API 23; the example follows Flutter 3.47's API 24 minimum.
- A visible Flutter Activity when starting a tunnel, so Android can present VPN
  consent and permit foreground-service startup.
- A real WGC/WireGuard peer and your own valid configuration. This SDK supplies
  neither credentials nor a service backend.

The default core build contains `arm64-v8a` and `x86_64`. Use `--android-abis`
with a comma-separated subset of `arm64-v8a,armeabi-v7a,x86_64` to change this.
The host app's ABI filters must match the libraries it ships. `armeabi-v7a` is an
optional build target; the example packages only the two default ABIs.

## Build and package the core

From a consuming Flutter application, build directly into its Android app's
native-library directory:

```bash
dart run wgc_ne:build_core --platform android --ndk /path/to/android-ndk --output android/app/src/main/jniLibs
```

The builder compiles `with_gvisor`, produces one `libwgcne.so` per ABI, and stores
build metadata and license files beside them. It supports the same `--config`
transport-extension imports as Apple builds. Android builds do not need Xcode or
`gomobile`. Existing output is protected; `--force` replaces only output marked
as a previous WGC NE build.

For the repository example, run from the repository root:

```bash
dart run wgc_ne:build_core --platform android --config example/wgc_ne.core.yaml --output example/android/app/src/main/jniLibs
```

Then run `flutter pub get` and `flutter build apk --release --target-platform
android-arm64,android-x64` in `example/`. APK compilation does not establish VPN
forwarding on a device.

Alternatively, keep the default `build/android/jniLibs` artifact and set
`wgcNeCoreDirectory=/absolute/path/to/build/android/jniLibs` in the host's
`android/gradle.properties`; the plugin adds that directory as a JNI library
source. Do not package two different copies of `libwgcne.so` for the same ABI.
Include the generated legal notices in your application's notices/source
redistribution; Gradle's JNI source set packages `.so` files, not those documents.

NDK r28+ and the builder's linker flags provide 16 KiB ELF segment alignment.
Use Android Gradle Plugin 8.5.1 or newer for aligned uncompressed APK libraries.
The example uses AGP 8.13.2. Validate both ELF and APK alignment before distribution:

```bash
python3 -I tool/check_android_artifacts.py --jni-libs example/android/app/src/main/jniLibs --apk example/build/app/outputs/flutter-apk/app-release.apk
```

## Flutter API

```dart
final tunnel = WgcNe.android(localizedDescription: 'My VPN');
final configuration = WgcConfiguration.fromJsonString(profileJsonFromSecureSource);
await tunnel.start(configuration); // waits for consent and local core startup
final status = await tunnel.status();
await tunnel.stop();
await tunnel.dispose();
```

Use `WgcNe.android` on Android and the existing Apple constructor on iOS/macOS.
Android needs no provider bundle identifier or Keychain access group. Consent
rejection reports `WgcErrorCode.permissionDenied`. Plugin activity attachment and
result handling are automatic; do not override `MainActivity.onActivityResult`
to start the tunnel yourself.

There is one tunnel per application. Conflicting starts fail with
`profile_conflict`. Stop during native startup cancels publication of a late
handle and closes it before releasing the service's TUN descriptor. Native calls
run on a serialized worker; status returns a public snapshot refreshed by the
service's own health polling. `connected` describes local startup, not remote
reachability. Disposing a Dart client releases that client's polling and pending
calls; stop the tunnel explicitly to disconnect the service.

## Service, permissions, and storage

The plugin manifest merges `INTERNET`, `FOREGROUND_SERVICE`, and
`FOREGROUND_SERVICE_SYSTEM_EXEMPTED`, and a `BIND_VPN_SERVICE`-protected service
with the `systemExempted` foreground-service type. Consent is obtained before the
service becomes foreground. It creates a low-importance notification channel,
shows a persistent notification with a disconnect action, and opens the host
application when the notification is tapped. Hosts can override `wgc_ne_*` string
resources for localization.

Android 13+ allows VPN foreground services to run without `POST_NOTIFICATIONS`.
If the host wants normal notification-drawer visibility when that permission has
not been granted, it should declare/request it as part of its own notification
UX; the plugin does not add another permission dialog.

Configuration is kept in process memory, never in service Intent extras,
SharedPreferences, logs, status, or saved instance state. The service returns
`START_NOT_STICKY` and disables always-on VPN support. Process death disconnects
it and requires an explicit new start. The host owns any secure persistence.
`removeProfile()` stops the memory-only session; it does not revoke Android's VPN
consent, which the user manages in system Settings.

## Routing and custom transports

The shared validated settings provide tunnel addresses, MTU, DNS, included routes,
and excluded routes, including peer endpoint host routes. Exclusions are
subtracted from included prefixes before installing routes, including on Android
versions before API 33. Explicit empty includes install no routes. Configurations
whose subtraction produces more than 8,192 routes are rejected.

Native sockets are protected through `VpnService.protect(fd)` before bind/connect.
Protection failure fails the operation. Both the WGC UDP transport and sing-box
socket dialers use it. Custom Go factories must use the socket control helpers
from [the transport guide](transports.md#android-socket-protection) for every
socket they create, including sockets created after startup.

The service uses Android's default underlying network (`setUnderlyingNetworks(null)`)
and does not pin Wi-Fi/cellular interfaces or implement a separate handover policy.
Peer endpoint exclusions alone are insufficient for arbitrary custom relay
endpoints; socket protection is required. The SDK does not promise seamless
network switching, always-on/lockdown operation, automatic process recovery, or
raw ICMP forwarding. Device forwarding and background/network-change acceptance
remain separate from build and local lifecycle checks.
