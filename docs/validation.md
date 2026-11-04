# Validation

Local verification on November 4, 2026, using Go 1.27.3, Flutter 3.47.2,
Dart 3.13.2, and Xcode 27.1 on Apple silicon:

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

WGC v0.2.0's optional receive-statistics counters can race under its concurrent
receive workers. This core disables those optional counters and uses independent
atomic totals at the selected transport boundary. Repeated race-enabled transport
round trips passed with that configuration.

WGC v0.2.0 does not retain application datagrams that trigger an initial
handshake. The stock-peer interoperability test retries UDP, so it does not
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
