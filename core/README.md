# WGC NE Go core

Module `github.com/idy/wgc-ne/core` combines WGC v0.2.0 with sing-box v1.14.4.
Build and test with `-tags with_gvisor` using Go 1.26+.

`NewSession` provides userspace `DialPeer` TCP/UDP connections without an OS TUN.
`Open` owns a transferred Apple utun descriptor and starts the full sing-box TUN
runtime. `native` exposes the bounded JSON/opaque-handle contract used by the C
archive in `cmd/wgc-ne-core`.

Transport implementations register with `transport.RegisterFactory` or
`transport.RegisterWrapper`. Only UDP is built in. The standalone Flutter builder
imports selected registration packages into the core at compile time.

The core uses atomic counters at the selected transport boundary and disables
WGC v0.2.0's optional receive statistics, whose internal receive workers can race.
Counters include encrypted datagrams and handshake traffic, not just application
payloads. Private transport internals may account for additional wire overhead.

See the repository's [architecture](https://github.com/idy/wgc-ne/blob/main/docs/architecture.md),
[transport guide](https://github.com/idy/wgc-ne/blob/main/docs/transports.md), and
[third-party notices](https://github.com/idy/wgc-ne/blob/main/THIRD_PARTY_NOTICES.md).

GPL-3.0-or-later; see LICENSE and NOTICE. WGC and all other dependencies retain
their own license terms.
