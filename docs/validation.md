# Validation

## Version 0.2.0

Local verification on November 4, 2026, on Apple silicon with Go 1.27.3,
Flutter 3.47.2, Dart 3.13.2, Xcode 27.1, JDK 17, Android SDK 36, and
NDK 28.2.13676358:

| Check | Result |
| --- | --- |
| Go tests with `with_gvisor`, race detector, and `go vet` | Passed |
| Protected TCP/UDP/listener sockets and descriptor ownership | Passed with synthetic callbacks and loopback sockets |
| JNI callback exceptions, thread attachment, reference/FD ownership | Passed with the actual C bridge and a fake VM under ASan/UBSan |
| Android consent, canonical CIDR routes, redaction, service cancellation/revoke/health | Passed; 36 JVM tests, including binding cancellation, foreground ordering, loopback routing, and API 23 lifecycle coverage |
| Flutter analysis and 36 Dart tests | Passed, including constructor parity and fail-fast Android toolchain preflight |
| ELF/ZIP checker regression tests | Passed; 11 tests covering bounded reads, alignment, truncation, and CRC corruption |
| Swift SDK build and 54 lifecycle/storage/network-settings tests | Passed |
| iOS setup regression tests and canonical native sources | Passed; 11 setup tests |
| Custom-transport Android core, arm64-v8a, x86_64, and optional armeabi-v7a | Built; ELF `LOAD` segments aligned to 16 KiB |
| Custom-transport Apple core, iOS arm64 | Built |
| Android Release example APK with arm64-v8a and x86_64 cores | Built with the example debug signing key; all six native libraries pass ELF/ZIP 16 KiB checks |

Android builds import `example/counter/register`; the wrapper changes no packet
bytes. Android service/consent tests and APK packaging checks are described in
[the integration guide](android-integration.md). Neither host JNI tests nor
native-library compilation establish real Android VPN forwarding.

## Earlier Apple preview verification

The earlier Apple preview was also checked on November 4, 2026, with the same
Go/Flutter/Xcode versions. These additional build/UI results are retained as
historical evidence, not a repeat of every check for the Android addition:

| Check | Result |
| --- | --- |
| Go tests with `with_gvisor` and race detector | Passed |
| WGC-to-WGC TCP/UDP, TCP half-close, custom transport and shutdown | Passed |
| Standard wireguard-go peer UDP/IP round trip | Passed |
| Transport admission/registration, invalid configuration, descriptor cleanup | Passed |
| Flutter analysis and 24 Dart tests | Passed |
| Swift SDK build and 54 actor-checked lifecycle/storage/network-settings tests | Passed |
| iOS setup regression tests and shared native source checks | Passed; 11 setup tests |
| Default core Apple builds | Passed for all five slices |
| Custom-transport core Apple build | Passed for iOS arm64 |
| Native C ABI validation and invalid-start descriptor ownership | Passed |
| Flutter iOS Release example with embedded provider | Built without signing |
| Project page desktop/mobile, light/dark and transport/stage controls | Passed in Chromium |
| Homepage project entry, links, responsive layout and theme toggle | Passed in Chromium |

Apple core slices are iOS arm64, iOS Simulator arm64/x86_64, and macOS
arm64/x86_64. The custom build imports `example/counter/register`; the wrapper
only counts bytes and does not alter packets. Go packet tests use synthetic
keys, loopback UDP, and userspace IP stacks without modifying host routes.
The interoperability server uses the unmodified WireGuard protocol implementation
in the pinned SagerNet wireguard-go dependency, not a second WGC instance.

The core pins WGC `v0.2.1-0.20261103184829-50549511c059`, which includes upstream
handshake, session, queue, and statistics synchronization fixes. Optional WGC peer
statistics remain disabled to avoid duplicate accounting; SDK counters use
independent atomic totals at the selected transport boundary.

This WGC revision still does not retain application datagrams that trigger an
initial handshake. The stock-peer interoperability test retries UDP, so it does not
establish first-datagram delivery. A cold session's first UDP DNS exchange can
therefore time out even after the handshake succeeds; this remains a limitation
of the pinned dependency.

## Not established by these checks

- This standalone plugin has not completed signed physical-device VPN forwarding,
  background/reconnect, or App Store acceptance testing.
- Simulator or unsigned App builds do not establish system VPN functionality.
- macOS System Extension installation and privileged-helper migration are not
  implemented by this SDK. The host owns packaging and entitlements.
- No production service, real user identity, private transport, or application
  account backend was used for the public project's tests.
- The Dart 3.3 / Flutter 3.19 minimum was checked against dependency constraints
  and API usage, but no consumer build was run with that older toolchain.

The Flutter native bridge currently uses CocoaPods. Native applications and the
PacketTunnel target can consume the separate WGCNE Swift package directly.
