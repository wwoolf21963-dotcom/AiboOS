AiboOS iPhone SE (2016) — Experimental native Windows Pongo FIRST STAGE
========================================================================

*** NOT AN INSTALLER. NOT VERIFIED ON A REAL IPHONE. DO NOT FLASH. ***

Why this exists:
The AiboOS Windows Pongo transfer program checks for PongoOS (05ac:4141),
but your device appears in normal iOS mode (05ac:12a8). This is an
EXPERIMENTAL Windows-native port of the upstream openra1n boot stage,
which contains checkm8 and a historical PongoOS payload.

Included:
  aiboos-pongo-stage1.exe    Guarded native Windows port, experimental
  libusb-1.0.dll             USB runtime
  Start-Stage1-Diagnostics.cmd   READ-ONLY --selftest and --probe
  UPSTREAM.txt               Reproducible pin of upstream source
  SHA256SUMS.txt             Local file checksums

Building and offline self-tests do NOT establish that checkm8 will work on
your Windows host, that the Pongo payload works with iOS 15.8.8 on A9,
or that your current Windows driver can access the DFU interface.

You can double-click Start-Stage1-Diagnostics.cmd to check the current
Apple USB mode without modifying the iPhone.

HARDWARE RISKS:
- Real checkm8 requires DFU mode and a compatible Windows USB driver.
- Changing Apple device drivers may break Apple Devices/iTunes until reset.
- The checkm8 USB reset/timing is notoriously host-dependent.
- The upstream PongoOS payload may be outdated for modern iOS.
- Pongo USB transfer and kernel boot have NOT been verified.
- A Linux kernel that boots in RAM is NOT a replacement for iOS.
- Hoolock internal-storage support is documented for A11, not A9.

For these reasons, the supplied launcher NEVER enters DFU, installs a
driver, performs checkm8, uploads a boot image, or writes to NAND.
An explicitly acknowledged --load-pongo mode exists only for reviewed
hardware tests. Do not use it based on the successful CI test alone.

Upstream source: https://github.com/palera1n/openra1n
Pinned commit: 49fb794cde1f73cc7a00b502a42b994926c64c63
openra1n: Apache-2.0; original checkm8 derived from gaster.
PongoOS upstream: checkra1n/PongoOS; see original upstream licenses.
This is not affiliated with Apple, palera1n, or checkra1n.
