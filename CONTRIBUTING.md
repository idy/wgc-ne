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

Both CocoaPods plugin folders contain file links to the canonical Swift sources
under `apple/Sources/WGCNE`. Keep those links in sync when adding a Swift file;
`python3 -I tool/check_native_sources.py` verifies the single-source arrangement.

See `docs/apple-integration.md` for native integration and `docs/transports.md`
for custom-core builds. Tests must use synthetic keys and loopback/local stacks;
do not commit a real VPN profile. Never describe a successful build or simulated
peer test as a signed device, production-network, or App Store acceptance result.

## Pull request reviews

Ready pull requests are reviewed automatically by
[the Codex review workflow](.github/workflows/codex-review.yml). It calls the
shared GizClaw reviewer at `latest` and receives the repository's
`OPENAI_API_KEY` Actions secret explicitly. The reviewer uses the trusted base
and treats the pull request diff as data; it does not execute pull request code.

To request a fresh review, add a new pull request comment containing
`@codex review` on its own line. Use a new request instead of rerunning an old
Actions run. Closing Issues are optional; when present, their plans are reviewed
alongside the changes.

Before merging, inspect the `OpenAI PR Review`, `OpenAI Issue Review`, and
`OpenAI Code Review` checks on the current commit and read the published review.
These automated checks do not replace the platform validation described above.
