# WGC NE architecture

WGC NE is an independent Flutter plugin and Apple Network Extension SDK. Its Go
core uses `github.com/idy/wgc` v0.2.0 for authenticated WireGuard packets and
sing-box v1.14.4 for userspace TCP/UDP, TUN flow handling, DNS, and routing.
It is not an official WireGuard or sing-box application.

## Boundaries

- The containing application owns its UI, account/API integrations, and policy.
- The Flutter plugin controls an owned `NETunnelProviderManager` through native
  code and reads status/statistics through provider messages.
- Each containing app embeds and signs its own PacketTunnel extension. Applications
  share source and the ABI, not an installed provider or VPN identity.
- The provider runs Swift and Go, without a Flutter engine.
- Configuration is stored as a device-only Keychain item in a caller-supplied
  shared Keychain access group. Preferences contain only the profile reference,
  access-group name, and owning app identifier. Both targets need the matching
  Keychain entitlement. No private keys or full configuration go into logs,
  status responses, or `NETunnelProviderProtocol.providerConfiguration`.
- The SDK includes only standard UDP. Custom Go transport factories/wrappers are
  compiled into the extension's core; Flutter chooses the registered name and
  supplies JSON options. Unknown names fail closed.
- App-specific authentication, relaying, framing/obfuscation, DNS pins, service
  domains, and credentials do not belong in this public repository.

## Configuration version 1

```json
{
  "version": 1,
  "private_key": "<canonical Base64 X25519 private key>",
  "addresses": ["10.7.0.2/32"],
  "peers": [{
    "id": "exit",
    "public_key": "<canonical Base64 X25519 public key>",
    "endpoint": "203.0.113.10:51820"
  }],
  "default_peer": "exit",
  "transport": {"type": "udp", "options": {}},
  "mtu": 1280,
  "dns_server": "1.1.1.1:53",
  "network": {
    "dns_servers": ["198.18.0.2"],
    "included_routes": ["0.0.0.0/0"],
    "excluded_routes": []
  }
}
```

`version`, `private_key`, `addresses`, and `peers` are required. Defaults:
`default_peer` is the first peer, `transport` is UDP, MTU is 1280, tunnel DNS is
`198.18.0.2`, upstream DNS is `1.1.1.1:53`, and included routes cover the address
families in `addresses`. Numeric, unzoned endpoints and resolvers only. Peers'
outer endpoint host routes are added to exclusions. An explicit empty
`network.included_routes` list installs no included routes; only an omitted or
null list selects the defaults. Each input route list accepts at most 1,024
entries. Derived exclusions can contain up to 1,056 entries after adding host
routes for the 32 supported peers. The configured inner source addresses must be
allowed by the remote WireGuard server.

Optional `sing_box` replaces the generated sing-box configuration. The supported
built-in registrations are TUN, direct, WGC, UDP/TCP DNS, and FakeIP DNS. Exactly
one TUN inbound is required and its addresses/MTU must match the outer settings;
auto route installation is disabled because NetworkExtension owns it. A WGC
outbound uses `{"type":"wgc","tag":"vpn","peer":"exit","resolver":"dns-remote"}`.
Custom sing-box configuration does not grant access to undeclared WGC peers.
The generated TUN uses the gVisor stack, which accepts host prefixes such as
`/32` and `/128`. A custom mixed or system stack needs a successor address inside
the first prefix of each configured address family; offline validation rejects
prefixes that cannot satisfy that requirement.

The default policy sends TUN TCP/UDP and DNS through the selected peer. It does
not bundle product-specific routing lists, accounts, subscriptions, or service
endpoints. It does not claim raw ICMP forwarding through the userspace outbound.

## Native core ABI v1

All JSON is UTF-8 with explicit lengths, maximum 128 KiB. Returned strings use
`{"ok":true,"result":...}` or a redacted error envelope. Free every returned
string with `WGCNEFree`. No Go pointers or packet callbacks cross the ABI.

```c
int32_t WGCNEABIVersion(void);
char *WGCNEValidate(const char *config, int32_t length);
char *WGCNEStart(int32_t owned_fd, const char *config, int32_t length);
char *WGCNEStatus(uint64_t handle);
void WGCNEStop(uint64_t handle);
void WGCNEFree(char *value);
```

Validate does no networking and returns public network settings:
`{addresses:["10.7.0.2/32"],mtu:1280,dns_servers:["198.18.0.2"],included_routes:["0.0.0.0/0"],excluded_routes:["203.0.113.10/32"]}`.
Start ALWAYS takes ownership of `owned_fd`, including invalid JSON and all error
paths. The provider passes a duplicate of its own utun descriptor. Start returns
`{handle:1}` only after both the WGC session and sing-box start. Pending native
startup cancels its context after 20 seconds; custom transport constructors must
honor cancellation. Successful startup disarms that timer, so it does not limit
the running tunnel's lifetime. Stop is idempotent.
Status returns `{state:"running",public_key:"...",bytes_sent:0,bytes_received:0,packets_sent:0,packets_received:0,core_version:"1.14.4"}` and never configuration.
The provider stops the core before discarding network settings. A provider-owned
health check observes terminal core failure without requiring host subscriptions
and requests system tunnel teardown. Caller deadlines do not release ownership
of an outstanding system settings mutation; its raw completion still controls
ordered cleanup.

## Flutter/native contract

Channel `dev.idy.wgc_ne/methods`. Calls:

- `start`: `{providerBundleIdentifier, keychainAccessGroup, configuration:<JSON string>, localizedDescription?}`
- `stop`: `{providerBundleIdentifier}`
- `status`: `{providerBundleIdentifier}`
- `removeProfile`: `{providerBundleIdentifier}` (explicit user action only).

Status is a dictionary with `state`: `disconnected`, `connecting`, `connected`,
`disconnecting`, `reasserting`, or `invalid`, plus optional `core` containing the
redacted ABI status. A Dart status stream may poll the native status only while
subscribed; subscriptions and disposal must release timers. Native calls use
bounded asynchronous completion, not blocking the main thread. Plugin errors
are stable codes and safe messages.

Provider messages use `{method:"status"}` and the same JSON result/error envelope.
The generic Swift provider owns platform setup and accepts an injected `CoreEngine`
implementation. The Go adapter implements it against the ABI above. Keep the
Swift package buildable without a generated Go binary; the extension target links
its chosen `WGCCore.xcframework` and compiles the Go adapter separately.

## Repository layout

- `core/`: independent Go module `github.com/idy/wgc-ne/core`, runtime, transport
  registry, native bridge, and C entrypoint.
- `Package.swift`, `apple/Sources/WGCNE/`: reusable native Swift SDK.
- `apple/GoAdapter/`: C header and Swift adapter for a generated WGCCore XCFramework.
- `lib/`, `ios/`, `macos/`: Flutter-facing API and platform plugins.
- `bin/`, `tool/`: custom-core builder and extension scaffolding tools.
- `example/`: minimal Flutter consumer and extension integration.
- `site/`: dependency-free project page for `wgc-ne.idy.dev`.

The public project is GPL-3.0-or-later. Preserve WGC's MIT attribution and
sing-box's own license/notice. Dependency licenses continue to apply.
