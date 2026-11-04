# Third-party notices

WGC NE is GPL-3.0-or-later. Its dependencies retain their own copyright and
license terms; the project's license does not replace them.

| Component | Pinned version | License / upstream |
| --- | --- | --- |
| WGC | v0.2.1-0.20261103184829-50549511c059 | MIT — https://github.com/idy/wgc |
| sing-box | v1.14.4 | GPL-3.0-or-later and upstream notice — https://github.com/SagerNet/sing-box |
| sing | v0.9.7-0.20261023115459-5dc452e537bf | GPL-3.0-or-later — https://github.com/SagerNet/sing |
| sing-tun | v0.9.7-0.20261023115432-040db71fcd33 | GPL-3.0-or-later — https://github.com/SagerNet/sing-tun |

The pinned sing-box notice includes: “In addition, no derivative work may use
the name or imply association with this application without prior consent.”
WGC NE uses its own name and is not an official product of those projects.

Collected license and notice files are preserved under `third_party/licenses/`.
They include the short upstream GPL notices that automated classifiers could not
identify; those notices were checked against their original pinned modules.
The complete core dependency graph and cryptographic checksums are recorded in
`core/go.mod` and `core/go.sum`. The WGC dependency includes WireGuard Go and
selected gVisor utilities. sing-box's userspace network stack uses its gVisor
fork. Dart dependencies are declared in `pubspec.yaml` and retain their licenses.

Custom transports remain the consuming application's responsibility. Building
an extension into the native core does not make its license disappear. Review
the licenses of the resulting combined binary before distributing it.

No product-specific transport framing, account services, private credentials,
or routing databases from a consuming application are included here.
