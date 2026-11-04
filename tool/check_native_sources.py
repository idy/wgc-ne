#!/usr/bin/env python3
"""Ensure native integrations share canonical Swift sources without copied code."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = sorted((root / 'apple/Sources/WGCNE').glob('*.swift'))
for platform in ('ios', 'macos'):
    links = sorted((root / platform / 'Classes/WGCNE').glob('*.swift'))
    assert [p.name for p in sources] == [p.name for p in links], platform + ': missing source links'
    for link in links:
        assert link.is_symlink(), str(link.relative_to(root)) + ': expected a source link'
        assert link.resolve() == root / 'apple/Sources/WGCNE' / link.name, 'Source link leaves the SDK'
adapter = root / 'example/ios/WGCPacketTunnel/WGCCoreEngine.swift'
assert adapter.is_symlink(), 'The example must link the canonical Go adapter'
assert adapter.resolve(strict=True) == root / 'apple/GoAdapter/WGCCoreEngine.swift', 'The example adapter leaves the SDK'
print('Both CocoaPods plugins and the example share canonical Swift sources.')
