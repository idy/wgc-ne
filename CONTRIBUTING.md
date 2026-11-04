# Contributing

Use Go 1.26+, Flutter/Dart, and Xcode on macOS for Apple builds. Keep changes to
public generic networking and platform integration; application-specific account
services and private transports belong in their consuming projects.

Run the checks relevant to a change:

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

On macOS, run the iOS setup regression tests as well:

```bash
python3 -I -m unittest discover -s tool -p 'test_*.py'
```

Both CocoaPods plugin folders contain file links to the canonical Swift sources
under `apple/Sources/WGCNE`, and the example links the canonical Go adapter under
`apple/GoAdapter`. Keep those links in sync when adding a Swift file;
`python3 -I tool/check_native_sources.py` verifies the shared sources.

See `docs/apple-integration.md` for native integration and `docs/transports.md`
for custom-core builds. Tests must use synthetic keys and loopback/local stacks;
do not commit a real VPN profile. Never describe a successful build or simulated
peer test as a signed device, production-network, or App Store acceptance result.
