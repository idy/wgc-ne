# Custom transports

A transport implementation runs in the Go core inside the PacketTunnel process.
Dart selects its registered name and supplies JSON options. No packets cross a
Flutter method channel, and iOS does not dynamically load a Go plugin.

## Register a factory or wrapper

Use a factory when you create the whole transport:

```go
transport.RegisterFactory("my-link", func(ctx context.Context, raw json.RawMessage) (wgc.Transport, error) {
    return openMyLink(ctx, raw)
})
```

Use a wrapper when you transform an existing transport:

```go
func init() {
    err := transport.RegisterWrapper("my-wrapper", func(ctx context.Context, base wgc.Transport, raw json.RawMessage) (wgc.Transport, error) {
        return newWrapper(base, raw)
    })
    if err != nil { panic(err) }
}
```

Import `github.com/idy/wgc-ne/core/transport` and alias
`github.com/idy/wgc` as `wgc` (its Go package name is `wireguard`).
The returned value implements:

```go
type Transport interface {
    ReadFrom([]byte) (int, netip.AddrPort, error)
    WriteTo([]byte, netip.AddrPort) (int, error)
    Close() error
}
```

Keep WGC datagram boundaries and the remote `AddrPort` identity. Close must wake
blocked readers. A successful wrapper owns and closes its base. On construction
failure, return nil plus an error; the registry closes the base. Do not log keys
or transport options. Validate your own options; the registry cannot infer a
custom implementation's schema.

## Build it into the core

Create `wgc_ne.core.yaml` in the consuming project:

```yaml
extensions:
  - package: example.com/team/transport/register
    module: example.com/team/transport
    version: v1.2.3
    # Optional local module instead of a remote checkout:
    # path: ../transport
```

Paths are relative to the YAML file. Private module authentication uses the
normal Go environment (`GOPRIVATE`, Git credentials, or SSH); credentials never
belong in this YAML or the public plugin.

```bash
dart run wgc_ne:build_core --platform ios --config wgc_ne.core.yaml --output build/WGCCore.xcframework
```

The builder generates a main package importing the extension, pins dependency
versions, compiles the selected Apple architectures, and packages a static
XCFramework. Link that exact artifact into the extension target, not only Runner.
A missing registration is an error, never a fallback to plain UDP.

## Select it from configuration

```json
{
  "transport": {
    "type": "my-wrapper",
    "options": {},
    "base": {"type": "udp", "options": {"listen": ":0"}}
  }
}
```

An omitted wrapper base means UDP. At most eight wrapper layers are accepted.
The default UDP transport supports the optional `listen` address; endpoints stay
in the declared peers. A factory must not receive `base`.

The repository includes a transparent byte-counting wrapper in
[`example/counter`](../example/counter/register/register.go). It changes no packet
bytes and is not an obfuscation algorithm. Build it using
`--config example/wgc_ne.core.yaml` from the repository root and select `counter`.

## Admission and application protocols

Go users may pass `SessionOptions.PeerConfigLookup` as an additional admission
policy for declared peer keys. It runs when WGC admits a peer, not on each packet.
Returning nil or an error denies admission. The default pins declared peer keys
and endpoints. Dynamic account authorization belongs in the application.

The standard WGC NE outbound transports IP packets. A Transport wraps already
encrypted WireGuard datagrams; it is not a plaintext IP-payload or relay-prefix
hook. Applications with an additional payload protocol must provide that adapter
in their native core as well; wrapping UDP alone does not implement it.

## Distribution

Keeping an extension in a private repository does not waive the licensing
obligations of a distributed combined binary. The default core links GPL-licensed
sing-box. Preserve required notices and provide corresponding source as required
by the applicable licenses when distributing your custom core.
