# WGC NE

A Flutter plugin and native Android/Apple SDK for applications that want
WireGuard sessions with an application-owned transport. The Flutter plugin
supports Android 6.0+ (API 23), iOS, and macOS.

[Project page](https://wgc-ne.idy.dev/) · [Android integration](docs/android-integration.md) ·
[Apple integration](docs/apple-integration.md) · [Custom transports](docs/transports.md) ·
[Architecture and ABI](docs/architecture.md)

WGC NE uses [WGC](https://github.com/idy/wgc) for peer admission, WireGuard
handshakes, encryption, and replay protection. sing-box handles TUN flows,
userspace TCP/UDP, DNS, and routing. The default transport is standard UDP.
Applications can compile their own transport factories or wrappers into the
native core and select them from Flutter configuration.

This is a preview SDK, not a VPN service or an official WireGuard/sing-box app.
It contains no account backend, subscription system, private transport algorithm,
or service-specific node list.

## How it fits

```text
Your Flutter app                  Your native Apple app
       │                                  │
       └────────── WGC NE Apple SDK ──────┘
                         │ lifecycle / status IPC
                Your PacketTunnel extension
                         │
                  sing-box IP flows
                         │
                    WGC sessions
                         │
              UDP or your compiled transport
```

The extension runs Swift and Go, without a Flutter engine. Every app embeds and
signs its own extension. Shared code does not mean sharing another app's running
provider, signing identity, or Keychain data.

On Android, the same core runs in the application's foreground `VpnService`.
The plugin handles VPN consent; JNI transfers a service-owned TUN descriptor
and protects native sockets from routing back through the VPN. Configuration
stays in memory, and process death requires an explicit reconnect.

## Get started

Use the repository as a Flutter Git dependency. A pub.dev publication is not
required or implied by the GitHub release.

```yaml
dependencies:
  wgc_ne:
    git:
      url: https://github.com/idy/wgc-ne.git
      ref: v0.2.0
```

For Android, build with Go 1.26+ and NDK r28+ on macOS or Linux:

```bash
dart run wgc_ne:build_core --platform android --output android/app/src/main/jniLibs
```

Set `ANDROID_HOME` with NDK `28.2.13676358` installed, or pass `--ndk`. Start with
`WgcNe.android(localizedDescription: 'My VPN')`; the remaining Dart operations
match the Apple API. Follow [Android integration](docs/android-integration.md)
for packaging, permissions, and custom socket protection.

For Apple, build a core on macOS with Xcode and Go 1.26 or newer:

```bash
dart run wgc_ne:build_core --platform ios --output build/WGCCore.xcframework
```

Use `--platform macos` or `--platform all` for other Apple slices. `--device-only`
builds just iOS arm64 for faster development. Existing output is protected; use
`--force` only to replace a previous WGC NE build.

Follow the [Apple integration guide](docs/apple-integration.md) to add the
PacketTunnel target, shared Keychain entitlement, and generated core. Adding the
Dart dependency alone cannot provision an Apple extension.

The Flutter native bridge currently uses CocoaPods. The separate WGCNE Swift
package is used directly by the extension and native Apple apps.

The Dart API controls one provider:

```dart
final tunnel = WgcNe(
  providerBundleIdentifier: 'com.example.app.PacketTunnel',
  keychainAccessGroup: 'TEAMID.com.example.app.wgc-ne',
);
final configuration = WgcConfiguration.fromJsonString(profileJsonFromSecureSource);
await tunnel.start(configuration);
final status = await tunnel.status();
await tunnel.stop();
await tunnel.dispose();
```

Use `tunnel.statuses` for subscription-scoped status updates. `connected` means
the native provider/service and local core started; it does not prove a remote peer is
reachable or that the internet is working. Never log configuration JSON.

The [example app](example/) is a small consumer for your own synthetic/test
configuration. It does not contain a working service key or pretend to connect.

## Transport injection

A custom implementation stays in the consuming project's Go module. Register it
with `core/transport.RegisterFactory` or `RegisterWrapper`, list its package in
`wgc_ne.core.yaml`, and build that core:

```bash
dart run wgc_ne:build_core --platform ios --config wgc_ne.core.yaml
```

The selected transport is created **inside the native tunnel runtime**. Dart sends
only the registered name and JSON options; it is not a per-packet callback.
Unknown registrations fail instead of falling back to UDP. The included
[counter wrapper example](example/counter/register/register.go) demonstrates
injection without changing packet bytes.

See [the full transport guide](docs/transports.md) for ownership, pinning,
composition, and distribution requirements. A datagram transport operates on
encrypted WireGuard messages; an application's extra plaintext payload protocol
is a separate native adapter.

## Configuration

[Configuration v1](docs/architecture.md#configuration-version-1) declares the
private key, inner addresses, peer keys/numeric endpoints, transport, and system
network settings. The inner addresses must match the remote server's allowed
addresses. The default routes TCP/UDP and DNS through one selected WGC peer.

Optional custom sing-box JSON supports the registered TUN, direct, WGC, UDP/TCP
DNS, and FakeIP components. This is not a bundle of every sing-box protocol.
The native platform owns the OS routes; sing-box automatic route installation is
rejected. Raw ICMP forwarding is not provided by the userspace WGC outbound.

On Apple, configuration is stored in a device-only shared Keychain item and
NetworkExtension preferences hold only a reference. On Android, it stays in
service memory without automatic process recovery. Status exposes public identity
and counters only. The host application remains responsible for peer trust,
account authorization, configuration provenance, and key lifecycle.

## Development

```bash
go -C core test -tags with_gvisor -race ./...
```

```bash
flutter analyze
```

```bash
flutter test
```

```bash
swift test
```

Go tests create local encrypted peers and userspace TCP/UDP endpoints. They do
not change your host's routes. [Contributing](CONTRIBUTING.md) also covers the iOS
setup regression tests and native source checks. Signed device and
production-network acceptance are separate from these checks; see
[validation](docs/validation.md).

## Website development

The static project page is in `site/`, with no build step or package dependencies.
From the repository root, preview it with `python3 -m http.server 8080 --directory site`.
`index.html` is readable in English without JavaScript; `script.js` provides Chinese
translations, the interactive architecture diagram, copy feedback, and live
release downloads. `styles.css` defines the layout and light/dark color tokens.

`site/shared/` contains the common idy.dev header/footer styles, preference and
release helpers, and locally hosted fonts with their licenses. The compact header
and page use Montserrat for headings, Monda for body text, Lato for notes, and Phosphor
icons; Manrope remains a fallback. Keep shared files identical across the idy.dev
sites. Language follows the browser and
theme follows the system until a visitor saves a manual choice in the header.
The public GitHub Releases API selects the latest stable release, or the newest
published preview when no stable release exists. XCFramework and checksum links
use uploaded assets' `browser_download_url` values; missing assets are not offered.
API failures leave a working Releases link with no pinned latest version. Check
both languages, manual and system themes, 375px layouts, diagram and copy controls,
and release failure/missing-asset states when changing the website.

## License

GPL-3.0-or-later. WGC retains its MIT license; sing-box and other dependencies
retain their own terms and notices. See [LICENSE](LICENSE), [NOTICE](NOTICE), and
[third-party notices](THIRD_PARTY_NOTICES.md). Linking a private transport into a
distributed GPL core does not waive corresponding-source obligations.
