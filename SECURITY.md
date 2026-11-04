# Security

Do not put private keys, full tunnel configurations, transport secrets, signing
identities, provisioning profiles, or account tokens in an issue or pull request.
For sensitive reports, use GitHub's private vulnerability reporting when enabled.

WGC NE is a pre-1.0 SDK, not an audited security product. The host application is
responsible for configuration provenance, peer authorization, key lifecycle,
platform entitlements, and its own transport extensions. Unknown transports and
undeclared peers are rejected rather than silently using a different route.

The native ABI bounds JSON inputs, never exports Go pointers, and takes ownership
of duplicated TUN file descriptors on every Start path. Status reports contain
public identities and counters only. Configuration lives in a device-only shared
Keychain item, with only a reference stored in NetworkExtension preferences.

Public defaults enable standard UDP and forward IP traffic. They do not implement
application accounts, payment, remote configuration services, or private framing.
