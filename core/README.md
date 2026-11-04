# WGC NE Go core

Module `github.com/idy/wgc-ne/core` combines WGC
`v0.2.1-0.20261103184829-50549511c059` with sing-box v1.14.4. The WGC pseudo-version
pins upstream commit `50549511c059` before its next tagged release.
Build and test with `-tags with_gvisor` using Go 1.26+.

`NewSession` provides userspace `DialPeer` TCP/UDP connections without an OS TUN.
`Open` owns a transferred Apple utun or Android `VpnService` TUN descriptor and
starts the full sing-box TUN runtime. Ownership transfers on every path,
including invalid arguments and startup failure. The host installs validated
VPN settings first; the core never installs host routes. `native` exposes the
bounded JSON/opaque-handle contract shared by the Apple C archive in
`cmd/wgc-ne-core` and Android JNI shared library in `cmd/wgc-ne-android`.
The Apple C ABI remains version 1.

Transport implementations register with `transport.RegisterFactory` or
`transport.RegisterWrapper`. Only UDP is built in. The standalone Flutter builder
imports selected registration packages into the core at compile time.

## Android socket protection

Android API 23+ requires `transport.WithSocketProtector(ctx, protector)` before
`Open` or `NewSession`. The callback calls `VpnService.protect(fd)` and returns
an error when Java returns false. It may run concurrently and must borrow the
socket only during the call: never close, retain, or duplicate that descriptor.
Keep the protector alive until the engine closes. Protect outer network sockets,
never the TUN or the userspace connections inside WGC.

The default UDP transport protects before bind. Custom factories and wrappers
receive the same context and must protect **every** outer socket, including
reconnects, auxiliary connections, and their own DNS. For standard Go networking:

```go
listener := net.ListenConfig{Control: transport.SocketControl(ctx)}
conn, err := listener.ListenPacket(ctx, "udp", ":0")

dialer := net.Dialer{Control: transport.SocketControl(ctx)}
stream, err := dialer.DialContext(ctx, "tcp", "203.0.113.10:443")
```

Compose protection with any other socket control; never overwrite it. A raw
socket implementation calls `transport.ProtectSocket(ctx, fd)` before bind,
connect, or send, and closes its own socket if protection fails. The helpers
redact callback errors, propagate cancellation, and never close a borrowed fd.
Without a protector they are no-ops on non-Android hosts; Android fails closed.
A registered factory is trusted native code: the registry cannot force it to use
these helpers or intercept sockets opened by arbitrary third-party libraries.

sing-box direct TCP/UDP sockets and direct DNS/HTTP dialers also protect,
including UDP listeners and explicit bind options, regardless of
`route.auto_detect_interface`. With sing-box v1.14.4 this uses a service-registry
decorator that composes protection with the unconditional
`NetworkManager.AutoRedirectOutputMarkFunc` socket-control hook. Upgrade tests
must retain coverage of that upstream hook. Android follows the OS default
underlying network and does not provide an interface monitor or explicit network
selection. The supplied TUN is duplicated with close-on-exec; Android sets
nonblocking mode, which is shared with any host duplicates of that descriptor.

## Android JNI entrypoint

`cmd/wgc-ne-android` is a cgo `c-shared` main package with no gomobile dependency.
Copy all three command files (`main.go`, `jni_bridge.c`, `jni_bridge.h`) when
creating a generated extension module; replace the
`// wgc-ne:extension-imports` marker as for the Apple command. Build with NDK
clang targeting API 23 or newer, for example from this module:

```sh
GOOS=android GOARCH=arm64 CGO_ENABLED=1 \
CC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android23-clang" \
CGO_LDFLAGS="-Wl,-z,max-page-size=16384" \
go build -tags with_gvisor -buildmode=c-shared -o libwgcne.so ./cmd/wgc-ne-android
```

Use the matching NDK host and target triple for other platforms/ABIs. The
16 KiB maximum-page-size flag is supplied through `CGO_LDFLAGS` (Go rejects it in
a `#cgo LDFLAGS` directive). Check every ELF `LOAD` segment has alignment at least
`0x4000`, and package the native library with the Android build tools' required
16 KiB zip alignment.

The library exports static native methods for `dev.idy.wgcne.NativeCore`:

```java
static native String validate(byte[] configuration);
static native String start(int ownedFd, byte[] configuration, NativeCore.Protector protector);
static native String status(long handle);
static native void stop(long handle);
interface Protector { boolean protect(int fd); }
```

All responses use the existing bounded, redacted JSON envelopes. Configuration
is UTF-8 and at most 128 KiB. `start` consumes `ownedFd` even for null/oversized
configuration, missing protectors, or JNI failures; transfer a detached descriptor
or a duplicate, never a descriptor still owned by `ParcelFileDescriptor`.
`native.Bridge.StartWithSocketProtector` also owns the protector release callback
on every path. JNI holds a global reference until startup fails, the engine
terminates, or `stop` closes it. In-flight callbacks retain that reference until
they finish. Callbacks attach arbitrary Go threads to the VM and detach only
threads they attached. If the VM temporarily refuses attachment during
asynchronous retirement, the deletion token is retained and drained by the next
attached JNI call. A thrown Java callback exception is cleared without logging
and fails protection closed. Call `stop` on terminal handles to remove
them; it is idempotent. Start/stop may block and belong off the Android UI thread.

## Validation

Run `go test -tags with_gvisor ./...`, `go vet -tags with_gvisor ./...`, and
`go test -race -tags with_gvisor ./...` from this module. Protection tests use
loopback sockets and fake/invalid TUN descriptors without host routing changes.
The standalone C harness exercises the actual JNI code with a fake VM, including
callback rejection/exceptions, thread attachment, global-reference lifetime, and
FD transfer on invalid input. From this module, using the NDK's VM-neutral
`jni.h` with the **host** compiler:

```sh
NDK_HOST_TAG=darwin-x86_64 # Use linux-x86_64 on Linux CI.
clang -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
  -Icmd/wgc-ne-android -Icmd/wgc-ne-android/testdata \
  -idirafter "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST_TAG/sysroot/usr/include" \
  cmd/wgc-ne-android/testdata/jni_bridge_test.c -o /tmp/wgc-ne-jni-test
/tmp/wgc-ne-jni-test
```

Add `-fsanitize=address,undefined` when the host compiler supports it. Cross-build
and check ELF alignment/exports separately. These checks do not replace an
Android device/emulator test of `VpnService`, tunnel traffic, stop/restart,
network changes, and the Java/Go callback boundary.

The core uses atomic counters at the selected transport boundary and disables
WGC's optional peer statistics to avoid duplicate accounting. Counters include
encrypted datagrams and handshake traffic, not just application payloads. Private
transport internals may account for additional wire overhead.

See the repository's [architecture](https://github.com/idy/wgc-ne/blob/main/docs/architecture.md),
[transport guide](https://github.com/idy/wgc-ne/blob/main/docs/transports.md), and
[third-party notices](https://github.com/idy/wgc-ne/blob/main/THIRD_PARTY_NOTICES.md).

GPL-3.0-or-later; see LICENSE and NOTICE. WGC and all other dependencies retain
their own license terms.
