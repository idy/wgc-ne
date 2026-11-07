# Changelog

## 0.2.1

- Fix Apple Keychain configuration reads that fail with `errSecParam` when a
  persistent reference is combined with item-attribute filters on iOS.
- Preserve service/access-group ownership, synchronization, and payload-size
  validation by checking attributes returned with the configuration data.

## 0.2.0

- Android API 23+ support through an app-owned foreground `VpnService`, JNI,
  protected native sockets, and `WgcNe.android`.
- Consent-result handling, serialized startup/shutdown, independent core health
  polling, and memory-only Android configuration.
- Android NDK core builds with compiled transport extensions, multiple ABIs,
  16 KiB alignment checks, example packaging, and platform regression tests.

## 0.1.0

Initial preview API:

- WGC v0.2.0 sessions and a sing-box v1.14.4 userspace/TUN integration.
- Standard UDP plus compiled-in transport factories and wrappers.
- Redacted native ABI with explicit descriptor ownership and bounded JSON.
- Apple Network Extension SDK and Flutter control surface.
- Shared Keychain configuration, custom-core builder, and integration example.

The API is pre-1.0. A successful build is not a claim of App Store acceptance or
universal device/network compatibility.
